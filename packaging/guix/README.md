# Guix packaging

The source lives in `hello-guix/`: `system/` composes services and hardware
support, `packages/` supplies the maintained component recipes, and `installer/`
handles installation. Guix compiles every Scheme file beneath a channel's module root,
so the channel uses a small directory of relative file links:

- `channel/` exposes system and package modules, selected by `.guix-channel`.
- `installer/` exposes the Linux installer modules for image builds.

Each link points to its corresponding file in `hello-guix/`. Image builds
put both directories on the module path, alongside the patched GNU Guix
installer. Tests and standalone build recipes stay outside those paths.
Guix uses its normal channel compiler; there is no custom channel builder.

When adding a Scheme module, add its relative file link to the appropriate
directory too. `make check code` checks that the views are complete, that
module names match their paths, and that saved source and archives preserve
the links. Source snapshots accept only these links, pointing to their
matching files within the source tree.

The standalone build recipes live in `recipes/`: they prepare the installer
source and program, select its Guix tools, and construct the RAM installation
image. These recipes stay outside both module views.

The programs in `scripts/packaging/` run the build and collect its results.
Local records, caches and assembled downloads go under `build_dir`
(normally `build/`); Guix build outputs remain in its store.

## Experimental Guix evaluator

Guix commit `7c39b1b1a0ad114ab5ceab0c53fb84dd0f990d9f` can lose the
active package transformation while lowering a system with a Home environment
and grafts. The cold-cache regression in `tests/system/software.scm` exercises
this upstream defect. Until the correction reaches upstream, we can compile
an isolated development evaluator from the same source with our small patch.
This remains experimental; it is not the default release evaluator.

Set `GUIX` to the existing channel profile containing that Guix revision and
Asahi. From the project root, in the Linux development shell, point
`GUIX_SOURCE` at its complete cached source directory in the store:

```sh
mkdir -p build
GUIX_SOURCE=/gnu/store/f9g7j21b57yhl3ax1hgpr8g2qvm6nrah-guix-7c39b1b \
  "$GUIX" build --file=packaging/guix/recipes/development-guix.scm \
    --max-jobs=1 --cores=2 --root="$PWD/build/development-guix"

export GUIX="$PWD/build/development-guix/bin/guix"
make check code only=runtime GUIX="$GUIX"
```

The recipe checks the entire upstream source tree, records the patch hash,
compiles Guix with its normal channel compiler, and retains the selected Asahi
channel. The
result is a separate Guix/Asahi profile. The runtime check then compiles Hello
Guix and records the combined profile in its reported `runtime-check-*`
directory. Once that check passes, select the combined profile:

```sh
check_records=/absolute/path/to/the/reported/runtime-check-directory
export GUIX="$(cat "$check_records/channel-profile")/bin/guix"
```

Continue with the existing `make plan system` and `make build system` commands,
using this `GUIX` value and your chosen configuration and build directory.

The corrected source is explicitly local: `guix describe` reports Guix's
zero revision rather than claiming a published upstream commit. Its source
directory includes `hello-guix-development.scm`, recording the actual upstream
revision, hashes, patch and recipe. Keep the profile root for exact replay;
its local channel description alone cannot be fetched with `guix time-machine`.
