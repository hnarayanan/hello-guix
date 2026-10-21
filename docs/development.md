<!-- SPDX-FileCopyrightText: 2026 Harish Narayanan -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Building and contributing

The [architecture guide](architecture.md) explains how Hello Guix fits
together. Let’s now get a feel for working on it. We’ll start with a small
change and see how to check it, then move on to building the installer.
If you’re here to build the release downloads, head straight to
[Prepare your tools](#prepare-your-tools), then continue with
[Prepare a release](#prepare-a-release).

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

If you add a top-level file or directory, classify it in
[`build_inputs.py`](../scripts/build_inputs.py) so the source snapshot
includes it. Keep generated files under `build_dir`.

## Prepare your tools

Building the installer involves both Linux and macOS. We’ll build the
Guix installation image on ARM64 Linux (`aarch64-linux`), then assemble
the Mac installer on macOS. You can use different computers for these
stages. Here’s what each needs:

- **Linux:** the [Guix package manager][install-guix], with its daemon
  running and available to your account, and `guix` on your `PATH`. Guix
  will provide the remaining build tools through the shell we set up below.
- **macOS:** Python 3.12 or later, GNU Make, `patch` and Xcode Command Line
  Tools. Assembling the 0.1 installer needs an Apple Silicon Mac running
  macOS 26 or later.

The Python checks alone work on either platform with Python, Make and
`patch`. The Scheme checks use the Guix development shell on Linux.

### Get the source

Begin with a checkout of the project or an unpacked source download. With
Git installed, you can get a checkout on the computer where you’ll work:

```sh
git clone https://github.com/hnarayanan/hello-guix.git
cd hello-guix
```

To work from a particular release, check out its tag or commit before
building. Run the commands below from the project root, the directory
containing `Makefile`, unless another directory is given.

For a release build, start on Linux. We’ll later copy the image and its
saved source to macOS. If you’ve already made changes on another computer,
bring those across too; cloning from GitHub won’t include your local edits.

### Set up the Linux development environment

We want to be able to work on Hello Guix with the same tools on different
Linux machines. Guix lets us describe those tools in Scheme, just as we
describe the system itself. We can then ask it to open a shell with those
tools ready to use.

Our description lives in two files. [`scripts/environment.scm`][environment]
lists the tools, including Python and Make, while
[`packaging/guix/channels.scm`][channels] selects the package definitions
that determine their versions. The command below uses both to prepare
our development environment and enter it.

On the Linux machine, run this from the directory containing `Makefile`
in your copy of Hello Guix:

```sh
export GUIX=$(command -v guix)

"$GUIX" time-machine --channels=packaging/guix/channels.scm -- \
  shell --pure --preserve='^(TERM|GUIX)$' --manifest=scripts/environment.scm -- \
    bash --norc
```

`GUIX` lets us call your installed Guix command from the new shell,
while leaving your installed packages unchanged. To keep this setup
reproducible across machines, we use the certificates supplied by our
manifest. Once inside, we need to tell Python where to find the
certificates it uses for secure downloads:

```sh
export SSL_CERT_DIR="$GUIX_ENVIRONMENT/etc/ssl/certs"
export SSL_CERT_FILE="$SSL_CERT_DIR/ca-certificates.crt"
test -s "$SSL_CERT_FILE"
```

You remain in the project root. Use this shell for the Guix commands
below, and type `exit` to leave it. Re-enter it after changing the channels
or tool manifest.

### Check Python on macOS

When we assemble the installer on macOS, our Make commands will use the
Python installed there. Check that it is version 3.12 or later:

```sh
python3 --version
```

Make uses `python3` from your `PATH`. If you need another installed
version, set its path in that terminal before running Make:

```sh
export PYTHON=/absolute/path/to/python3
"$PYTHON" --version
```

This choice applies to the later macOS assembly commands too.

## Make and check a change

We’ll continue in the Guix development shell on Linux. Before making a
change, let’s run the Python checks from the project root:

```sh
make check code only=python
```

This runs the Python tests, including checks that our patches and
catalogue work with Asahi’s installer. These checks use temporary files
and simulated disks.

They also run on macOS. Python is the default when `only` is omitted;
we’ll select the Scheme checks separately below.

> Note that our commands follow `make <verb> <noun>`. Run `make help` for
> the full set of combinations and their settings.

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

Outputs go under `build/`. Set `build_dir` to use another folder, and pass
the same setting when checking that image. Guix uses its configured
resource limits unless you supply `jobs` (simultaneous builds) or `cores`
(cores requested for each build). Adding `jobs=1 cores=2` to
`make build image` requests one build at a time with two cores. These
settings also work with `make plan image`.

### Build the installation image

Follow the [image build steps](#build-the-image) below, then return here
to test it. The build saves our source alongside the image, so the same
result can later become part of a release.

The build checks the image before saving it. To check the image, catalogue
and saved source again without booting it, pass the directory you chose:

```sh
make check image build_dir="$build_dir"
```

### Test in a virtual machine

We can exercise installation using disposable virtual disks. Start with
the smaller check, which tests destination preparation and recovery from
interrupted writes:

```sh
make check code only=installation-target
```

The full check runs Guix’s installer and boots the resulting system
through UEFI. It uses a 20 GiB virtual disk and defaults to 6 GiB of guest
RAM, in addition to build space. Leave memory for the host too, and finish
building before running the VM. Use KVM when available: software emulation
can exceed the installation phase’s two-hour timeout.

```sh
make check code only=installation
```

Set `vm_memory` in MiB if the default leaves too little memory for the
host. For example, `make check code only=installation vm_memory=4096`
gives the guest 4 GiB. The installer still checks that it has enough RAM
to load the setup image.

These VMs have no host directory shares or device passthrough. They can
check the installation flow, but Apple Recovery, startup and drivers
still need a real Mac. See the [current hardware coverage][tested] before
choosing what to test there.

## Prepare a release

Let’s now put together the files someone will download to install Hello
Guix on their Mac. Alongside the installer, we’ll prepare a source archive
so they can understand how it was made and build it themselves.

The installation has two parts. Asahi’s installer runs in macOS, sets
aside disk space and prepares the Mac to boot Linux. The Mac then boots
into a temporary Guix system, where the GNU Guix installer guides us
through configuring and installing the system we’ll keep.

We need to bring both parts together for our download. We’ll first build
the temporary Guix system on ARM64 Linux, then carry it to macOS and
assemble it with Asahi’s installer. Finally, we’ll package the complete
installer and its matching source as two downloads.

Each of these stages has its own Make command. We’ll work through them
in order below:

| Command | What it produces |
|---|---|
| `make build image` | The bootable Guix installation system and its saved source |
| `make build installer` | Asahi’s macOS installer assembled with the Guix image |
| `make build package` | The two downloadable archives, launcher and checksums |

### Build the image

Start at the project root on Linux, in the [Guix development
shell](#set-up-the-linux-development-environment). You can come straight
here after preparing your tools. Allow tens of GiB for the build; the
[build settings](#build-and-test-the-installer) explain how to limit
resource use.

Keep the same terminal open for each machine’s steps, so the paths you
set remain available. Resolve any command failure before continuing.

We first save the source and build from that copy, keeping the image tied
to the code that produced it.

Start with the source you intend to release, including any local edits
copied from another machine. Uncommitted changes are saved too. To
reproduce an earlier build, use its saved source.

Choose a fresh directory for this build:

```sh
build_dir=build/image-01
```

First, let’s preview the build steps and where the results will be saved:

```sh
make plan image build_dir="$build_dir"
```

Then build the image:

```sh
make build image build_dir="$build_dir"
```

The resulting *catalogue* in `build/image-01/catalogue/` brings together
the image, its description for Asahi’s installer, checksums and saved
source. This is the directory we’ll carry to macOS.

You can retry an unchanged build in the same directory. After editing
the source, choose a new directory, such as `build/image-02`; the saved
source is not overwritten. Guix reuses unchanged build results even in a
fresh directory. Keep the catalogue unchanged for the remaining steps.

Check the image and its saved source before continuing:

```sh
make check image build_dir="$build_dir"
```

The source download will contain our code, patches and build instructions,
with pinned references to upstream work. Building from it fetches those
dependencies as needed.

### Assemble on macOS

The image is ready, but we still need a way to install it from macOS.
For this we reuse Asahi’s installer and Python runtime, adding our
launcher. In 0.1, we also build libffi from pinned source with a macOS 26
deployment target.

Switch to a normal terminal on macOS with the [tools prepared
earlier](#prepare-your-tools). Set `PYTHON` again if you chose a different
interpreter. Allow space for the catalogue, unpacked runtime, temporary
files and archives.

We’ll give the release a fresh working directory, `release_work`, and copy
the whole catalogue into it. This includes `source-record/`, the saved
source we’ll use for assembly. With SSH access to the Linux builder,
replace the login and remote path below with your own:

```sh
builder=user@linux-builder
remote_catalogue=/absolute/path/to/hello-guix/build/image-01/catalogue
release_work="$HOME/hello-guix-release-01"
mkdir "$release_work"
scp -pr "$builder:$remote_catalogue" "$release_work/"

catalogue="$release_work/catalogue"
assembly="$release_work/assembly"
(cd "$catalogue" && shasum -a 256 -c SHA256SUMS)
```

The checksum command checks that the files arrived intact. We’ll now
build the macOS installer using the source we brought over from Linux.
The `-C` option tells Make which directory to work in.

You can stay in your current directory: Make already knows where to find
the source. We’ll put the assembled files beside the catalogue, in
`$release_work/assembly`. That directory must not already exist.

The catalogue contains the Guix image and our source. We also need
Asahi’s macOS bundle, which supplies Python and its libraries, and the
source for Asahi’s installer. The command below downloads these inputs
and the supporting archives for licences, certificates and libffi,
checks their recorded hashes, and assembles the installer:

```sh
make -C "$catalogue/source-record" build installer \
  catalogue="$catalogue" assembly="$assembly"
```

If you have saved these downloads from an earlier build, you can reuse
them by adding optional settings to that command. Give each setting an
absolute path on your Mac:

- `runtime_archive` selects Asahi’s prebuilt macOS bundle, pinned in
  [`asahi-installer-runtime.json`](../packaging/macos/asahi-installer-runtime.json).
- `source_archive` selects the matching Asahi installer source, pinned in
  [`asahi-installer-source.json`](../packaging/macos/asahi-installer-source.json).
- `runtime_sources` selects a directory of archives used for licences,
  certificates and libffi. Their filenames, URLs and hashes are recorded
  in [`runtime-sources.json`](../packaging/macos/runtime-sources.json).

For each setting you omit, the build downloads that input. If you supply
`runtime_sources`, it must contain every archive needed by this step,
with the filenames recorded in the manifest. Saved downloads undergo
the same checksum checks as new ones.

The resulting `$assembly` directory contains `installer/`, ready to run,
and `source/`, ready for the source download, as described in
[NOTICE](../NOTICE). Beside them, `build.json` records which installer and
sources belong together. Packaging uses this record to check the pair;
it stays in the assembly directory and is not part of either download.

Now check the assembly and its bundled runtime on macOS. This verifies
the files and their matching sources, then checks that Asahi’s installer
can use its bundled Python and libraries to read the installation image:

```sh
make -C "$assembly/source" check installer assembly="$assembly"
```

### Package the downloads

Let’s now turn the assembled files into two downloads. The installer
archive contains Asahi’s macOS installer and the temporary Guix system
used to configure and install Guix System on the Mac. The source archive
contains our code, patches and build instructions, with pinned references
to upstream work, so someone can understand and rebuild the installer.

Alongside these archives, we’ll prepare a small launcher that downloads
and starts the installer, and checksums for the files we’ll publish. The
launcher needs to know where the installer archive will be hosted, so we
set that address in `base_url`.

We’ll use `make -C` as before to run the packaging command from our saved
source in `$assembly/source`. For a GitHub release tagged `v0.1`, use:

```sh
package_dir="$release_work/downloads"
base_url=https://github.com/hnarayanan/hello-guix/releases/download/v0.1
make -C "$assembly/source" build package \
  assembly="$assembly" package_dir="$package_dir" \
  version=0.1 base_url="$base_url"
```

Use your own address if publishing elsewhere. The output directory must
be new and outside the assembly; the version must match the image,
optionally with an `-rcN` suffix. The command creates four files:

- `hello-guix-0.1.tar.gz`, the installer.
- `hello-guix-0.1-src.tar.gz`, the project sources, patches and upstream pins.
- `install.sh`, the download launcher.
- `SHA256SUMS`, their checksums.

Check them before publishing:

```sh
make -C "$assembly/source" check package package_dir="$package_dir"
```

You can stop here if you only wanted to build the downloads. To compare
with an earlier build of the same version, use their checksum files:

```sh
diff -u /path/to/previous-release/SHA256SUMS "$package_dir/SHA256SUMS"
```

No output means the recorded hashes match. A meaningful comparison needs
the same source snapshot, version and download address. We remove archive
timestamps, but 0.1 does not yet guarantee identical bytes from independent
builds: macOS assembly uses your installed Xcode tools, whose versions are
not pinned.

### Publish and check the download

When you’re ready to publish, upload all four files to the address chosen
above. Keep that version unchanged once released, so its links continue
to identify the same files.

For Hello Guix, also copy the generated `install.sh` to
`assets/hello-guix.sh` in the website source. This gives it the stable
address `https://harishnarayanan.org/hello-guix.sh`, while the archive
stays on GitHub. Publish this copy after the release assets are available.

Finally, check the address readers will use from the Mac. The web
launcher takes `--check`, while the bundled launcher above takes `check`:

```sh
launcher_url=https://harishnarayanan.org/hello-guix.sh
curl -fsSL --proto '=https' "$launcher_url" | sh -s -- --check
```

Repeat with `launcher_url="$base_url/install.sh"` to check the copy
published with the release assets too.

The check downloads over HTTPS, verifies the archive and checks the runtime
without starting installation. The verified download is cached for reuse.
To install, run the same pipeline ending in `| sh`, without
`-s -- --check`.

### Verify that exact release on hardware

For the final check, install from the hosted release just as a new user
would. Follow macOS preparation, Apple Recovery and Guix’s installer.
After rebooting, check login, sudo, root and EFI identities, Wi-Fi/DNS,
the desktop environment, audio, Bluetooth, suspend and reconfiguration.
Confirm that other installations remain usable.

Keep the archive hashes and results, and update the [tested
scope][tested]. This connects the release people download to the system
we have actually used.

[install-guix]: https://guix.gnu.org/manual/en/html_node/Binary-Installation.html
[environment]: ../scripts/environment.scm
[channels]: ../packaging/guix/channels.scm
[tested]: installation.md#what-has-been-tested
