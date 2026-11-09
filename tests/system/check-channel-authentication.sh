#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
# All Git commits and signing keys belong to a disposable local fixture.
set -euo pipefail
if test "$#" -lt 4 || test "$#" -gt 6; then
    echo 'Usage: check-channel-authentication.sh SOURCE NEW-RECORDS TOOLS GUIX [JOBS] [CORES]' >&2
    exit 1
fi
source=$1
records=$2
tools=$3
guix=$4
jobs=${5:-}
cores=${6:-}
export PATH="$tools/bin"
umask 077
mkdir "$records"
records=$(cd "$records" && pwd -P)
export HOME="$records/home" XDG_CACHE_HOME="$records/cache"
mkdir "$HOME" "$XDG_CACHE_HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='Hello Guix authentication fixture'
export GIT_AUTHOR_EMAIL='hello-guix-test@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
export GIT_TERMINAL_PROMPT=0
unset GPG_AGENT_INFO SSH_AUTH_SOCK
fixture="$source/tests/system/channel-authentication.scm"
"$guix" repl "$fixture" inputs "$records"

# Use a short private path for GnuPG's Unix socket; remove the secret test keys
# on success, error or timeout. Public keys and Git evidence remain in records.
key_home=$(mktemp -d /tmp/hello-guix-auth-XXXXXX)
export GNUPGHOME="$key_home"
cleanup() {
    status=$?
    "$tools/gpgconf" --homedir "$key_home" --kill gpg-agent >/dev/null 2>&1 || true
    rm -rf -- "$key_home"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fingerprint() {
    local kind a b c d e f g h value rest
    while IFS=: read -r kind a b c d e f g h value rest; do
        if test "$kind" = fpr; then printf '%s\n' "$value"; return; fi
    done < <("$tools/gpg" --batch --with-colons --fingerprint "$1")
    echo 'Generated test key has no fingerprint.' >&2
    return 1
}
for identity in authorized unauthorized; do
    "$tools/gpg" --batch --pinentry-mode loopback --passphrase '' \
        --quick-generate-key "Hello Guix fixture $identity <$identity@example.invalid>" \
        rsa2048 sign 1d
done
authorized=$(fingerprint '<authorized@example.invalid>')
unauthorized=$(fingerprint '<unauthorized@example.invalid>')
printf '%s\n' "$authorized" > "$records/authorized-fingerprint"
printf '%s\n' "$unauthorized" > "$records/unauthorized-fingerprint"

repository="$records/repository"
"$tools/git" init --quiet --initial-branch=main "$repository"
git() { "$tools/git" -C "$repository" "$@"; }
git config gpg.program "$tools/gpg"
git config gpg.format openpgp
# Include the whole maintained source, as a real channel checkout would.
inputs=(.gitignore .guix-channel COPYING Makefile NOTICE README.md
        LICENSES docs hello-guix packaging patches scripts tests)
for name in "${inputs[@]}"; do cp -R "$source/$name" "$repository/"; done
cat > "$repository/.guix-authorizations" <<EOF
(authorizations
 (version 0)
 (("$authorized" (name "Disposable Hello Guix test signer"))))
EOF
git add .guix-authorizations "${inputs[@]}"
git commit --quiet --gpg-sign="$authorized" --message='Introduce the local authentication fixture'
introduction=$(git rev-parse HEAD)
printf '%s\n' "$introduction" > "$records/introduction"

git checkout --quiet --orphan keyring
git rm --quiet -rf .
"$tools/gpg" --batch --armor --export "$authorized" > "$repository/authorized.key"
"$tools/gpg" --batch --armor --export "$unauthorized" > "$repository/unauthorized.key"
git add authorized.key unauthorized.key
git -c commit.gpgsign=false commit --quiet --no-gpg-sign --message='Public test keys'
git checkout --quiet main

run() {
    local name=$1 mode=$2 revision=$3 expected=$4 signer=${5:-$authorized}
    local directory="$records/$name"
    mkdir -p "$directory/home" "$directory/cache"
    # Separate caches also force the wrong-introduction case to check its key.
    if env HOME="$directory/home" XDG_CACHE_HOME="$directory/cache" \
        "$guix" repl "$fixture" "$mode" "$repository" "$introduction" "$signer" \
        "$revision" "$expected" "$directory" "$jobs" "$cores" \
        > "$directory/run.log" 2>&1; then
        cat "$directory/run.log"
    else
        local status=$?
        cat "$directory/run.log"
        return "$status"
    fi
}

printf 'First authorized revision.\n' > "$repository/.authentication-fixture"
git add .authentication-fixture
git commit --quiet --gpg-sign="$authorized" --message='First authorized update'
first=$(git rev-parse HEAD)
run first build main "$first"

printf 'Second authorized revision.\n' > "$repository/.authentication-fixture"
git add .authentication-fixture
git commit --quiet --gpg-sign="$authorized" --message='Advance the followed branch'
second=$(git rev-parse HEAD)
run second build main "$second"
run replay replay "$records/first/channels.scm" "$first"
"$tools/cmp" "$records/first/profile.drv" "$records/replay/profile.drv"
"$tools/cmp" "$records/first/channels.scm" "$records/replay/channels.scm"
printf 'Recorded channel revision replayed with the same profile derivation.\n'

git checkout --quiet -b unauthorized "$second"
printf 'Unauthorized signer.\n' > "$repository/.authentication-fixture"
git add .authentication-fixture
git commit --quiet --gpg-sign="$unauthorized" --message='Reject an unauthorized signer'
bad=$(git rev-parse HEAD)
run unauthorized reject-unauthorized "$bad" "$bad"

git checkout --quiet -b unsigned "$second"
printf 'Unsigned successor.\n' > "$repository/.authentication-fixture"
git add .authentication-fixture
git -c commit.gpgsign=false commit --quiet --no-gpg-sign --message='Reject an unsigned successor'
unsigned=$(git rev-parse HEAD)
run unsigned reject-unsigned "$unsigned" "$unsigned"
git checkout --quiet main
run wrong-introduction reject-introduction "$second" "$second" "$unauthorized"

printf '\nAuthenticated local channel delivery and exact-revision replay passed.\n'
printf 'Upstream inputs were reused; this is not a fresh time-machine bootstrap.\n'
