# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Test bundle assembly with temporary files. Do not start macOS preparation."""

import contextlib
import io
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT / "scripts"))
from asahi_payload import stage
from build_inputs import checksum_text, file_hashes, record_snapshot, sha256, source_files
from macos_bundle import (assemble, build_libffi, check_assembly, check_bundle, check_catalogue,
                          inventory, main, release, unpack_runtime, verify_checksums)
import payload_fixtures as fixtures


def archive_files(path, files):
    with tarfile.open(path, "w:gz") as archive:
        for name, value in files.items():
            member = tarfile.TarInfo(name)
            if isinstance(value, tuple):
                member.type = tarfile.SYMTYPE
                member.linkname = value[0]
            else:
                member.size = len(value)
            archive.addfile(member, None if isinstance(value, tuple) else io.BytesIO(value))


class MacOSBundleTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        for name in source_files(PROJECT):
            target = self.project / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, target)

        self.source_tar = self.root / "source.tar.gz"
        self.runtime_tar = self.root / "runtime.tar.gz"
        self.source_files = {"asahi-installer-test/src/main.py": b"upstream = True\n",
                             "asahi-installer-test/LICENSE": b"fixture licence\n"}
        self.libffi_path = "Frameworks/Python.framework/Versions/3.13/lib/libffi.8.dylib"
        self.runtime_files = {"./" + self.libffi_path: b"original library",
                              "./main.py": b"upstream = True\n", "./version.tag": b"test\n",
                              "./Frameworks/version/file": b"framework fixture",
                              "./Frameworks/current": ("version",)}
        archive_files(self.source_tar, self.source_files)
        archive_files(self.runtime_tar, self.runtime_files)
        self.write_pins()
        self.runtime_sources = self.root / "runtime-sources"
        self.runtime_sources.mkdir()
        libffi = self.runtime_sources / "libffi.tar.gz"
        self.upstream_notice = b"Copyright upstream author\r\nPermission to redistribute.\r\n"
        archive_files(libffi, {"libffi/source.c": b"upstream source",
                              "libffi/LICENSE": self.upstream_notice})
        self.libffi_archive = libffi.read_bytes()
        certificates = self.runtime_sources / "certifi.tar.gz"
        archive_files(certificates, {"certifi/cacert.pem": b"recorded certificates\n"})
        (self.project / "packaging/macos/runtime-sources.json").write_text(json.dumps({
            "files": [{"component": "certifi", "file": certificates.name,
                       "sha256": sha256(certificates), "bytes": certificates.stat().st_size},
                      {"component": "libffi", "file": libffi.name, "sha256": sha256(libffi),
                       "bytes": libffi.stat().st_size,
                       "notices": {"LICENSE.libffi": "libffi/LICENSE"}}],
            "certificates": {"archive": certificates.name, "member": "certifi/cacert.pem",
                             "runtime_path": "Frameworks/version/file"}}))
        adaptations = self.project / "patches/asahi-macos-installer"
        (adaptations / "patches/series").write_text("test.patch\n")
        (adaptations / "patches/test.patch").write_text(
            "--- a/src/main.py\n+++ b/src/main.py\n@@ -1 +1 @@\n"
            "-upstream = True\n+upstream = 'adapted'\n")

        package = self.root / "package"
        files = package / fixtures.PACKAGE_DIRECTORY
        files.mkdir(parents=True)
        (files / "description.json").write_text(json.dumps({"os_list": [fixtures.ENTRY]}))
        with zipfile.ZipFile(files / "guix-setup.zip", "w") as archive:
            archive.writestr("guix.icns", b"icns")
            archive.writestr("Guix_image.img", fixtures.root_image())
            for path, content in fixtures.ram_files().items():
                archive.writestr(path, content)
            archive.writestr("esp/m1n1/boot.bin", b"fixture")
            archive.writestr("esp/EFI/BOOT/BOOTAA64.EFI", fixtures.efi_image())
        self.inputs = self.root / "image-source"
        record_snapshot(self.inputs, self.project)
        self.catalogue = self.root / "catalogue"
        stage(package, self.catalogue, self.inputs, self.project)
        self.assembly = self.root / "assembly with spaces"
        self.output = self.assembly / "installer"
        self.source = self.assembly / "source"
        # Keep assembly tests portable; the native build is checked on macOS.
        builder = patch("macos_bundle.build_libffi", side_effect=self.replace_libffi)
        self.libffi_build = builder.start()
        self.addCleanup(builder.stop)

    def replace_libffi(self, archive, runtime, minimum_macos, cores=None):
        self.assertEqual(archive.read_bytes(), self.libffi_archive)
        self.assertEqual(minimum_macos, 26)
        (runtime / self.libffi_path).write_bytes(b"upstream build")

    def write_pins(self):
        common = {"release": "test", "url": "https://invalid.example/unused"}
        (self.project / "packaging/macos/asahi-installer-source.json").write_text(json.dumps({
            **common, "commit": "test", "sha256": sha256(self.source_tar)}))
        (self.project / "packaging/macos/asahi-installer-runtime.json").write_text(json.dumps({
            **common, "source_commit": "test", "sha256": sha256(self.runtime_tar),
            "bytes": self.runtime_tar.stat().st_size, "minimum_macos": 26, "files": {}}))

    def build(self, **options):
        with contextlib.redirect_stdout(io.StringIO()):
            return assemble(self.catalogue, self.assembly, self.runtime_tar,
                            self.source_tar, self.project,
                            runtime_sources=self.runtime_sources, **options)

    def run_cli(self, *arguments):
        return subprocess.run([sys.executable, "-B", str(PROJECT / "scripts/macos_bundle.py"),
                               *map(str, arguments)], capture_output=True, text=True)

    def test_cli_checks_installer_and_matching_sources(self):
        self.build()
        result = self.run_cli("check", "--assembly", self.assembly)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Installer and source verified", result.stdout)
        (self.source / "README.md").write_text("changed after assembly")
        result = self.run_cli("check", "--assembly", self.assembly)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum inventory differs", result.stderr)
        result = self.run_cli("check", "--bundle", self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_cli("check", "--bundle", self.output, "--assembly", self.assembly)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not allowed with argument", result.stderr)

    def test_explicit_build_cores_reach_libffi(self):
        self.build(cores=3)
        self.assertEqual(self.libffi_build.call_args.kwargs, {"cores": 3})

    def test_source_archive_can_supply_another_snapshot_without_git(self):
        (self.project / "README.md").write_text("updated launcher source\n")
        # Exercise a custom output inside the project, outside its default build directory.
        self.assembly = self.project / "local outputs/assembly"
        self.build()
        release_dir = self.root / "release"
        release(self.assembly, release_dir, "0.1", "https://example.org/0.1")
        extracted = self.root / "extracted"
        with tarfile.open(release_dir / "hello-guix-0.1-src.tar.gz") as archive:
            archive.extractall(extracted, filter="data")
        source = extracted / "hello-guix-0.1-src"
        self.assertEqual(file_hashes(source / "image-source"), file_hashes(self.inputs))
        self.assertFalse((source / "upstream").exists())
        self.assertTrue((source / "build.json").is_file())
        self.assertFalse((source / ".git").exists())
        snapshot = source / "build/source-record"
        record_snapshot(snapshot, source)
        self.assertEqual(source_files(source), source_files(snapshot))
        self.assertEqual((snapshot / "README.md").read_text(), "updated launcher source\n")
        for name in ("image-source", "build.json"):
            self.assertFalse((snapshot / name).exists())

    def test_only_installation_bundles_are_accepted(self):
        report = self.build()
        self.assertEqual(report["kind"], "installation")
        self.assertEqual(check_bundle(self.output), report)
        report["kind"] = report["payload"]["kind"] = "unknown-kind"
        (self.output / "bundle.json").write_text(json.dumps(report))
        with self.assertRaisesRegex(ValueError, "Unrecognized bundle format"):
            check_bundle(self.output)

    def test_installer_is_independent_of_development_sources(self):
        report = self.build()
        self.assertEqual(check_assembly(self.assembly), report)
        self.assertEqual(set(p.name for p in self.output.iterdir()), {
            "install.sh", "bundle.json", "libexec", "runtime", "catalogue",
            "docs", "COPYING", "LICENSES", "NOTICE", "notices",
        })
        self.assertEqual(set(p.name for p in (self.output / "catalogue").iterdir()),
                         {"installer_data.json", "os"})
        self.assertEqual(set(p.name for p in (self.output / "docs").iterdir()),
                         {"installation.md", "configuration.md", "recovery.md",
                          "philosophy.md", "channels.scm"})
        self.assertFalse((self.source / "image-source").exists())
        self.assertTrue((self.source / "tests/test_macos_bundle.py").is_file())
        self.assertFalse((self.source / "upstream").exists())
        for name in ("asahi-installer-source.json", "asahi-installer-runtime.json",
                     "runtime-sources.json"):
            with self.subTest(pin=name):
                self.assertEqual((self.source / "packaging/macos" / name).read_bytes(),
                                 (self.project / "packaging/macos" / name).read_bytes())
        shutil.rmtree(self.source)
        self.assertEqual(check_bundle(self.output), report)
        subprocess.run([sys.executable, "-I", "-B", str(self.output / "libexec/bundle.py"),
                        "--bundle", str(self.output)], check=True, capture_output=True)

    def test_image_source_record_and_launcher_source_record_are_separate(self):
        (self.project / "README.md").write_text("new documentation\n")
        (self.project / "packaging/guix/channels.scm").write_text("new pins\n")
        image_record = (self.catalogue / "source-record/README.md").read_bytes()
        report = self.build()
        self.assertEqual(check_bundle(self.output), report)
        self.assertEqual((self.source / "image-source/README.md").read_bytes(), image_record)
        self.assertEqual((self.source / "README.md").read_text(), "new documentation\n")
        self.assertEqual((self.output / "docs/channels.scm").read_bytes(),
                         (self.catalogue / "source-record/packaging/guix/channels.scm").read_bytes())
        self.assertEqual((self.output / "runtime/main.py").read_text(), "upstream = 'adapted'\n")
        self.assertTrue((self.output / "runtime/guix_boot.py").is_file())
        self.assertTrue((self.output / "runtime/Frameworks/current").is_symlink())
        self.assertEqual((self.output / "runtime/Frameworks/current/file").read_bytes(),
                         b"recorded certificates\n")
        self.assertFalse((self.source / "upstream").exists())
        for name in ("COPYING", "LICENSES/GPL-3.0-or-later.txt", "LICENSES/MIT.txt"):
            with self.subTest(name=name):
                self.assertEqual((self.output / name).read_bytes(),
                                 (self.project / name).read_bytes())
        self.assertEqual((self.output / "NOTICE").read_bytes(),
                         (self.project / "NOTICE").read_bytes())
        # REUSE-IgnoreStart
        self.assertIn("SPDX-License-Identifier: MIT",
                      (self.output / "runtime/guix_boot.py").read_text())
        # REUSE-IgnoreEnd

    def test_cached_runtime_inputs_are_reused_without_fetching_unused_sources(self):
        path = self.project / "packaging/macos/runtime-sources.json"
        manifest = json.loads(path.read_text())
        # Tcl's sources are recorded upstream, but provide no files we consume.
        manifest["files"].append({"component": "Tcl", "file": "tcl.tar.gz",
                                  "sha256": "0" * 64, "bytes": 42,
                                  "url": "https://invalid.example/unused"})
        path.write_text(json.dumps(manifest))
        cached = file_hashes(self.runtime_sources)
        installer_inputs = {path: sha256(path) for path in (self.source_tar, self.runtime_tar)}
        with patch("macos_bundle.urllib.request.urlopen") as download:
            self.build()
        download.assert_not_called()
        self.assertEqual(file_hashes(self.runtime_sources), cached)
        self.assertEqual({path: sha256(path) for path in installer_inputs}, installer_inputs)
        self.assertFalse((self.source / "upstream").exists())
        self.assertEqual((self.output / "notices/LICENSE.libffi").read_bytes(),
                         self.upstream_notice)
        self.assertEqual((self.output / "runtime/Frameworks/current/file").read_bytes(),
                         b"recorded certificates\n")

    def test_missing_required_cache_input_does_not_trigger_a_download(self):
        (self.runtime_sources / "certifi.tar.gz").unlink()
        with patch("macos_bundle.urllib.request.urlopen") as download:
            with self.assertRaises(FileNotFoundError):
                self.build()
        download.assert_not_called()
        self.libffi_build.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_runtime_source_size_is_checked_before_use(self):
        path = self.project / "packaging/macos/runtime-sources.json"
        manifest = json.loads(path.read_text())
        manifest["files"][1]["bytes"] += 1
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "size differs"):
            self.build()
        self.libffi_build.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_libffi_is_replaced_and_recorded(self):
        report = self.build()
        self.libffi_build.assert_called_once()
        library = self.output / "runtime" / self.libffi_path
        self.assertEqual(library.read_bytes(), b"upstream build")
        self.assertEqual(report["files"]["runtime/" + self.libffi_path]["sha256"], sha256(library))

    def test_notices_preserve_upstream_text_and_attribution(self):
        self.build()
        notices = self.output / "notices"
        self.assertEqual((notices / "LICENSE.libffi").read_bytes(), self.upstream_notice)
        for name in ("LICENSE.python-asn1", "python-asn1-AUTHORS.rst"):
            self.assertEqual((notices / name).read_bytes(),
                             (self.project / "packaging/macos/notices" / name).read_bytes())
        (notices / "LICENSE.libffi").unlink()
        with self.assertRaisesRegex(ValueError, "LICENSE.libffi"):
            check_bundle(self.output)

    def test_missing_or_linked_notice_stops_assembly(self):
        for files, error in (({"libffi/source.c": b"source"}, KeyError),
                             ({"libffi/LICENSE": ("source.c",)}, ValueError)):
            with self.subTest(files=files):
                archive = self.runtime_sources / "libffi.tar.gz"
                archive_files(archive, files)
                path = self.project / "packaging/macos/runtime-sources.json"
                manifest = json.loads(path.read_text())
                manifest["files"][1]["sha256"] = sha256(archive)
                manifest["files"][1]["bytes"] = archive.stat().st_size
                path.write_text(json.dumps(manifest))
                with self.assertRaises(error):
                    self.build()
                self.libffi_build.assert_not_called()
                self.assertFalse(self.output.exists())

    def test_libffi_build_failure_never_publishes_original_library(self):
        self.libffi_build.side_effect = subprocess.CalledProcessError(1, "make")
        with self.assertRaises(subprocess.CalledProcessError):
            self.build()
        self.assertFalse(self.output.exists())

    def test_bad_libffi_source_never_builds(self):
        (self.runtime_sources / "libffi.tar.gz").write_bytes(b"wrong source")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.build()
        self.libffi_build.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_bad_runtime_digest_never_publishes(self):
        self.runtime_tar.write_bytes(b"bad archive")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.build()
        self.assertFalse(self.output.exists())

    def test_bad_runtime_source_never_publishes(self):
        (self.runtime_sources / "certifi.tar.gz").write_bytes(b"wrong source")
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            self.build()
        self.assertFalse(self.output.exists())

    def test_source_mismatch_never_publishes(self):
        self.runtime_files["./main.py"] = b"different upstream\n"
        archive_files(self.runtime_tar, self.runtime_files)
        self.write_pins()
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.build()
        self.assertFalse(self.output.exists())

    def test_changed_catalogue_stops_before_fetching_inputs(self):
        (self.catalogue / "os/guix-setup.zip").write_bytes(b"wrong ZIP")
        with patch("macos_bundle.fetch_archive") as fetch, \
                self.assertRaisesRegex(ValueError, "inventory differs"):
            self.build()
        fetch.assert_not_called()
        self.assertFalse(self.assembly.exists())

    def test_changed_bundle_and_unknown_files_are_rejected(self):
        self.build()
        path = self.output / "runtime/main.py"
        original = path.read_bytes()
        path.write_text("changed")
        with self.assertRaisesRegex(ValueError, "runtime/main.py"):
            check_bundle(self.output)
        path.write_bytes(original)
        (self.output / "unexpected").write_text("extra")
        with self.assertRaisesRegex(ValueError, "unexpected"):
            check_bundle(self.output)

    def test_existing_bundle_is_preserved(self):
        self.assembly.mkdir()
        marker = self.assembly / "keep"
        marker.write_text("keep")
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.build()
        self.assertEqual(marker.read_text(), "keep")

    def test_bundle_verifier_runs_without_build_tools(self):
        self.build()
        checker = self.root / "check.py"
        shutil.copyfile(self.output / "libexec/bundle.py",
                        checker)
        command = [sys.executable, "-I", "-B", str(checker), "--bundle", str(self.output)]
        result = subprocess.run(command, cwd=self.root, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Bundle verified", result.stdout)

        (self.output / "runtime/main.py").write_text("changed")
        result = subprocess.run(command, cwd=self.root, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Bundle files changed: runtime/main.py", result.stderr)

    def test_output_inside_catalogue_cannot_copy_itself(self):
        self.assembly = self.catalogue / "assembly"
        with self.assertRaisesRegex(ValueError, "outside the input catalogue"):
            self.build()
        self.assertFalse(self.output.exists())

    def test_executable_changes_are_detected(self):
        self.build()
        (self.output / "install.sh").chmod(0o644)
        with self.assertRaisesRegex(ValueError, "install.sh"):
            check_bundle(self.output)

    def test_release_preserves_bundle_and_pins_its_download(self):
        report = self.build()
        destination = self.root / "release"
        release(self.assembly, destination, "0.1-rc2", "https://releases.example/0.1-rc2")
        verify_checksums(destination)
        result = self.run_cli("check-release", "--directory", destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Release checksum inventory verified", result.stdout)
        (destination / "extra").write_text("unlisted")
        result = self.run_cli("check-release", "--directory", destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum inventory differs", result.stderr)
        (destination / "extra").unlink()
        archive = destination / "hello-guix-0.1-rc2.tar.gz"
        script = (destination / "install.sh").read_text()
        self.assertIn("https://releases.example/0.1-rc2/" + archive.name, script)
        self.assertIn(sha256(archive), script)
        self.assertNotIn("@ARCHIVE_", script)
        self.assertNotIn("@WORK_", script)
        self.assertNotIn("@MINIMUM_MACOS@", script)
        self.assertIn("minimum_macos=26", script)
        subprocess.run(["/bin/sh", "-n", str(destination / "install.sh")], check=True)
        with tarfile.open(archive) as stream:
            stream.extractall(self.root / "extracted", filter="data")
        self.assertEqual(check_bundle(self.root / "extracted/hello-guix"), report)
        with tarfile.open(destination / "hello-guix-0.1-rc2-src.tar.gz") as stream:
            stream.extractall(self.root / "source", filter="data")
        verify_checksums(self.root / "source/hello-guix-0.1-rc2-src")
        extracted = self.root / "source/hello-guix-0.1-rc2-src"
        expected = {name.as_posix() for name in source_files(self.project)}
        self.assertEqual(set(file_hashes(extracted)), expected | {"SHA256SUMS", "build.json"})
        self.assertEqual(file_hashes(extracted), file_hashes(self.source))
        build = json.loads((extracted / "build.json").read_text())
        self.assertEqual(build["payload"], report["payload"])
        self.assertEqual(build["installer_sha256"], sha256(self.output / "bundle.json"))
        self.assertEqual(build["image_source"], ".")
        self.assertFalse((extracted / "upstream").exists())
        self.assertFalse((extracted / "runtime").exists())
        self.assertEqual(set(p.name for p in destination.iterdir()), {
            "hello-guix-0.1-rc2.tar.gz", "hello-guix-0.1-rc2-src.tar.gz",
            "install.sh", "SHA256SUMS",
        })

    def test_make_builds_and_checks_release_from_existing_assembly(self):
        self.build()
        destination = self.root / "release files"
        environment = {
            "PATH": os.defpath, "HOME": str(self.root), "TMPDIR": str(self.root),
            "PYTHON": sys.executable, "PYTHONDONTWRITEBYTECODE": "1",
        }

        def make(*goals, **settings):
            return subprocess.run([shutil.which("make"), "--no-print-directory", *goals,
                                   *(f"{name}={value}" for name, value in settings.items())],
                                  cwd=PROJECT, env=environment, capture_output=True, text=True)

        # Everything needed is local; the URL is written into the launcher only.
        result = make("build", "release", assembly=self.assembly, release_dir=destination,
                      version="0.1", base_url="https://invalid.example")
        self.assertEqual(result.returncode, 0, result.stderr)
        for noun, settings in (("installer", {"assembly": self.assembly}),
                               ("release", {"release_dir": destination})):
            with self.subTest(noun=noun):
                result = make("check", noun, **settings)
                self.assertEqual(result.returncode, 0, result.stderr)
        (destination / "install.sh").write_text("changed after release assembly")
        result = make("check", "release", release_dir=destination)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Checksum inventory differs", result.stderr)

    def test_release_rejects_old_source_layout_even_with_valid_checksums(self):
        self.build()
        upstream = self.source / "upstream"
        upstream.mkdir()
        shutil.copyfile(self.source_tar, upstream / "asahi-installer.tar.gz")
        hashes = file_hashes(self.source)
        del hashes["SHA256SUMS"]
        (self.source / "SHA256SUMS").write_text(checksum_text(hashes))
        verify_checksums(self.source)
        destination = self.root / "release"
        with self.assertRaisesRegex(ValueError, "Unclassified project path: upstream"):
            release(self.assembly, destination, "0.1", "https://releases.example")
        self.assertFalse(destination.exists())

    def test_release_rejects_changed_or_unpaired_project_sources(self):
        self.build()
        destination = self.root / "release"
        readme = self.source / "README.md"
        original = readme.read_bytes()
        readme.write_text("changed after assembly")
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            release(self.assembly, destination, "0.1", "https://releases.example")
        readme.write_bytes(original)
        report = json.loads((self.output / "bundle.json").read_text())
        report["minimum_macos"] = 27
        (self.output / "bundle.json").write_text(json.dumps(report))
        with self.assertRaisesRegex(ValueError, "Installer and source do not match"):
            release(self.assembly, destination, "0.1", "https://releases.example")
        self.assertFalse(destination.exists())

    def test_release_refuses_a_different_version(self):
        self.build()
        destination = self.root / "release"
        for version in ("0.2", "0.10", "0.1-anything", "0.1-rc0"):
            with self.subTest(version=version), self.assertRaisesRegex(ValueError, "catalogue version"):
                release(self.assembly, destination, version, "https://releases.example")
            self.assertFalse(destination.exists())

    def test_release_refuses_changed_bundle_or_insecure_host(self):
        self.build()
        destination = self.root / "release"
        for url in ("http://releases.example", "file:///tmp", "https://user:password@releases.example"):
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "HTTPS"):
                release(self.assembly, destination, "0.1", url)
            self.assertFalse(destination.exists())
        (self.output / "runtime/main.py").write_text("changed")
        with self.assertRaisesRegex(ValueError, "runtime/main.py"):
            release(self.assembly, destination, "0.1", "https://releases.example")
        self.assertFalse(destination.exists())

    def test_bootstrap_reuses_verified_download_and_rejects_corruption(self):
        # Test the shell bootstrap with a small archive. Replace macOS commands,
        # downloads, and the launcher with test scripts. No installer can run.
        tools = self.root / "tools"
        tools.mkdir()
        payload = self.root / "download.tar.gz"
        archive_files(payload, {"hello-guix/install.sh":
                               b'printf "%s\\n" "$1" >> "$HOME/launches"\n'})
        digest = sha256(payload)
        stubs = {
            "uname": "echo Darwin",
            "arch": "exit 0",
            "sw_vers": 'echo "${TEST_MACOS_VERSION:-26.0}"',
            "df": 'printf "Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 9000000 0 %s 0%% /\\n" "${TEST_FREE_KIB:-9000000}"',
            "caffeinate": 'shift; exec "$@"',
            "curl": 'echo download >> "$HOME/downloads"\n'
                    'while [ "$1" != --output ]; do shift; done\n'
                    'cp "$HOME/download.tar.gz" "$2"',
            "tar": f'shift 2; exec {shlex.quote(shutil.which("tar"))} "$@"',
        }
        # Guix supplies sha256sum; macOS supplies shasum.
        if not shutil.which("shasum"):
            stubs["shasum"] = 'shift 2; exec sha256sum "$@"'
        for name, body in stubs.items():
            tool = tools / name
            tool.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
            tool.chmod(0o700)
        template = (PROJECT / "src/hello-guix/installer/macos/bootstrap.sh").read_text()
        template = template.replace("export PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                                    "export PATH=" + shlex.quote(str(tools) + ":" + os.environ["PATH"]))
        script = self.root / "bootstrap.sh"
        script.write_text(template.replace("@ARCHIVE_URL@", "https://example.invalid/installer")
                          .replace("@ARCHIVE_SHA256@", digest)
                          .replace("@MINIMUM_MACOS@", "26")
                          .replace("@ARCHIVE_KIB@", "10").replace("@WORK_KIB@", "100"))
        environment = {**os.environ, "HOME": str(self.root), "TMPDIR": str(self.root)}
        def run():
            return subprocess.run(["sh", str(script), "--check"], env=environment,
                                  capture_output=True, text=True)
        environment["TEST_MACOS_VERSION"] = "25.7"
        result = run()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires macOS 26", result.stderr)
        self.assertFalse((self.root / "downloads").exists())
        self.assertFalse((self.root / "launches").exists())
        environment.pop("TEST_MACOS_VERSION")
        for available in ("50", "unknown"):
            environment["TEST_FREE_KIB"] = available
            result = run()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("free", result.stderr)
            self.assertFalse((self.root / "downloads").exists())
            self.assertFalse((self.root / "launches").exists())
        environment.pop("TEST_FREE_KIB")
        for _ in range(2):
            result = run()
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "downloads").read_text().splitlines(), ["download"])
        self.assertEqual((self.root / "launches").read_text().splitlines(), ["check", "check"])
        cache = self.root / "Library/Caches/Hello Guix" / (digest + ".tar.gz")
        # df accounts for the cached archive. Only extraction needs more space.
        environment["TEST_FREE_KIB"] = "100"
        self.assertEqual(run().returncode, 0)
        environment.pop("TEST_FREE_KIB")
        cache.write_bytes(b"damaged cache")
        self.assertEqual(run().returncode, 0)
        self.assertEqual(sha256(cache), digest)
        cache.write_bytes(b"damaged cache")
        payload.write_bytes(b"damaged download")
        self.assertNotEqual(run().returncode, 0)
        self.assertEqual(len((self.root / "launches").read_text().splitlines()), 4)
        self.assertEqual(list(cache.parent.glob(".download-*")), [])

        # A changed release has a different digest, even at the same URL.
        archive_files(payload, {"hello-guix/install.sh": b'echo new-release >> "$HOME/launches"\n'})
        new_digest = sha256(payload)
        script.write_text(script.read_text().replace(digest, new_digest))
        self.assertEqual(run().returncode, 0)
        self.assertEqual(sha256(cache.parent / (new_digest + ".tar.gz")), new_digest)
        self.assertEqual((self.root / "launches").read_text().splitlines()[-1], "new-release")

    def test_framework_link_cannot_escape(self):
        self.runtime_files["./Frameworks/current"] = ("../../outside",)
        archive_files(self.runtime_tar, self.runtime_files)
        with self.assertRaises((ValueError, tarfile.FilterError)):
            unpack_runtime(self.runtime_tar, self.root / "unpacked")

    def test_path_traversal_and_case_aliases_are_rejected(self):
        for extra in ("../escape", "./MAIN.py", "./ambiguous//file"):
            with self.subTest(extra=extra):
                archive_files(self.runtime_tar, {**self.runtime_files, extra: b"bad"})
                with self.assertRaises(ValueError):
                    unpack_runtime(self.runtime_tar, self.root / "unpacked")

    def test_special_files_are_rejected(self):
        with tarfile.open(self.runtime_tar, "w:gz") as archive:
            member = tarfile.TarInfo("fifo")
            member.type = tarfile.FIFOTYPE
            archive.addfile(member)
        with self.assertRaisesRegex(ValueError, "Special file"):
            unpack_runtime(self.runtime_tar, self.root / "unpacked")

    def test_checksum_list_cannot_hide_an_extra_file(self):
        (self.catalogue / "extra").write_text("unlisted")
        with self.assertRaisesRegex(ValueError, "inventory differs"):
            verify_checksums(self.catalogue)

    def test_smoke_probe_refuses_import_side_effects(self):
        bundle = self.root / "probe"
        (bundle / "runtime").mkdir(parents=True)
        marker = self.root / "should-not-exist"
        main = bundle / "runtime/main.py"
        for code in (f"open({str(marker)!r}, 'w')",
                     "import subprocess; subprocess.run(['/usr/bin/true'])"):
            with self.subTest(code=code):
                main.write_text(code)
                result = subprocess.run([sys.executable, "-B", str(PROJECT / "src/hello-guix/installer/macos/runtime_check.py"),
                                         str(bundle)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("forbidden", result.stderr)
                self.assertFalse(marker.exists())


class LibffiBuildTests(unittest.TestCase):
    def test_parallelism_is_optional(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "libffi.tar.gz"
            archive_files(archive, {"libffi/configure": b"fixture"})
            runtime = root / "runtime"
            library = runtime / "Frameworks/Python.framework/Versions/3.13/lib/libffi.8.dylib"
            library.parent.mkdir(parents=True)

            def run(command, **options):
                if command[0] == "/usr/bin/make":
                    output = options["cwd"] / ".libs/libffi.8.dylib"
                    output.parent.mkdir()
                    output.write_bytes(b"built library")

            for cores, expected in ((None, ["/usr/bin/make"]),
                                    (3, ["/usr/bin/make", "-j3"])):
                with self.subTest(cores=cores), patch("macos_bundle.sys.platform", "darwin"), \
                        patch("macos_bundle.platform.machine", return_value="arm64"), \
                        patch("macos_bundle.subprocess.run", side_effect=run) as command:
                    build_libffi(archive, runtime, 26, cores=cores)
                    self.assertEqual(command.call_args_list[1].args[0], expected)
                    self.assertEqual(library.read_bytes(), b"built library")

    def test_invalid_core_counts_stop_before_assembly(self):
        for cores in ("0", "-1", "two"):
            arguments = ["macos_bundle.py", "build", "--catalogue", "unused",
                         "--output", "unused", "--cores", cores]
            with self.subTest(cores=cores), patch("sys.argv", arguments), \
                    patch("macos_bundle.assemble") as build, \
                    contextlib.redirect_stderr(io.StringIO()) as errors, \
                    self.assertRaises(SystemExit) as stopped:
                main()
            self.assertEqual(stopped.exception.code, 2)
            self.assertIn("use a positive integer", errors.getvalue())
            build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
