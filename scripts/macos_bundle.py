#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Assemble or verify a macOS bundle. Never run an installer."""

import argparse
import gzip
import io
import json
import platform
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from urllib.parse import urlsplit
import zipfile

# Do not add Python cache files to a source snapshot with recorded checksums.
sys.dont_write_bytecode = True

from asahi_payload import check_os, json_bytes, require
from build_inputs import PROJECT, checksum_text, file_hashes, record_snapshot, sha256
from prepare_asahi import apply_adaptations, unpack_source

sys.path.insert(0, str(PROJECT / "src/hello-guix/installer/macos"))
from bundle import check_bundle, inventory


def verify_checksums(directory):
    """Check a saved file inventory independently of the working source."""
    hashes = file_hashes(directory)
    expected = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        require(match is not None, f"Invalid checksum line in {directory}")
        digest, name = match.groups()
        require(name not in expected and name != "SHA256SUMS",
                f"Duplicate or self-referencing checksum: {name}")
        expected[name] = digest
    del hashes["SHA256SUMS"]
    require(hashes == expected, f"Checksum inventory differs: {directory}")


def fetch_archive(local, pin, target):
    if local is not None:
        shutil.copyfile(local, target)
    else:
        print(f"Downloading {pin['url']}", flush=True)
        request = urllib.request.Request(pin["url"], headers={"User-Agent": "hello-guix"})
        with urllib.request.urlopen(request, timeout=60) as response, target.open("wb") as output:
            shutil.copyfileobj(response, output)
    require(sha256(target) == pin["sha256"], f"Archive checksum mismatch: {target.name}")
    if "bytes" in pin:
        require(target.stat().st_size == pin["bytes"], "Runtime archive size differs")


def unpack_runtime(archive, destination):
    """Extract the runtime. Allow framework links, but reject ambiguous paths and special files."""
    with tarfile.open(archive, "r:gz") as stream:
        seen = set()
        for member in stream.getmembers():
            name = member.name.removeprefix("./").rstrip("/")
            if name == ".":
                require(member.isdir(), "Invalid archive root")
                continue
            path = PurePosixPath(name)
            require(name and not path.is_absolute() and ".." not in path.parts
                    and str(path) == name and all(ord(c) >= 32 for c in name),
                    f"Unsafe runtime path: {member.name}")
            require(name.casefold() not in seen, f"Duplicate runtime path: {name}")
            seen.add(name.casefold())
            require(member.isfile() or member.isdir() or member.issym(),
                    f"Special file in runtime archive: {name}")
        # data_filter additionally checks link destinations during extraction.
        stream.extractall(destination, filter="data")
    inventory(destination)


def installer_files(source):
    """Map files to Asahi's release layout. Remove src/ from paths, but keep asahi_firmware/."""
    result = {}
    for directory in (source / "src", source / "asahi_firmware"):
        for path in directory.rglob("*"):
            if path.is_file() and not path.is_symlink():
                name = path.relative_to(source if directory.name == "asahi_firmware" else directory)
                result[name.as_posix()] = path
    return result


def build_libffi(archive, runtime, minimum_macos, cores=None):
    """Build the pinned upstream library with Apple's tools and replace the bundled copy."""
    require(sys.platform == "darwin" and platform.machine() == "arm64",
            "Build the macOS runtime on an Apple Silicon Mac with Xcode Command Line Tools")
    with tempfile.TemporaryDirectory(prefix="hello-guix-libffi-") as temporary:
        work = Path(temporary)
        with tarfile.open(archive) as stream:
            stream.extractall(work, filter="data")
        source, = work.iterdir()
        build = work / "build"
        build.mkdir()
        environment = {
            "HOME": str(Path.home()), "TMPDIR": str(work),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CC": "/usr/bin/clang", "CFLAGS": "-O2 -arch arm64",
            "MACOSX_DEPLOYMENT_TARGET": str(minimum_macos),
        }
        subprocess.run(["/bin/sh", str(source / "configure"), "--disable-static",
                        "--disable-docs", "--prefix=/usr"],
                       cwd=build, env=environment, check=True)
        command = ["/usr/bin/make"]
        if cores is not None:
            command.append(f"-j{cores}")
        subprocess.run(command, cwd=build, env=environment, check=True)
        library = runtime / "Frameworks/Python.framework/Versions/3.13/lib/libffi.8.dylib"
        shutil.copyfile(build / ".libs/libffi.8.dylib", library)
        # Keep the library relocatable. Renew its local signature after changing the name.
        subprocess.run(["/usr/bin/install_name_tool", "-id", "@rpath/libffi.8.dylib",
                        str(library)], env=environment, check=True)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(library)],
                       env=environment, check=True)


