<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Building and contributing

The [architecture guide](architecture.md) explains how the pieces fit
together. Here we’ll work through a small example, check it and build the
installer. The final section is for preparing a release.

## Where to begin

Choose a part you would like to understand or improve, using the [source
map](architecture.md#where-the-code-lives) to find a starting point.
Contributions need not be large. Helping someone understand the code,
making it simpler or catching a recurring bug are all useful places to
start. The [project philosophy](philosophy.md) describes the care I ask of
this work.

Look for an existing Guix or Asahi interface before adding machinery.
Our additions should preserve the user’s other choices and give the same
result when applied again. If a choice cannot be preserved, explain why
rather than quietly dropping it.

Keep upstream changes as small, explained patches against the pinned
revision, and retire them when upstream provides the same facility. Follow
the licences and source-notice conventions in [COPYING](../COPYING).

## Prepare your tools

You can begin on macOS or Linux with the Python checks. Checks that use
Guix need Linux, and building the complete installation image needs an
ARM64 Linux machine (`aarch64-linux`). We then assemble the Mac installer
on macOS. These stages can run on different machines.

### Local work on macOS or Linux

With Python 3.12 or later, GNU Make and `patch`, open a terminal in the
project root and run:

```sh
make check code
```

This prepares the pinned Asahi installer source with our patches, then
runs the Python tests using temporary files. It does not install a system
or write to a device.

Commands follow `make <verb> <noun>`, such as `make check code` or
`make build image`. Run `make help` for the commands and their settings.

The prepared source stays in `build/asahi-installer/`. If you change an
Asahi patch, preserve any edits to that generated tree, move it aside and
run the check again.

### The Guix development environment

For the Scheme checks and image builds, use Linux with [Guix
installed][install-guix], its daemon running and your account able to
use it. From the project root, enter a shell with our recorded channel
versions and build tools:

```sh
export GUIX=$(command -v guix)
"$GUIX" time-machine --channels=packaging/guix/channels.scm -- \
  shell --pure --preserve='^(TERM|GUIX)$' \
  --manifest=scripts/environment.scm -- \
  bash --noprofile --norc
```

This leaves your installed packages unchanged. Inside the shell, set the
certificate paths so Python can verify downloads:

```sh
export SSL_CERT_DIR="$GUIX_ENVIRONMENT/etc/ssl/certs"
export SSL_CERT_FILE="$SSL_CERT_DIR/ca-certificates.crt"
test -s "$SSL_CERT_FILE"
```

Use this shell for the Guix commands below, and re-enter it after changing
the channels or tool manifest. Resolve any command failure before
continuing.

## Make and check a change

Let’s try a change we can examine without booting a Mac. Suppose we want
a system to load `tun`, a kernel module used for virtual networking.
We can add that choice to a configuration, then check that
`with-asahi-hardware` preserves it when adding the Mac’s requirements.

We’ll start with `console`, a fictional system in
[`tests/hardware.scm`](../tests/hardware.scm), and add Guix’s module-loading
service:

```scheme
(define requested-module
  (with-asahi-hardware
   (operating-system (inherit console)
    (services
     (cons (service kernel-module-loader-service-type '("tun"))
           %base-services)))))
```

`inherit` starts with `console`’s settings. We replace its service list
with the base services and our additional request, then pass that
description to `with-asahi-hardware`. The result should include both the
Asahi modules and `tun`. The test file’s `value` helper lets us check:

```scheme
(test-equal "other kernel modules retained" '("asahi" "appledrm" "tun")
            (value requested-module kernel-module-loader-service-type))
```

After editing the function or its tests, run this in the Guix development
shell:

```sh
make check code only=hardware
```

This checks the description without activating it. The test systems use
fictional disks, so do not use them to reconfigure your computer.

### Choosing checks for your change

Use the checks that exercise the part you changed. Run them as an ordinary
user in the Guix development shell. Results and logs go under `build/`.

| Work | Check |
|---|---|
| Hardware, audio and boot bundles | `make check code only=hardware` |
| Installer choices and generated configurations | `make check code only=configuration` |
| Saved sources and rebuilding | `make check code only=source` |
| Console and GNOME system builds | `make check code only=desktop` |

The first two mostly inspect definitions and temporary files. The latter
two build systems, so allow more time and space. Their
[test script](../tests/guix/check-source.sh) accepts `--dry-run` to preview
the work, and `--desktop` to include both systems.

## Build and test the installer

Once the smaller checks pass, we can build the complete installation
image. Use the Guix development shell on ARM64 Linux, with tens of GiB
available for dependencies and intermediate files.

Outputs go under `build/`. Set `build_dir` to use another folder, or
`jobs` and `cores` to override Guix’s configured resource limits.

### Build the installation image

First, prepare the pinned sources and see what Guix needs to build or
download:

```sh
make plan image
```

Then build the image:

```sh
make build image
```

Guix reuses existing build results. A new image is checked before it
replaces the previous result. To check an existing image again, use
`make check image`. This inspects its contents without booting it.

### Test in a virtual machine

We can exercise installation using disposable virtual disks. Start with
the smaller check, which tests destination preparation and recovery from
interrupted writes:

```sh
make check code only=installation-target
```

The full check runs Guix’s installer and boots the resulting system
through UEFI. It needs a 20 GiB virtual disk and 6 GiB of guest RAM, in
addition to build space. On a machine with limited memory, finish building
before running the VM. KVM speeds this up when available:

```sh
make check code only=installation
```

These VMs have no host directory shares or device passthrough. They can
check the installation flow, but Apple Recovery, startup and drivers
still need a real Mac. See the [current hardware coverage][tested] before
choosing what to test there.

## Prepare a release

For a release, we need to prepare and verify both the installer and its
sources. We’ll freeze a candidate on Linux, assemble it on macOS, then
check the downloads before installing from them.

Keep the same terminal open within each machine’s steps, so the paths
you set remain available.

### Freeze the candidate

In the Guix development shell, choose a fresh directory:

```sh
build_dir=build/candidate-01
make build candidate build_dir="$build_dir"
```

This builds from a saved copy of the project. It produces a *catalogue*
under `build/candidate-01/catalogue/`, containing the image, its Asahi
description, checksums and saved source. Existing Guix outputs are reused.
Use a new candidate directory after changing the source.

Check the catalogue before continuing:

```sh
(cd "$build_dir/catalogue" && sha256sum -c SHA256SUMS)
```

New top-level files and directories need to be classified in
[`build_inputs.py`](../scripts/build_inputs.py). Keep generated files
under `build_dir`.

The source download contains our code, patches, build instructions and
upstream pins. The channel revisions lead to Guix’s package recipes,
while the macOS manifests record upstream source URLs and checksums.
Building from these sources fetches dependencies as needed.

### Assemble on macOS

Transfer the catalogue, including `source-record/`, to an Apple Silicon
Mac with Python 3.12 or later and Xcode Command Line Tools. Preserve
executable permissions and symbolic links when copying.

Set the catalogue’s path and choose a new output directory:

```sh
catalogue=/absolute/path/to/catalogue
assembly=/absolute/path/to/assembly
```

Use the saved source to assemble the installer:

```sh
make -C "$catalogue/source-record" build installer \
  candidate="$catalogue" assembly="$assembly"
```

This combines the image with Asahi’s runtime and our launcher. Most of
the runtime is reused, but we build libffi from upstream source. For 0.1,
the library’s deployment target and the launcher’s minimum version are
both macOS 26.

The result has an `installer/` directory ready to run and a `source/`
directory for the source download. [NOTICE](../NOTICE) explains what
each contains. A small `build.json` record identifies the sources used
for the installer and image. If the image came from an earlier project
snapshot, that snapshot is also kept in the source download.

Reuse cached inputs through the `runtime_archive`, `source_archive` and
`runtime_sources` settings. Their hashes are checked before use. These
upstream archives are build inputs; they are not copied into the source
download.

Check the assembly:

```sh
make -C "$catalogue/source-record" check installer assembly="$assembly"
```

Then check that the bundled runtime can open the image:

```sh
bash "$assembly/installer/install.sh" check
```

Keep the `check` argument: without it, the launcher starts Asahi’s
installer and can change the Mac’s disk.

### Prepare and check the hosted download

GitHub Releases or a static HTTPS server can host the downloads. Choose
a new release directory outside the assembly and replace the example
URL with the release address:

```sh
release_dir=/absolute/path/to/release
make -C "$assembly/source" build release \
  assembly="$assembly" release_dir="$release_dir" \
  version=0.1 base_url=https://your-host.example/releases/0.1
```

The version must match the image’s release version, optionally with an
`-rcN` suffix. The command creates four files:

- `hello-guix-0.1.tar.gz`, the installer.
- `hello-guix-0.1-src.tar.gz`, the project sources, pins and build record.
- `install.sh`, the download launcher.
- `SHA256SUMS`, their checksums.

Check them before publishing:

```sh
make -C "$assembly/source" check release release_dir="$release_dir"
```

Nothing has been uploaded yet. Publish all four files together at the
chosen address, keeping that version unchanged once released.

Finally, check the hosted download on the Mac. The web launcher takes
`--check`, while the bundled launcher above takes `check`:

```sh
curl -fsSL --proto '=https' \
  https://your-host.example/releases/0.1/install.sh | sh -s -- --check
```

This downloads over HTTPS, verifies the archive and checks the runtime
without starting installation. The verified download is cached for reuse.
To install, run the same pipeline ending in `| sh`, without
`-s -- --check`.

### Verify that exact release on hardware

Use the hosted release for a full installation through macOS preparation,
Apple Recovery and Guix’s installer. After rebooting, check login, sudo,
root and EFI identities, Wi-Fi/DNS, the desktop environment, audio,
Bluetooth, suspend and reconfiguration. Confirm that other installations
remain usable.

Keep the archive hashes and results, and update the [tested
scope][tested]. This connects the release people download to the system
we have actually used.

[install-guix]: https://guix.gnu.org/manual/en/html_node/Binary-Installation.html
[tested]: installation.md#what-has-been-tested
