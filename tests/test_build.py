# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check source records and build results with temporary files."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from build_inputs import PROJECT, record_snapshot, source_files, verify_snapshot
import payload_fixtures as fixtures


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        for name in source_files(PROJECT):
            target = self.project / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, target)
        self.inputs = self.project / "build/source-record"

    def test_record_is_repeatable_and_keeps_exact_sources(self):
        record_snapshot(self.inputs, self.project)
        before = (self.inputs / "SHA256SUMS").stat().st_mtime_ns
        record_snapshot(self.inputs, self.project)
        verify_snapshot(self.inputs, self.project)
        self.assertEqual((self.inputs / "SHA256SUMS").stat().st_mtime_ns, before)
        for name in ("packaging/guix/channels.scm", "COPYING",
                     "LICENSES/GPL-3.0-or-later.txt", "LICENSES/MIT.txt",
                     "packaging/macos/asahi-installer-source.json.license",
                     "packaging/macos/asahi-installer-runtime.json.license",
                     "packaging/macos/notices/sources.json.license",
                     "NOTICE"):
            with self.subTest(name=name):
                self.assertEqual((self.inputs / name).read_bytes(),
                                 (self.project / name).read_bytes())

    def test_edits_require_another_source_record(self):
        record_snapshot(self.inputs, self.project)
        (self.project / "packaging/guix/packages/setup-install.scm").write_text("new recipe")
        with self.assertRaisesRegex(ValueError, "Build inputs changed"):
            record_snapshot(self.inputs, self.project)
        self.assertNotEqual((self.inputs / "packaging/guix/packages/setup-install.scm").read_text(), "new recipe")

    def test_missing_added_and_tampered_inputs_are_detected(self):
        record_snapshot(self.inputs, self.project)
        extra = self.project / "packaging/guix/systems/new-input.json"
        extra.write_text("new input")
        with self.assertRaisesRegex(ValueError, "Build inputs changed"):
            verify_snapshot(self.inputs, self.project)
        extra.unlink()
        (self.inputs / "packaging/guix/channels.scm").unlink()
        with self.assertRaisesRegex(ValueError, "Build inputs changed"):
            verify_snapshot(self.inputs, self.project)

    def test_snapshot_links_are_rejected(self):
        record_snapshot(self.inputs, self.project)
        (self.inputs / "unexpected").symlink_to(self.root)
        with self.assertRaisesRegex(ValueError, "link or special"):
            verify_snapshot(self.inputs, self.project)

    def test_whole_directories_include_new_file_types_and_subdirectories(self):
        names = ("src/hello-guix/data/device.json", "docs/figures/boot.svg",
                 "scripts/helpers/tool", "tests/fixtures/result.txt")
        for name in names:
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(name)
        record_snapshot(self.inputs, self.project)
        for name in names:
            self.assertEqual((self.inputs / name).read_text(), name)
        (self.project / names[0]).write_text("changed data")
        with self.assertRaisesRegex(ValueError, "Build inputs changed"):
            verify_snapshot(self.inputs, self.project)

    def test_unclassified_files_and_empty_directories_are_reported(self):
        for name, directory in (("new-settings.json", False), ("new-tools", True)):
            with self.subTest(name=name):
                path = self.project / name
                path.mkdir() if directory else path.write_text("new source")
                with self.assertRaisesRegex(ValueError, f"Unclassified project path: {name}"):
                    record_snapshot(self.inputs, self.project)
                self.assertFalse(self.inputs.exists())
                path.rmdir() if directory else path.unlink()

    def test_metadata_build_outputs_and_caches_stay_out(self):
        for name in (".git/config", "build/log",
                     ".DS_Store", "src/hello-guix/.DS_Store",
                     "scripts/__pycache__/build_inputs.cpython.pyc"):
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("not source")
        record_snapshot(self.inputs, self.project)
        self.assertEqual({p.name for p in self.inputs.iterdir()}, {
            ".gitignore", "COPYING", "Makefile", "NOTICE", "README.md", "SHA256SUMS",
            "LICENSES", "docs", "packaging", "patches", "scripts", "src", "tests",
        })
        self.assertFalse((self.inputs / "scripts/__pycache__").exists())
        self.assertFalse((self.inputs / "src/hello-guix/.DS_Store").exists())
        copied = self.root / "copied-source"
        self.assertEqual(record_snapshot(copied, self.inputs),
                         verify_snapshot(self.inputs, self.project))

    def test_source_links_and_special_files_are_rejected(self):
        path = self.project / "src/device"
        for kind in ("file link", "directory link", "pipe"):
            with self.subTest(kind=kind):
                if kind == "pipe":
                    os.mkfifo(path)
                else:
                    path.symlink_to(self.project / ("README.md" if kind == "file link" else "docs"))
                with self.assertRaisesRegex(ValueError, "link or special"):
                    record_snapshot(self.inputs, self.project)
                path.unlink()

    def test_custom_build_directory_does_not_hide_its_neighbours_or_source(self):
        output = self.project / "local outputs/candidate"
        output.mkdir(parents=True)
        (output / "log").write_text("not source")
        with patch.dict(os.environ, BUILD_DIR=str(output)):
            record_snapshot(self.inputs, self.project)
            neighbour = output.parent / "settings.json"
            neighbour.write_text("unclassified")
            with self.assertRaisesRegex(ValueError, "Unclassified project path:.*settings.json"):
                verify_snapshot(self.inputs, self.project)
            neighbour.unlink()
        for directory in (".", "src", "src/hello-guix"):
            with self.subTest(directory=directory), patch.dict(os.environ, BUILD_DIR=directory):
                with self.assertRaisesRegex(ValueError, "overlaps project source"):
                    source_files(self.project)

    def test_snapshot_tracks_nested_modules(self):
        name = Path("src/hello-guix/installer/linux/setup.scm")
        record_snapshot(self.inputs, self.project)
        self.assertEqual((self.inputs / name).read_bytes(),
                         (self.project / name).read_bytes())
        (self.project / name).write_text("changed module")
        with self.assertRaisesRegex(ValueError, "Build inputs changed"):
            verify_snapshot(self.inputs, self.project)

    def test_snapshot_tracks_guix_test_runners_and_recipes(self):
        names = (Path("tests/guix/check-vm.sh"), Path("tests/guix/configuration-check.scm"))
        record_snapshot(self.inputs, self.project)
        for name in names:
            self.assertEqual((self.inputs / name).read_bytes(),
                             (self.project / name).read_bytes())
        (self.project / names[1]).write_text("changed test recipe")
        with self.assertRaisesRegex(ValueError, "Build inputs changed"):
            verify_snapshot(self.inputs, self.project)

    def prepare_fake_guix(self):
        package = self.root / "fixture-package"
        directory = package / fixtures.PACKAGE_DIRECTORY
        directory.mkdir(parents=True)
        (directory / "package.json").write_text(json.dumps({"os_list": [fixtures.ENTRY]}))
        with zipfile.ZipFile(directory / "guix-setup.zip", "w") as archive:
            archive.writestr("guix.icns", b"icns")
            archive.writestr("Guix_image.img", fixtures.root_image())
            for path, content in fixtures.ram_files().items():
                archive.writestr(path, content)
            archive.writestr("esp/m1n1/boot.bin", b"fixture")
            archive.writestr("esp/EFI/BOOT/BOOTAA64.EFI", fixtures.efi_image())
        command = self.root / "fake-guix"
        command.write_text("#!" + sys.executable + "\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as stream:
    stream.write(json.dumps({"cwd": os.getcwd(), "args": args}) + "\\n")
if "time-machine" in args:
    print(os.environ["PROFILE"])
    sys.exit(0)
if "repl" in args:
    candidate, result = map(pathlib.Path, args[-2:])
    if result.exists() and not result.is_symlink():
        sys.exit("Result is not a symlink")
    os.replace(candidate, result)
    sys.exit(0)
if "--file=packaging/guix/packages/setup-install.scm" in args:
    if os.environ.get("FAIL_BUILD"):
        sys.exit(23)
    if os.environ.get("EDIT_LIVE_PROJECT"):
        (pathlib.Path(os.environ["EDIT_LIVE_PROJECT"]) / "README.md").write_text("later edit")
for argument in args:
    if argument.startswith("--root="):
        pathlib.Path(argument.split("=", 1)[1]).symlink_to(os.environ["PACKAGE"])
''')
        profile = self.root / "profile"
        (profile / "bin").mkdir(parents=True)
        (profile / "bin/guix").symlink_to(command)
        command.chmod(0o755)
        # Do not inherit the caller's Make settings or build destinations.
        self.environment = {name: os.environ[name]
                            for name in ("PATH", "TMPDIR", "LANG", "LC_ALL")
                            if name in os.environ}
        self.environment.update(GUIX=str(command), PYTHON=sys.executable,
                                PROFILE=str(profile),
                                PACKAGE=str(package), CALLS=str(self.root / "calls"))

    def make(self, *targets):
        return subprocess.run(["make", *targets], cwd=self.project, env=self.environment,
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def calls(self):
        return [json.loads(line) for line in (self.root / "calls").read_text().splitlines()]

    def test_image_builds_keep_old_sources_when_development_continues(self):
        self.prepare_fake_guix()
        recipe = "packaging/guix/packages/setup-install.scm"
        (self.project / recipe).write_text("first edit")
        result = self.make("build", "image")
        self.assertEqual(result.returncode, 0, result.stdout)
        (self.project / recipe).write_text("second edit")
        before = self.calls()
        result = self.make("build", "image")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Build inputs changed", result.stdout)
        self.assertEqual(self.calls(), before)
        result = self.make("build", "image", "build_dir=build/image-02")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual((self.inputs / recipe).read_text(), "first edit")
        self.assertEqual((self.project / "build/image-02/source-record" / recipe).read_text(),
                         "second edit")
        builds = [c for c in self.calls()
                  if "--file=packaging/guix/packages/setup-install.scm" in c["args"]]
        self.assertEqual(len(builds), 2)  # Each invocation reaches Guix's cache.
        self.assertTrue((self.project / "build/payload").is_dir())
        self.assertEqual(list((self.project / "build").glob(".build-*")), [])

    def test_failed_build_or_validation_keeps_the_previous_result(self):
        self.prepare_fake_guix()
        result = self.make("build", "image")
        self.assertEqual(result.returncode, 0, result.stdout)
        previous = (self.project / "build/payload").readlink()
        self.environment["FAIL_BUILD"] = "yes"
        result = self.make("build", "image")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.project / "build/payload").readlink(), previous)
        self.environment.pop("FAIL_BUILD")
        invalid = self.root / "invalid-package"
        shutil.copytree(previous, invalid)
        (invalid / fixtures.PACKAGE_DIRECTORY / "guix-setup.zip").unlink()
        self.environment["PACKAGE"] = str(invalid)
        result = self.make("build", "image")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing archive", result.stdout)
        self.assertEqual((self.project / "build/payload").readlink(), previous)
        self.assertEqual(list((self.project / "build").glob(".build-*")), [])

    def test_catalogue_builds_from_saved_source_even_during_live_edits(self):
        self.prepare_fake_guix()
        original = (self.project / "README.md").read_bytes()
        self.environment["EDIT_LIVE_PROJECT"] = str(self.project)
        result = self.make("build", "image")
        self.assertEqual(result.returncode, 0, result.stdout)
        for call in self.calls():
            self.assertEqual(Path(call["cwd"]).resolve(), self.inputs.resolve())
        catalogue = self.project / "build/catalogue"
        self.assertEqual((catalogue / "source-record/README.md").read_bytes(), original)
        self.assertEqual((self.project / "README.md").read_text(), "later edit")
        before = (catalogue / "SHA256SUMS").read_bytes()
        result = self.make("build", "image")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Build inputs changed", result.stdout)
        self.assertEqual((catalogue / "SHA256SUMS").read_bytes(), before)

    def test_failed_image_build_can_be_retried(self):
        self.prepare_fake_guix()
        self.environment["FAIL_BUILD"] = "yes"
        failed = self.make("build", "image")
        self.assertNotEqual(failed.returncode, 0)
        self.assertFalse((self.project / "build/catalogue").exists())
        self.environment.pop("FAIL_BUILD")
        for _ in range(2):
            retried = self.make("build", "image")
            self.assertEqual(retried.returncode, 0, retried.stdout)

    def test_payload_commands_scan_only_named_modules(self):
        self.prepare_fake_guix()
        for verb in ("plan", "build"):
            result = self.make(verb, "image")
            self.assertEqual(result.returncode, 0, result.stdout)
        builds = [c["args"] for c in self.calls()
                  if "--file=packaging/guix/packages/setup-install.scm" in c["args"]]
        for arguments in builds:
            paths = [arguments[i + 1] for i, arg in enumerate(arguments) if arg == "-L"]
            self.assertEqual(len(paths), 2)
            self.assertEqual(paths[1], "src")
            self.assertTrue(Path(paths[0]).is_absolute())
            self.assertIn(Path(paths[0]).name, ("source", "installer-source"))
        for path in (self.project / "src").rglob("*.scm"):
            source = "\n".join(line for line in path.read_text().splitlines()
                               if not line.lstrip().startswith(";"))
            declaration = re.match(r"\s*\(define-module\s+\(([^()]*)\)", source)
            self.assertIsNotNone(declaration, f"Standalone file on module path: {path}")
            self.assertEqual(tuple(declaration.group(1).split()),
                             path.relative_to(self.project / "src").with_suffix("").parts)

    def test_grammar_rejects_incomplete_or_ambiguous_commands_before_work(self):
        self.prepare_fake_guix()
        for goals in (("build",), ("image", "build"), ("build", "code"),
                      ("build", "candidate"), ("build", "release"),
                      ("check", "release"), ("package", "installer"),
                      ("build", "installer", "candidate=old-catalogue"),
                      ("build", "package", "release_dir=old-output"),
                      ("build", "image", "check", "image"),
                      ("build", "image", "only=hardware"),
                      ("check", "code", "only=unknown")):
            with self.subTest(goals=goals):
                result = self.make(*goals)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "calls").exists())

    def test_resource_limits_are_optional_and_paths_may_contain_spaces(self):
        self.prepare_fake_guix()
        result = self.make("build", "image", "build_dir=build with spaces")
        self.assertEqual(result.returncode, 0, result.stdout)
        for call in self.calls():
            self.assertFalse(any(arg.startswith(("--max-jobs", "--cores"))
                                 for arg in call["args"]))
        self.assertTrue((self.project / "build with spaces/catalogue").is_dir())
        result = self.make("build", "image", "build_dir=build with spaces", "jobs=3", "cores=4")
        self.assertEqual(result.returncode, 0, result.stdout)
        for call in self.calls()[-5:]:
            if "repl" not in call["args"]:
                self.assertIn("--max-jobs=3", call["args"])
                self.assertIn("--cores=4", call["args"])
        profile_calls = [c for c in self.calls() if "time-machine" in c["args"]]
        self.assertEqual(len(profile_calls), 2)

    def test_plan_needs_no_guix_and_creates_no_build_directory(self):
        self.prepare_fake_guix()
        self.environment["GUIX"] = str(self.root / "guix-not-installed")
        before = sorted(self.project.rglob("*"))
        result = self.make("plan", "image", "build_dir=build/fresh image",
                           "catalogue=build/chosen catalogue", "jobs=3", "cores=4")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("build/fresh image/source-record", result.stdout)
        self.assertIn("build/chosen catalogue", result.stdout)
        self.assertIn("Jobs: 3\nCores: 4", result.stdout)
        self.assertIn("Exact dependencies and downloads are determined during the build", result.stdout)
        self.assertFalse((self.root / "calls").exists())
        self.assertFalse((self.project / "build").exists())
        self.assertEqual(sorted(self.project.rglob("*")), before)

    def test_plan_preserves_existing_outputs_and_reports_changed_source(self):
        self.prepare_fake_guix()
        result = self.make("build", "image")
        self.assertEqual(result.returncode, 0, result.stdout)
        previous = (self.project / "build/payload").lstat().st_mtime_ns
        source_root = (self.project / "build/installer-source").lstat().st_mtime_ns
        catalogue = (self.project / "build/catalogue/SHA256SUMS").read_bytes()
        before = self.calls()
        result = self.make("plan", "image")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Build inputs verified", result.stdout)
        self.assertEqual(self.calls(), before)
        (self.project / "README.md").write_text("a change to plan")
        result = self.make("plan", "image")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Build inputs changed", result.stdout)
        self.assertEqual(self.calls(), before)
        self.assertEqual((self.project / "build/payload").lstat().st_mtime_ns, previous)
        self.assertEqual((self.project / "build/installer-source").lstat().st_mtime_ns, source_root)
        self.assertEqual((self.project / "build/catalogue/SHA256SUMS").read_bytes(), catalogue)
        self.assertEqual(list((self.project / "build").glob(".build-*")), [])

    def test_image_operation_can_run_without_make(self):
        self.prepare_fake_guix()
        (self.root / "python").symlink_to(sys.executable)
        self.environment["PYTHON"] = "./python"
        shells = ["bash"]
        if Path("/bin/bash").is_file():
            shells.append("/bin/bash")
        for shell in shells:
            with self.subTest(shell=shell):
                result = subprocess.run([shell, str(self.project / "scripts/build_image.sh")],
                                        cwd=self.root, env=self.environment, text=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 0, result.stdout)
        self.environment["PYTHON"] = sys.executable
        result = self.make("check", "image")
        self.assertEqual(result.returncode, 0, result.stdout)
        (self.project / "build/catalogue/os/guix-setup.zip").unlink()
        result = self.make("check", "image")
        self.assertNotEqual(result.returncode, 0)

    def test_python_checks_manage_temporary_source_and_accept_an_archive(self):
        python = self.root / "python"
        python.write_text("#!" + sys.executable + "\n" + '''import json, os, pathlib, sys
args = sys.argv[1:]
source = os.environ.get("ASAHI_SOURCE")
with pathlib.Path(__file__).with_suffix(".log").open("a") as stream:
    stream.write(json.dumps({"args": args, "source": source}) + "\\n")
if args[0] == "scripts/prepare_asahi.py":
    pathlib.Path(args[args.index("--directory") + 1]).mkdir(parents=True, exist_ok=True)
    stage = "prepare"
else:
    assert pathlib.Path(source).is_absolute() and pathlib.Path(source).is_dir()
    stage = "test"
if os.environ.get("HELLO_GUIX_TEST_FAILURE") == stage:
    sys.exit(23)
''')
        python.chmod(0o755)
        environment = {"PATH": os.environ["PATH"], "PYTHON": str(python),
                       "BUILD_DIR": "build with spaces"}
        shell = "/bin/bash" if Path("/bin/bash").is_file() else "bash"
        archive = str(self.root / "source archive.tar.gz")
        log = python.with_suffix(".log")
        old_source = self.project / "build with spaces/asahi-installer/local-edit"
        old_source.parent.mkdir(parents=True)
        old_source.write_text("keep this edit")
        cases = (((), ""), (("python", ""), ""), (("python", archive), ""),
                 ((), "prepare"), ((), "test"))
        for arguments, failure in cases:
            with self.subTest(arguments=arguments, failure=failure):
                log.unlink(missing_ok=True)
                environment["HELLO_GUIX_TEST_FAILURE"] = failure
                result = subprocess.run([shell, str(self.project / "scripts/check_code.sh"),
                                         *arguments], cwd=self.root, env=environment,
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 23 if failure else 0, result.stdout)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                source = Path(calls[0]["args"][2])
                self.assertEqual(source.name, "asahi-installer")
                self.assertEqual(source.parent.parent, Path("build with spaces"))
                self.assertNotEqual(source, Path("build with spaces/asahi-installer"))
                expected = ["scripts/prepare_asahi.py", "--directory",
                            str(source), "--cache-directory", "build with spaces/cache"]
                if arguments and arguments[-1]:
                    expected += ["--archive", archive]
                expected_calls = [{"args": expected, "source": None}]
                if failure != "prepare":
                    expected_calls.append({
                        "args": ["-m", "unittest", "discover", "-s", "tests", "-v"],
                        "source": str((self.project / source).resolve()),
                    })
                self.assertEqual(calls, expected_calls)
                self.assertFalse((self.project / source.parent).exists())
                self.assertEqual(old_source.read_text(), "keep this edit")


if __name__ == "__main__":
    unittest.main()