def collect_runtime_sources(source_record, bundle, cache=None):
    """Keep upstream sources, collect their notices and install the pinned certificates."""
    manifest = json.loads((source_record / "packaging/macos/runtime-sources.json").read_text())
    destination = source_record / "upstream/runtime"
    destination.mkdir(parents=True)
    notices = bundle / "notices"
    notices.mkdir()
    for entry in manifest["files"]:
        fetch_archive(cache / entry["file"] if cache else None,
                      entry, destination / entry["file"])
        if entry.get("notices"):
            with tarfile.open(destination / entry["file"]) as archive:
                for name, path in entry["notices"].items():
                    member = archive.getmember(path)
                    require(member.isfile(), f"Notice must be a regular file: {path}")
                    target = notices / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(archive.extractfile(member).read())

    # Asahi copies certificates from its build host. Use the complete set
    # from the certifi release in runtime-sources.json.
    certificates = manifest["certificates"]
    with tarfile.open(destination / certificates["archive"]) as archive:
        member = archive.getmember(certificates["member"])
        require(member.isfile(), "Certificate bundle must be a regular file")
        data = archive.extractfile(member).read()
    (bundle / "runtime" / certificates["runtime_path"]).write_bytes(data)
    libffi, = (entry for entry in manifest["files"] if entry["component"] == "libffi")
    return destination / libffi["file"]


def check_catalogue(catalogue):
    verify_checksums(catalogue)
    verify_checksums(catalogue / "source-record")
    entry, _, report = check_os(catalogue / "installer_data.json", catalogue / "os")
    require(entry.get("guix_boot") is True, "Catalogue must select the Guix boot adaptation")
    saved = json.loads((catalogue / "payload-report.json").read_text())
    require(all(saved.get(key) == value for key, value in report.items()),
            "Saved payload report disagrees with the actual archive")
    require(saved.get("source_checksums_sha256") == sha256(catalogue / "source-record/SHA256SUMS"),
            "Payload source record differs from the checked build")
    return saved


def copy_guides(source, bundle, image_source):
    """Keep user guides offline; link to the repository for contributor material."""
    destination = bundle / "docs"
    destination.mkdir()
    repository = "https://github.com/hnarayanan/hello-guix/blob/main/"
    for name in ("installation.md", "configuration.md", "recovery.md", "philosophy.md"):
        text = (source / "docs" / name).read_text()
        for local, remote in (("development.md", "docs/development.md"),
                              ("architecture.md", "docs/architecture.md")):
            text = text.replace("(" + local, "(" + repository + remote)
        text = text.replace("(../packaging/guix/channels.scm)", "(channels.scm)")
        (destination / name).write_text(text)
    shutil.copyfile(source / image_source / "packaging/guix/channels.scm",
                    destination / "channels.scm")


def assemble(catalogue, output, runtime_archive=None, source_archive=None,
             project=PROJECT, runtime_sources=None, cores=None):
    require(not output.exists() and not output.is_symlink(),
            f"Output already exists: {output}. Use check to verify it, or choose a new output.")
    require(not output.resolve().is_relative_to(catalogue.resolve()),
            "Bundle output must be outside the input catalogue")
    payload = check_catalogue(catalogue)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".macos-bundle-", dir=output.parent) as temporary:
        temporary = Path(temporary)
        assembly = temporary / "assembly"
        assembly.mkdir()
        bundle = assembly / "installer"
        bundle.mkdir()
        source_record = assembly / "source"
        record_snapshot(source_record, project, outputs=(temporary, output))
        project_digest = sha256(source_record / "SHA256SUMS")
        pin = json.loads((source_record / "packaging/macos/asahi-installer-runtime.json").read_text())
        source_pin = json.loads((source_record / "packaging/macos/asahi-installer-source.json").read_text())
        require(pin["source_commit"] == source_pin["commit"]
                and pin["release"] == source_pin["release"], "Runtime and source revisions differ")

        runtime_tar = temporary / "runtime.tar.gz"
        source_tar = temporary / "source.tar.gz"
        fetch_archive(runtime_archive, pin, runtime_tar)
        fetch_archive(source_archive, source_pin, source_tar)
        runtime = bundle / "runtime"
        unpack_runtime(runtime_tar, runtime)
        require((runtime / "version.tag").read_text().strip() == pin["release"],
                "Runtime release tag differs")
        for name, digest in pin["files"].items():
            require(sha256(runtime / name) == digest, f"Runtime component differs: {name}")

        source = unpack_source(source_tar, temporary / "upstream", source_pin)
        originals = installer_files(source)
        for name, path in originals.items():
            require(sha256(runtime / name) == sha256(path),
                    f"Runtime source does not match the pinned source: {name}")
        apply_adaptations(source, source_record)
        for name, path in installer_files(source).items():
            target = runtime / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, target)

        print("Copying the checked Guix catalogue...", flush=True)
        destination = bundle / "catalogue"
        destination.mkdir()
        shutil.copytree(catalogue / "os", destination / "os")
        shutil.copyfile(catalogue / "installer_data.json", destination / "installer_data.json")
        _, _, copied = check_os(destination / "installer_data.json", destination / "os")
        require(all(payload.get(key) == value for key, value in copied.items()),
                "Catalogue changed while copying")
        # An older cached image must keep the source that actually built it.
        image_source = "."
        if project_digest != payload["source_checksums_sha256"]:
            image_source = "image-source"
            shutil.copytree(catalogue / "source-record", source_record / image_source)
            verify_checksums(source_record / image_source)
            require(sha256(source_record / image_source / "SHA256SUMS")
                    == payload["source_checksums_sha256"], "Image source changed while copying")
        (source_record / "upstream").mkdir()
        shutil.copyfile(source_tar, source_record / "upstream/asahi-installer.tar.gz")
        libffi_source = collect_runtime_sources(source_record, bundle, runtime_sources)
        shutil.copyfile(source / "LICENSE", bundle / "notices/LICENSE.asahi-installer")
        notices = source_record / "packaging/macos/notices"
        for notice in json.loads((notices / "sources.json").read_text()):
            require(sha256(notices / notice["file"]) == notice["sha256"],
                    f"Upstream notice differs: {notice['file']}")
            shutil.copyfile(notices / notice["file"], bundle / "notices" / notice["file"])
        print("Building libffi from its upstream source...", flush=True)
        build_libffi(libffi_source, runtime, pin["minimum_macos"], cores=cores)
        shutil.copyfile(source_record / "COPYING", bundle / "COPYING")
        shutil.copytree(source_record / "LICENSES", bundle / "LICENSES")
        shutil.copyfile(source_record / "NOTICE", bundle / "NOTICE")
        copy_guides(source_record, bundle, image_source)
        launcher = source_record / "src/hello-guix/installer/macos"
        shutil.copyfile(launcher / "launch.sh", bundle / "install.sh")
        (bundle / "install.sh").chmod(0o755)
        (bundle / "libexec").mkdir()
        for name in ("bundle.py", "runtime_check.py"):
            shutil.copyfile(launcher / name, bundle / "libexec" / name)
        report = {
            "format": 1,
            "kind": payload["kind"],
            "minimum_macos": pin["minimum_macos"],
            "runtime_sha256": pin["sha256"],
            "upstream_source_sha256": source_pin["sha256"],
            "matched_source_files": len(originals),
            "payload": payload,
            "files": inventory(bundle),
        }
        (bundle / "bundle.json").write_bytes(json_bytes(report))
        (source_record / "build.json").write_bytes(json_bytes({
            "format": 1, "installer_sha256": sha256(bundle / "bundle.json"),
            "project_source_sha256": project_digest, "image_source": image_source,
            "payload": payload,
        }))
        (source_record / "SHA256SUMS").unlink()
        (source_record / "SHA256SUMS").write_text(checksum_text(file_hashes(source_record)))
        require(not output.exists() and not output.is_symlink(), "Output appeared during assembly")
        assembly.rename(output)
    return report


def write_archive(directory, destination, name, additions=None):
    """Preserve ordinary files and framework links without host metadata."""
    additions = additions or {}
    def normalise(member):
        member.uid = member.gid = member.mtime = 0
        member.uname = member.gname = ""
        member.pax_headers = {}
        return member

    def select(member):
        relative = member.name.removeprefix(name + "/")
        return None if relative in additions else normalise(member)

    with destination.open("wb") as output, gzip.GzipFile(
            fileobj=output, filename="", mode="wb", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w") as archive:
            archive.add(directory, arcname=name, filter=select)
            for relative, content in sorted(additions.items()):
                if isinstance(content, Path):
                    archive.add(content, arcname=f"{name}/{relative}", filter=normalise)
                else:
                    member = tarfile.TarInfo(f"{name}/{relative}")
                    member.size = len(content)
                    archive.addfile(normalise(member), io.BytesIO(content))


def check_guix_sources(path, package_output):
    """Match a complete collector archive to the image's recorded build output."""
    with gzip.open(path, "rb") as compressed, tarfile.open(fileobj=compressed, mode="r|") as archive:
        first = archive.next()
        require(first is not None and first.name == "guix-sources.json" and first.isfile(),
                "Use the Guix source collector to create an archive with its manifest")
        manifest = json.load(archive.extractfile(first))
        require(manifest.get("format") == 1 and package_output in manifest["outputs"],
                "Guix sources belong to a different image build")
        expected = set(manifest["store_items"])
        require(expected and Path(manifest["derivation"]).name in expected,
                "Guix sources are missing their root derivation")
        seen = set()
        # Read the entire stream to catch truncation and missing source inputs.
        for member in archive:
            if member is first:
                continue
            parts = PurePosixPath(member.name).parts
            require(parts and parts[0] in expected and ".." not in parts,
                    f"Unexpected Guix source entry: {member.name}")
            seen.add(parts[0])
        require(seen == expected, "Guix source archive is incomplete")
        # Tar ends before gzip's checksum and length trailer.
        while compressed.read(1024 * 1024):
            pass


def check_assembly(assembly):
    bundle, source = assembly / "installer", assembly / "source"
    report = check_bundle(bundle)
    verify_checksums(source)
    build = json.loads((source / "build.json").read_text())
    require(build.get("format") == 1
            and build["installer_sha256"] == sha256(bundle / "bundle.json")
            and build["payload"] == report["payload"], "Installer and source do not match")
    return report


def release(assembly, output, version, base_url, guix_sources):
    """Package the checked bundle and a launcher that downloads this release through HTTPS."""
    require(re.fullmatch(r"[0-9][A-Za-z0-9.-]*", version), "Invalid release version")
    url = urlsplit(base_url)
    require(url.scheme == "https" and url.hostname and not url.username
            and not url.password and not url.query and not url.fragment
            and not any(c.isspace() for c in base_url), "Use an HTTPS release directory URL")
    require(not output.exists() and not output.is_symlink(), "Release output already exists")
    require(not output.resolve().is_relative_to(assembly.resolve()), "Release must be outside the assembly")
    report = check_assembly(assembly)
    bundle, source = assembly / "installer", assembly / "source"
    base_version = re.sub(r"-rc[1-9][0-9]*$", "", version)
    entries = json.loads((bundle / "catalogue/installer_data.json").read_text())["os_list"]
    require(len(entries) == 1 and entries[0]["name"] == f"Guix System (Hello Guix {base_version})",
            "Release version must match the catalogue version (optionally -rcN)")
    minimum_macos = report["minimum_macos"]
    require(type(minimum_macos) is int and minimum_macos >= 11, "Invalid minimum macOS version")
    check_guix_sources(guix_sources, report["payload"]["package_output"])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".release-", dir=output.parent) as temporary:
        directory = Path(temporary) / "release"
        directory.mkdir()
        archive = directory / f"hello-guix-{version}.tar.gz"
        write_archive(bundle, archive, "hello-guix")
        source_hashes = file_hashes(source)
        del source_hashes["SHA256SUMS"]
        source_hashes["upstream/guix-build-sources.tar.gz"] = sha256(guix_sources)
        write_archive(source, directory / f"hello-guix-{version}-src.tar.gz",
                      f"hello-guix-{version}-src", {
                          "upstream/guix-build-sources.tar.gz": guix_sources,
                          "SHA256SUMS": checksum_text(source_hashes).encode(),
                      })
        template = (source / "src/hello-guix/installer/macos/bootstrap.sh").read_text()
        bootstrap = template.replace("@ARCHIVE_URL@", shlex.quote(base_url.rstrip("/") + "/" + archive.name))
        bootstrap = bootstrap.replace("@ARCHIVE_SHA256@", shlex.quote(sha256(archive)))
        bootstrap = bootstrap.replace("@MINIMUM_MACOS@", str(minimum_macos))
        # Allow space for extraction and the launcher's separate runtime copy.
        # The margin covers filesystem overhead and temporary files.
        def file_bytes(tree):
            return sum(p.stat().st_size for p in tree.rglob("*")
                       if p.is_file() and not p.is_symlink())
        archive_kib = (archive.stat().st_size + 1023) // 1024
        work_kib = (file_bytes(bundle) + file_bytes(bundle / "runtime") + 1023) // 1024 + 512 * 1024
        bootstrap = bootstrap.replace("@ARCHIVE_KIB@", str(archive_kib))
        bootstrap = bootstrap.replace("@WORK_KIB@", str(work_kib))
        (directory / "install.sh").write_text(bootstrap)
        (directory / "SHA256SUMS").write_text(checksum_text(file_hashes(directory)))
        directory.rename(output)


def positive_integer(value):
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("use a positive integer") from None
    if number <= 0:
        raise argparse.ArgumentTypeError("use a positive integer")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build", help="assemble a new directory from verified inputs")
    build.add_argument("--catalogue", required=True, type=Path)
    build.add_argument("--output", required=True, type=Path)
    build.add_argument("--runtime-archive", type=Path)
    build.add_argument("--source-archive", type=Path)
    build.add_argument("--runtime-sources", type=Path,
                       help="reuse files from packaging/macos/runtime-sources.json")
    build.add_argument("--cores", type=positive_integer,
                       help="limit parallel libffi build jobs; otherwise use Make’s default")
    check = commands.add_parser("check", help="verify an installer or its paired source assembly")
    target = check.add_mutually_exclusive_group(required=True)
    target.add_argument("--bundle", type=Path)
    target.add_argument("--assembly", type=Path)
    saved = commands.add_parser("check-release", help="verify the release checksum inventory")
    saved.add_argument("--directory", required=True, type=Path)
    publish = commands.add_parser("release", help="package a bundle; does not upload or launch it")
    publish.add_argument("--assembly", required=True, type=Path)
    publish.add_argument("--guix-sources", required=True, type=Path,
                         help="complete source collector archive for this image")
    publish.add_argument("--output", required=True, type=Path)
    publish.add_argument("--version", required=True)
    publish.add_argument("--base-url", required=True, help="HTTPS directory where these files will be hosted")
    args = parser.parse_args()
    try:
        if args.command == "build":
            report = assemble(args.catalogue, args.output, args.runtime_archive,
                              args.source_archive, runtime_sources=args.runtime_sources,
                              cores=args.cores)
            print(f"Installer assembled: {args.output / 'installer'}")
            print(f"Source prepared: {args.output / 'source'}")
        elif args.command == "release":
            release(args.assembly, args.output, args.version, args.base_url, args.guix_sources)
            print(f"Release files prepared: {args.output}. Nothing was uploaded or launched.")
            return
        elif args.command == "check-release":
            verify_checksums(args.directory)
            print(f"Release checksum inventory verified: {args.directory}")
            return
        elif args.assembly is not None:
            report = check_assembly(args.assembly)
            print(f"Installer and source verified: {args.assembly}")
        else:
            report = check_bundle(args.bundle)
            print(f"Bundle verified: {args.bundle}")
        print(f"Payload SHA-256: {report['payload']['sha256']}")
        print(f"{report['kind']}. No installer or device operation was run.")
    except (OSError, EOFError, ValueError, KeyError, TypeError, tarfile.TarError, zipfile.BadZipFile,
            subprocess.CalledProcessError) as error:
        parser.exit(1, f"Bundle check failed: {error}\n")


if __name__ == "__main__":
    main()
