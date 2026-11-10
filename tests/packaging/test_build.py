# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check source records and build results with temporary files."""

import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/packaging"))
from source_record import PROJECT, record_snapshot, source_files, verify_snapshot
from . import payload_fixtures as fixtures


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.project = self.root / "project"
        for name in source_files(PROJECT):
            target = self.project / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, target, follow_symlinks=False)
        self.inputs = self.project / "build/source-record"

    def test_record_is_repeatable_and_keeps_exact_sources(self):
        record_snapshot(self.inputs, self.project)
        before = (self.inputs / "SHA256SUMS").stat().st_mtime_ns
        record_snapshot(self.inputs, self.project)
        verify_snapshot(self.inputs, self.project)
        self.assertEqual((self.inputs / "SHA256SUMS").stat().st_mtime_ns, before)
        for name in (".guix-channel", "packaging/guix/channels.scm", "COPYING",
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
        (self.project / "packaging/guix/recipes/setup-install.scm").write_text("new recipe")
        with self.assertRaisesRegex(ValueError, "Build inputs changed"):
            record_snapshot(self.inputs, self.project)
        self.assertNotEqual((self.inputs / "packaging/guix/recipes/setup-install.scm").read_text(), "new recipe")

    def test_missing_added_and_tampered_inputs_are_detected(self):
        record_snapshot(self.inputs, self.project)
        extra = self.project / "packaging/guix/recipes/new-input.json"
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
        names = ("hello-guix/data/device.json", "docs/figures/boot.svg",
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
                     ".DS_Store", "hello-guix/.DS_Store",
                     "scripts/__pycache__/source_record.cpython.pyc"):
            path = self.project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("not source")
        record_snapshot(self.inputs, self.project)
        self.assertEqual({p.name for p in self.inputs.iterdir()}, {
            ".gitignore", ".guix-channel", "COPYING", "Makefile", "NOTICE", "README.md", "SHA256SUMS",
            "LICENSES", "docs", "hello-guix", "packaging", "patches", "scripts", "tests",
        })
        self.assertFalse((self.inputs / "scripts/__pycache__").exists())
        self.assertFalse((self.inputs / "hello-guix/.DS_Store").exists())
        copied = self.root / "copied-source"
        self.assertEqual(record_snapshot(copied, self.inputs),
                         verify_snapshot(self.inputs, self.project))

    def test_source_links_and_special_files_are_rejected(self):
        path = self.project / "hello-guix/device"
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
        for directory in (".", "hello-guix", "hello-guix/installer", "hello-guix/system"):
            with self.subTest(directory=directory), patch.dict(os.environ, BUILD_DIR=directory):
                with self.assertRaisesRegex(ValueError, "overlaps project source"):
                    source_files(self.project)

    def test_snapshot_tracks_nested_modules(self):
        names = (Path("hello-guix/installer/linux/setup.scm"),
                 Path("hello-guix/system/hardware.scm"))
        record_snapshot(self.inputs, self.project)
        for name in names:
            with self.subTest(name=name):
                original = (self.project / name).read_bytes()
                self.assertEqual((self.inputs / name).read_bytes(), original)
                (self.project / name).write_text("changed module")
                with self.assertRaisesRegex(ValueError, "Build inputs changed"):
                    verify_snapshot(self.inputs, self.project)
                (self.project / name).write_bytes(original)

    def test_snapshot_tracks_guix_test_runners_and_recipes(self):
        names = (Path("tests/installer/linux/check-vm.sh"), Path("tests/installer/linux/configuration-check.scm"))
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
if "--file=packaging/guix/recipes/setup-install.scm" in args:
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

    def prepare_runtime_profiles(self):
        """Exercise shell routing locally; these executables do not emulate Guix."""
        commands = self.root / "commands"
        commands.mkdir()
        for name, answer in (("uname", "Linux"), ("id", "1000")):
            command = commands / name
            command.write_text("#!/bin/sh\nprintf '%s\\n' " + answer + "\n")
            command.chmod(0o755)
        self.runtime_state = self.root / "runtime-state.json"
        self.runtime_state.write_text("{}")
        self.profiles = [(self.root / name).resolve()
                         for name in ("profile one", "profile two")]
        self.channel_profiles = [(self.root / name).resolve()
                                 for name in ("compiled one", "compiled two")]
        compiled = dict(zip(map(str, self.profiles), map(str, self.channel_profiles)))
        self.current = self.root / "current"
        self.runtime_fixture = self.root / "runtime fixture"
        self.runtime_fixture.mkdir()
        runner = self.runtime_fixture / "run"
        runner.write_text("#!" + sys.executable + "\n" + f'''
import json, os, pathlib, sys
with pathlib.Path({str(self.root / 'calls')!r}).open("a") as stream:
    stream.write(json.dumps({{"args": sys.argv[1:], "stage": "boot-cli-run",
                             "environment": dict(os.environ)}}) + "\\n")
state = json.loads(pathlib.Path({str(self.runtime_state)!r}).read_text())
if state.get("fail") == "boot-cli-run":
    print("fixture failure: boot-cli-run", file=sys.stderr)
    sys.exit(23)
print("fixture passed: boot-cli-run")
''')
        runner.chmod(0o755)
        self.channel_tools = self.root / "channel tools"
        self.channel_tools.mkdir()
        authentication = self.channel_tools / "bash"
        authentication.write_text("#!" + sys.executable + "\n" + f'''
import json, os, pathlib, sys
with pathlib.Path({str(self.root / 'calls')!r}).open("a") as stream:
    stream.write(json.dumps({{"args": sys.argv[1:], "stage": "channel-authentication",
                             "environment": dict(os.environ)}}) + "\\n")
state = json.loads(pathlib.Path({str(self.runtime_state)!r}).read_text())
if state.get("fail") == "channel-authentication":
    print("fixture failure: channel-authentication", file=sys.stderr)
    sys.exit(23)
if state.get("change_source"):
    (pathlib.Path(sys.argv[2]) / "README.md").write_text("changed saved source")
print("fixture passed: channel-authentication")
''')
        authentication.chmod(0o755)
        for directory, stage, seconds in (
                (self.runtime_fixture, "boot-cli-timeout", "1200"),
                (self.channel_tools, "channel-timeout", "600")):
            timeout = directory / "timeout"
            timeout.write_text("#!" + sys.executable + "\n" + f'''
import json, os, pathlib, sys
with pathlib.Path({str(self.root / 'calls')!r}).open("a") as stream:
    stream.write(json.dumps({{"args": sys.argv[1:], "stage": {stage!r},
                             "environment": dict(os.environ)}}) + "\\n")
state = json.loads(pathlib.Path({str(self.runtime_state)!r}).read_text())
if state.get("fail") == {stage!r}:
    print("fixture failure: " + {stage!r}, file=sys.stderr)
    sys.exit(124)
if sys.argv[1:4] != ["--signal=TERM", "--kill-after=20", {seconds!r}]:
    sys.exit("Unexpected timeout arguments")
os.execv(sys.argv[4], sys.argv[4:])
''')
            timeout.chmod(0o755)
        program = "#!" + sys.executable + "\n" + f'''
import json, os, pathlib, sys
state = json.loads(pathlib.Path({str(self.runtime_state)!r}).read_text())
# Like Guix's current-profile, retain the profile enclosing the command.
profile = pathlib.Path(sys.argv[0]).parent.parent.resolve()
args = sys.argv[1:]
script = next((pathlib.Path(arg.removeprefix("--file=")).name
               for arg in args[1:] if arg.endswith(".scm")), args[0])
compiled = {compiled!r}
stage = ("channel-profile" if script == "runtime-profile.scm"
         and str(profile) in compiled.values() else script)
if args[0] == "system":
    directory = pathlib.Path(args[-1]).parent
    if directory.name == "configuration-source":
        directory = directory.parent
    variant = (directory.parent.name if directory.name == "recovery"
               else directory.name.removesuffix("-provenance"))
    stage = variant + "-replay"
with pathlib.Path({str(self.root / 'calls')!r}).open("a") as stream:
    stream.write(json.dumps({{"args": args, "profile": str(profile), "stage": stage,
                             "environment": dict(os.environ)}}) + "\\n")
if state.get("fail") == stage:
    print("fixture failure: " + stage, file=sys.stderr)
    sys.exit(23)
if args[0] == "time-machine":
    print({str(self.profiles[1])!r})
elif script == "runtime-profile.scm":
    if state.get("move_current") and stage == "runtime-profile.scm":
        current = pathlib.Path({str(self.current)!r})
        current.unlink()
        current.symlink_to({str(self.profiles[1])!r})
    invalid = state.get("invalid_profile") == stage
    print(profile / "missing" if invalid else profile)
elif args[0] == "describe":
    print("fixture channels for " + profile.name)
elif args[0] == "build" and any(a.endswith("/tests/system/runtime-channel.scm") for a in args):
    root = next(arg.removeprefix("--root=") for arg in args if arg.startswith("--root="))
    pathlib.Path(root).symlink_to(compiled[str(profile)])
    print("fixture passed: runtime channel compilation")
elif args[0] == "build" and script == "channel-tools.scm":
    root = next(arg.removeprefix("--root=") for arg in args if arg.startswith("--root="))
    pathlib.Path(root).symlink_to({str(self.channel_tools)!r})
    print("fixture passed: channel-tools.scm")
elif args[0] == "build" and script == "boot-cli.scm":
    root = next(arg.removeprefix("--root=") for arg in args if arg.startswith("--root="))
    pathlib.Path(root).symlink_to({str(self.runtime_fixture)!r})
    print("fixture passed: boot-cli.scm")
elif args[0] == "repl" and script == "configuration.scm":
    directory = pathlib.Path(args[-3])
    directory.mkdir()
    (directory / "system.drv").write_text("/fixture/configuration.drv\\n")
    (directory / "recovery").mkdir()
    (directory / "recovery/config.scm").write_text(";; Configuration routing fixture.\\n")
    if state.get("change_source"):
        (pathlib.Path(args[1]).parents[2] / "README.md").write_text("changed saved source")
    print("fixture passed: " + stage)
elif script == "firmware.scm":
    directory = pathlib.Path(args[-3])
    directory.mkdir()
    (directory / "expected.drv").write_text("/fixture/firmware.drv\\n")
    (directory / "recovery").mkdir()
    (directory / "recovery/config.scm").write_text(";; Firmware routing fixture.\\n")
    print("fixture passed: " + stage)
elif script == "channel-migration.scm":
    directory = pathlib.Path(args[-1])
    directory.mkdir()
    for variant in ("original", "added-package", "local-helpers"):
        (directory / (variant + ".drv")).write_text("/fixture/" + variant + ".drv\\n")
        saved = directory / (variant + "-provenance")
        saved.mkdir()
        (saved / "configuration.scm").write_text(";; Routing fixture, not a Guix system.\\n")
        if variant == "local-helpers":
            (saved / "configuration-source").mkdir()
            (saved / "configuration-source/config.scm").write_text(";; Local helper fixture.\\n")
    print("fixture passed: " + stage)
elif args[:2] == ["system", "build"]:
    result = "different" if state.get("mismatch") == variant else variant
    print("/fixture/" + result + ".drv")
elif script in ("hardware.scm", "boot.scm", "boot-deployment.scm", "boot-build.scm", "runtime.scm"):
    print("fixture passed: " + stage)
else:
    sys.exit("Unexpected Guix operation: " + repr(args))
'''
        for profile in self.profiles + self.channel_profiles:
            (profile / "bin").mkdir(parents=True)
            command = self.root / "packages" / profile.name / "bin/guix"
            command.parent.mkdir(parents=True)
            command.write_text(program)
            command.chmod(0o755)
            (profile / "bin/guix").symlink_to(command)
        self.current.symlink_to(self.profiles[0])
        self.environment = {
            "PATH": str(commands) + os.pathsep + os.environ["PATH"],
            "GUIX": str(self.current / "bin/guix"), "PYTHON": sys.executable,
        }

    def test_runtime_checks_use_and_record_the_selected_profile(self):
        self.prepare_runtime_profiles()
        for index, profile in enumerate(self.profiles):
            with self.subTest(profile=profile.name):
                before = len(self.calls()) if (self.root / "calls").exists() else 0
                self.environment["GUIX"] = str(profile / "bin/guix")
                result = self.make("check", "code", "only=runtime",
                                   f"build_dir=build/runtime {index}")
                self.assertEqual(result.returncode, 0, result.stdout)
                records, = (self.project / f"build/runtime {index}").glob("runtime-check-*")
                self.assertEqual((records / "profile").read_text().strip(), str(profile))
                self.assertEqual((records / "channels.scm").read_text().strip(),
                                 "fixture channels for " + profile.name)
                channel_profile = self.channel_profiles[index]
                self.assertEqual((records / "channel").resolve(), channel_profile)
                self.assertEqual((records / "channel-profile").read_text().strip(),
                                 str(channel_profile))
                self.assertEqual((records / "channel-channels.scm").read_text().strip(),
                                 "fixture channels for " + channel_profile.name)
                self.assertTrue((records / "source/SHA256SUMS").is_file())
                calls = self.calls()[before:]
                build = next(i for i, call in enumerate(calls) if call["args"][0] == "build")
                self.assertTrue(all(call["profile"] == str(profile) for call in calls[:build + 1]))
                self.assertTrue(all(call["profile"] == str(channel_profile) for call in calls[build + 1:]))
                self.assertFalse(any("-L" in call["args"] for call in calls[build + 1:]))
                migration, = [call for call in calls if call["stage"] == "channel-migration.scm"]
                self.assertEqual(migration["args"][-2:],
                                 [str((records / "source/tests/system/channel-system.scm").resolve()),
                                  str((records / "migration").resolve())])
                replay = [call for call in calls if call["args"][0] == "system"]
                self.assertEqual([call["stage"] for call in replay],
                                 ["firmware-replay", "original-replay", "added-package-replay",
                                  "local-helpers-replay"])
                firmware_replay = replay.pop(0)
                self.assertTrue({"--no-grafts", "--save-provenance", "--derivation"}
                                .issubset(firmware_replay["args"]))
                self.assertEqual(firmware_replay["args"][-1],
                                 str((records / "firmware/recovery/config.scm").resolve()))
                self.assertEqual((records / "firmware/expected.drv").read_bytes(),
                                 (records / "firmware/recovered.drv").read_bytes())
                for call, variant in zip(replay, ("original", "added-package", "local-helpers")):
                    self.assertEqual(call["args"][:2], ["system", "build"])
                    self.assertTrue({"--no-grafts", "--save-provenance", "--derivation"}
                                    .issubset(call["args"]))
                    declaration = ("configuration-source/config.scm" if variant == "local-helpers"
                                   else "configuration.scm")
                    self.assertEqual(Path(call["args"][-1]),
                                     (records / "migration" / (variant + "-provenance")
                                      / declaration).resolve())
                    self.assertEqual((records / "migration" / (variant + ".drv")).read_bytes(),
                                     (records / "migration" / (variant + "-recovered.drv")).read_bytes())
        calls = self.calls()
        self.assertEqual({call["profile"] for call in calls},
                         set(map(str, self.profiles + self.channel_profiles)))
        self.assertTrue(all(call["args"][0] in ("repl", "describe", "build", "system") for call in calls))
        self.assertFalse(any("installer" in argument or "setup-tools" in argument
                             for call in calls for argument in call["args"]))

    def prepare_runtime_configuration(self):
        self.prepare_runtime_profiles()
        configuration = self.root / "reviewed configuration/config.scm"
        configuration.parent.mkdir()
        configuration.write_text(";; Reviewed declaration routing fixture.\n")
        return configuration.resolve()

    def test_runtime_configuration_keeps_the_selected_profile_and_replays(self):
        configuration = self.prepare_runtime_configuration()
        before = configuration.read_bytes()
        self.runtime_state.write_text(json.dumps({"move_current": True}))
        self.environment.update(GUILE_LOAD_PATH="/personal/override",
                                GUILE_LOAD_COMPILED_PATH="/personal/override",
                                GUIX_DAEMON_SOCKET="/chosen/daemon/socket")
        result = self.make("check", "code", "only=runtime",
                           f"configuration={configuration}", "jobs=1", "cores=2")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(configuration.read_bytes(), before)
        records, = (self.project / "build").glob("runtime-check-*")
        records = records.resolve()
        self.assertEqual(self.current.resolve(), self.profiles[1])
        self.assertEqual((records / "profile").read_text().strip(), str(self.profiles[0]))
        self.assertEqual((records / "channels.scm").read_text().strip(),
                         "fixture channels for " + self.profiles[0].name)
        self.assertTrue((records / "source/SHA256SUMS").is_file())
        self.assertFalse((records / "channel").exists())
        self.assertEqual((records / "configuration/system.drv").read_bytes(),
                         (records / "configuration/recovered.drv").read_bytes())
        calls = self.calls()
        self.assertEqual([call["stage"] for call in calls],
                         ["runtime-profile.scm", "describe", "configuration.scm",
                          "configuration-replay"])
        self.assertTrue(all(call["profile"] == str(self.profiles[0]) for call in calls))
        self.assertEqual(calls[2]["args"],
                         ["repl", str(records / "source/tests/system/configuration.scm"),
                          str(configuration), str(records / "configuration"), "1", "2"])
        self.assertEqual(calls[-1]["args"],
                         ["system", "build", "--no-grafts", "--save-provenance",
                          "--derivation", str(records / "configuration/recovery/config.scm")])
        for call in calls:
            self.assertEqual(call["environment"]["HOME"], str(records / "home"))
            self.assertEqual(call["environment"]["GUIX_DAEMON_SOCKET"], "/chosen/daemon/socket")
            self.assertNotIn("GUILE_LOAD_PATH", call["environment"])
            self.assertNotIn("GUILE_LOAD_COMPILED_PATH", call["environment"])
        self.assertIn("Reviewed configuration replayed", result.stdout)

    def test_runtime_configuration_failure_and_replay_mismatch_propagate(self):
        configuration = self.prepare_runtime_configuration()
        cases = ({"fail": "configuration.scm"}, {"fail": "configuration-replay"},
                 {"mismatch": "configuration"}, {"change_source": True})
        for index, state in enumerate(cases):
            with self.subTest(state=state):
                self.runtime_state.write_text(json.dumps(state))
                (self.root / "calls").unlink(missing_ok=True)
                result = self.make("check", "code", "only=runtime",
                                   f"configuration={configuration}",
                                   f"build_dir=build/configuration-failure-{index}")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                records, = (self.project / f"build/configuration-failure-{index}").glob("runtime-check-*")
                self.assertTrue((records / "source/SHA256SUMS").is_file())
                if "fail" in state:
                    self.assertIn("Error 23", result.stdout)
                    self.assertIn("fixture failure: " + state["fail"],
                                  (records / "check.log").read_text())
                    self.assertEqual(self.calls()[-1]["stage"], state["fail"])
                elif "mismatch" in state:
                    self.assertNotIn("Reviewed configuration replayed", result.stdout)
                else:
                    self.assertIn("Build inputs changed", result.stdout)

    def test_runtime_configuration_rejects_wrong_routes_and_inputs_before_guix(self):
        configuration = self.prepare_runtime_configuration()
        cases = (("only=hardware", f"configuration={configuration}"),
                 ("only=runtime-channel", f"configuration={configuration}"),
                 ("only=runtime", "configuration=relative/config.scm"),
                 ("only=runtime", f"configuration={configuration.parent / 'missing.scm'}"),
                 ("only=runtime", f"configuration={configuration.parent}"),
                 ("only=runtime", f"configuration={configuration}", "boot_reference=/gnu/store/example"))
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = self.make("check", "code", *arguments)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "calls").exists())
        result = self.make("build", "image", f"configuration={configuration}")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse((self.root / "calls").exists())

    def test_runtime_channel_route_authenticates_without_precompiling_hello(self):
        self.prepare_runtime_profiles()
        self.runtime_state.write_text(json.dumps({"move_current": True}))
        self.environment.update(GUILE_LOAD_PATH="/personal/override",
                                GUIX_DAEMON_SOCKET="/chosen/daemon/socket")
        result = self.make("check", "code", "only=runtime-channel", "jobs=1", "cores=2")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.current.resolve(), self.profiles[1])
        records, = (self.project / "build").glob("runtime-channel-*")
        records = records.resolve()
        self.assertEqual((records / "profile").read_text().strip(), str(self.profiles[0]))
        self.assertEqual((records / "channels.scm").read_text().strip(),
                         "fixture channels for " + self.profiles[0].name)
        self.assertTrue((records / "source/SHA256SUMS").is_file())
        self.assertFalse((records / "channel").exists())
        calls = self.calls()
        self.assertEqual([call["stage"] for call in calls],
                         ["runtime-profile.scm", "describe", "channel-tools.scm",
                          "channel-timeout", "channel-authentication"])
        self.assertTrue(all(call["profile"] == str(self.profiles[0]) for call in calls[:3]))
        self.assertIn("--max-jobs=1", calls[2]["args"])
        self.assertIn("--cores=2", calls[2]["args"])
        arguments = [str(records / "source/tests/system/check-channel-authentication.sh"),
                     str(records / "source"), str(records / "authentication"),
                     str(records / "tools"), str(self.profiles[0] / "bin/guix"), "1", "2"]
        self.assertEqual(calls[-1]["args"], arguments)
        self.assertEqual(calls[-2]["args"],
                         ["--signal=TERM", "--kill-after=20", "600",
                          str(records / "tools/bash"), *arguments])
        for call in calls:
            self.assertEqual(call["environment"]["HOME"], str(records / "home"))
            self.assertEqual(call["environment"]["GUIX_DAEMON_SOCKET"], "/chosen/daemon/socket")
            self.assertNotIn("GUILE_LOAD_PATH", call["environment"])
        self.assertEqual(calls[-1]["environment"]["PATH"], str(self.profiles[0] / "bin"))

    def test_runtime_channel_route_retains_failures_and_timeout_status(self):
        self.prepare_runtime_profiles()
        for index, (stage, status) in enumerate((("channel-tools.scm", 23),
                                                 ("channel-timeout", 124),
                                                 ("channel-authentication", 23))):
            with self.subTest(stage=stage):
                self.runtime_state.write_text(json.dumps({"fail": stage}))
                (self.root / "calls").unlink(missing_ok=True)
                result = self.make("check", "code", "only=runtime-channel",
                                   f"build_dir=build/authentication-failure-{index}")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(f"Error {status}", result.stdout)
                records, = (self.project / f"build/authentication-failure-{index}").glob("runtime-channel-*")
                self.assertTrue((records / "source/SHA256SUMS").is_file())
                self.assertIn("fixture failure: " + stage, (records / "check.log").read_text())
                self.assertEqual(self.calls()[-1]["stage"], stage)

    def test_runtime_channel_route_verifies_saved_source_on_exit(self):
        self.prepare_runtime_profiles()
        self.runtime_state.write_text(json.dumps({"change_source": True}))
        result = self.make("check", "code", "only=runtime-channel")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Build inputs changed", result.stdout)
        self.assertEqual(self.calls()[-1]["stage"], "channel-authentication")

    def local_runtime_socket(self):
        daemon = socket.socket(socket.AF_UNIX)
        self.addCleanup(daemon.close)
        path = self.root / "daemon.sock"
        daemon.bind(str(path))
        return path

    def test_runtime_system_route_uses_frozen_channel_and_clears_environment(self):
        self.prepare_runtime_profiles()
        daemon = self.local_runtime_socket()
        self.environment.update(GUIX_DAEMON_SOCKET="unix://" + str(daemon),
                                GUILE_LOAD_PATH="/personal/override")
        result = self.make("check", "code", "only=runtime-system", "jobs=1", "cores=2")
        self.assertEqual(result.returncode, 0, result.stdout)
        records, = (self.project / "build").glob("runtime-system-*")
        self.assertEqual((records / "channel-profile").read_text().strip(),
                         str(self.channel_profiles[0]))
        self.assertEqual((records / "fixture").resolve(), self.runtime_fixture.resolve())
        self.assertTrue((records / "source/SHA256SUMS").is_file())
        calls = self.calls()
        self.assertEqual([call["stage"] for call in calls],
                         ["runtime-profile.scm", "describe", "runtime-channel.scm",
                          "channel-profile", "describe", "boot-cli.scm",
                          "boot-cli-timeout", "boot-cli-run"])
        build = calls[-3]
        self.assertEqual(build["profile"], str(self.channel_profiles[0]))
        self.assertIn("--max-jobs=1", build["args"])
        self.assertIn("--cores=2", build["args"])
        self.assertIn("--no-grafts", build["args"])
        timeout = calls[-2]
        self.assertEqual(timeout["args"],
                         ["--signal=TERM", "--kill-after=20", "1200",
                          str(records.resolve() / "fixture/run"), str(records.resolve())])
        runner = calls[-1]
        self.assertEqual(runner["args"], [str(records.resolve())])
        self.assertEqual(runner["environment"]["GUIX_DAEMON_SOCKET"], str(daemon))
        self.assertEqual(runner["environment"]["HOME"], str(records.resolve() / "home"))
        self.assertNotIn("GUILE_LOAD_PATH", runner["environment"])
        self.assertFalse(any(call["args"][0] == "time-machine" for call in calls))

    def test_runtime_system_route_retains_build_and_execution_failures(self):
        self.prepare_runtime_profiles()
        self.environment["GUIX_DAEMON_SOCKET"] = str(self.local_runtime_socket())
        for index, (stage, status) in enumerate((("boot-cli.scm", 23),
                                                  ("boot-cli-timeout", 124),
                                                  ("boot-cli-run", 23))):
            with self.subTest(stage=stage):
                self.runtime_state.write_text(json.dumps({"fail": stage}))
                (self.root / "calls").unlink(missing_ok=True)
                result = self.make("check", "code", "only=runtime-system",
                                   f"build_dir=build/system-failure-{index}")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(f"Error {status}", result.stdout)
                records, = (self.project / f"build/system-failure-{index}").glob("runtime-system-*")
                self.assertTrue((records / "source/SHA256SUMS").is_file())
                self.assertIn("fixture failure: " + stage, (records / "check.log").read_text())
                self.assertEqual(self.calls()[-1]["stage"], stage)

    def test_runtime_system_requires_a_local_unix_socket_before_building(self):
        self.prepare_runtime_profiles()
        for index, daemon in enumerate(("ssh://example.test", "/missing/daemon.sock")):
            with self.subTest(daemon=daemon):
                self.environment["GUIX_DAEMON_SOCKET"] = daemon
                result = self.make("check", "code", "only=runtime-system",
                                   f"build_dir=build/socket-{index}")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse((self.root / "calls").exists())
                records, = (self.project / f"build/socket-{index}").glob("runtime-system-*")
                self.assertTrue((records / "source/SHA256SUMS").is_file())
                self.assertIn("local Unix", (records / "check.log").read_text())

    def test_runtime_boot_reference_and_resources_are_explicit_arguments(self):
        self.prepare_runtime_profiles()
        reference = "/gnu/store/fixture-existing-boot-bundle"
        result = self.make("check", "code", "only=runtime",
                           f"boot_reference={reference}", "jobs=1", "cores=2")
        self.assertEqual(result.returncode, 0, result.stdout)
        build, = [call for call in self.calls() if call["stage"] == "boot-build.scm"]
        self.assertEqual(build["args"][-3:], [reference, "1", "2"])
        self.assertNotIn("BOOT_REFERENCE", build["environment"])
        self.assertEqual(build["profile"], str(self.channel_profiles[0]))
        firmware, = [call for call in self.calls() if call["stage"] == "firmware.scm"]
        self.assertEqual(firmware["args"][-2:], ["1", "2"])
        self.assertEqual(firmware["profile"], str(self.channel_profiles[0]))

    def test_runtime_checks_freeze_the_profile_and_clear_personal_settings(self):
        self.prepare_runtime_profiles()
        self.runtime_state.write_text(json.dumps({"move_current": True}))
        pollution = {name: "/personal/override" for name in (
            "GUILE_LOAD_PATH", "GUILE_LOAD_COMPILED_PATH", "GUIX_PACKAGE_PATH",
            "GUIX_EXTENSIONS_PATH", "GUIX_UNINSTALLED", "GUIX_PROFILE",
            "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "BOOT_TEST_DIRECTORY")}
        self.environment.update(pollution, HOME="/personal/home",
                                GUIX_DAEMON_SOCKET="/chosen/daemon/socket")
        result = self.make("check", "code", "only=runtime")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.current.resolve(), self.profiles[1])
        calls = self.calls()
        build = next(i for i, call in enumerate(calls) if call["args"][0] == "build")
        self.assertTrue(all(call["profile"] == str(self.profiles[0]) for call in calls[:build + 1]))
        self.assertTrue(all(call["profile"] == str(self.channel_profiles[0]) for call in calls[build + 1:]))
        records, = (self.project / "build").glob("runtime-check-*")
        for call in calls:
            environment = call["environment"]
            self.assertFalse(set(pollution).intersection(environment))
            self.assertEqual(environment["HOME"], str((records / "home").resolve()))
            self.assertEqual(environment["LC_ALL"], "C")
            self.assertEqual(environment["GUIX_DAEMON_SOCKET"], "/chosen/daemon/socket")
        for call in calls[1:]:
            if call["stage"] != "channel-profile":
                self.assertEqual(call["environment"]["PATH"],
                                 str(Path(call["profile"]) / "bin"))

    def test_runtime_check_failures_keep_the_status_and_records(self):
        self.prepare_runtime_profiles()
        stages = ("runtime-profile.scm", "runtime-channel.scm", "channel-profile",
                  "hardware.scm", "boot.scm", "boot-deployment.scm", "boot-build.scm",
                  "runtime.scm", "firmware.scm", "firmware-replay", "channel-migration.scm",
                  "original-replay", "added-package-replay", "local-helpers-replay")
        for index, stage in enumerate(stages):
            with self.subTest(stage=stage):
                self.runtime_state.write_text(json.dumps({"fail": stage}))
                (self.root / "calls").unlink(missing_ok=True)
                result = self.make("check", "code", "only=runtime",
                                   f"build_dir=build/failure-{index}")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("Error 23", result.stdout)
                records, = (self.project / f"build/failure-{index}").glob("runtime-check-*")
                self.assertTrue((records / "source/SHA256SUMS").is_file())
                self.assertIn("fixture failure: " + stage, (records / "check.log").read_text())
                self.assertEqual(self.calls()[-1]["stage"], stage)

    def test_runtime_check_rejects_a_changed_recovered_derivation(self):
        self.prepare_runtime_profiles()
        self.runtime_state.write_text(json.dumps({"mismatch": "original"}))
        result = self.make("check", "code", "only=runtime")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls()[-1]["stage"], "original-replay")
        records, = (self.project / "build").glob("runtime-check-*")
        self.assertNotEqual((records / "migration/original.drv").read_bytes(),
                            (records / "migration/original-recovered.drv").read_bytes())

    def test_runtime_firmware_check_rejects_a_changed_recovered_derivation(self):
        self.prepare_runtime_profiles()
        self.runtime_state.write_text(json.dumps({"mismatch": "firmware"}))
        result = self.make("check", "code", "only=runtime")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls()[-1]["stage"], "firmware-replay")
        records, = (self.project / "build").glob("runtime-check-*")
        self.assertNotEqual((records / "firmware/expected.drv").read_bytes(),
                            (records / "firmware/recovered.drv").read_bytes())

    def test_runtime_check_rejects_an_unusable_profile(self):
        self.prepare_runtime_profiles()
        for index, stage in enumerate(("runtime-profile.scm", "channel-profile")):
            with self.subTest(stage=stage):
                self.runtime_state.write_text(json.dumps({"invalid_profile": stage}))
                (self.root / "calls").unlink(missing_ok=True)
                result = self.make("check", "code", "only=runtime",
                                   f"build_dir=build/invalid-{index}")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.calls()[-1]["stage"], stage)
                records, = (self.project / f"build/invalid-{index}").glob("runtime-check-*")
                self.assertTrue((records / "source/SHA256SUMS").is_file())
                self.assertTrue((records / "check.log").is_file())

    def test_configuration_channel_profile_rejects_wrong_routes_and_paths(self):
        self.prepare_runtime_profiles()
        cases = (
            (("check", "code", "only=runtime", "channel_profile=/a/profile"),
             "channel_profile= is for make check code only=configuration"),
            (("build", "image", "channel_profile=/a/profile"),
             "channel_profile= is for make check code only=configuration"),
            (("check", "code", "only=configuration", "channel_profile=relative/profile"),
             "channel_profile must be an absolute profile directory"),
            (("check", "code", "only=configuration", "channel_profile=/missing/profile"),
             "Channel profile has no executable bin/guix"),
        )
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = self.make(*arguments)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn(message, result.stdout)
                self.assertFalse((self.root / "calls").exists())

    def test_existing_hardware_check_keeps_its_release_evaluator(self):
        self.prepare_runtime_profiles()
        result = self.make("check", "code", "only=hardware")
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.calls()
        self.assertEqual(calls[0]["args"][0], "time-machine")
        self.assertEqual(calls[0]["profile"], str(self.profiles[0]))
        self.assertTrue(all(call["profile"] == str(self.profiles[1]) for call in calls[1:]))
        self.assertTrue(any(argument.endswith("/packaging/guix/channels.scm")
                            for argument in calls[0]["args"]))

    def test_image_builds_keep_old_sources_when_development_continues(self):
        self.prepare_fake_guix()
        recipe = "packaging/guix/recipes/setup-install.scm"
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
                  if "--file=packaging/guix/recipes/setup-install.scm" in c["args"]]
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
        shutil.copytree(previous, invalid, symlinks=True)
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
                  if "--file=packaging/guix/recipes/setup-install.scm" in c["args"]]
        for arguments in builds:
            paths = [arguments[i + 1] for i, arg in enumerate(arguments) if arg == "-L"]
            self.assertEqual(len(paths), 3)
            self.assertEqual(paths[1:], ["packaging/guix/installer", "packaging/guix/channel"])
            self.assertTrue(Path(paths[0]).is_absolute())
            self.assertIn(Path(paths[0]).name, ("source", "installer-source"))
        for root in (self.project / "packaging/guix/installer", self.project / "packaging/guix/channel"):
            for path in root.rglob("*.scm"):
                source = "\n".join(line for line in path.read_text().splitlines()
                                   if not line.lstrip().startswith(";"))
                declaration = re.match(r"\s*\(define-module\s+\(([^()]*)\)", source)
                self.assertIsNotNone(declaration, f"Standalone file on module path: {path}")
                self.assertEqual(tuple(declaration.group(1).split()),
                                 path.relative_to(root).with_suffix("").parts)

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
                result = subprocess.run([shell, str(self.project / "scripts/packaging/build-image.sh")],
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
if args[0] == "scripts/packaging/asahi_source.py":
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
                result = subprocess.run([shell, str(self.project / "scripts/check-code.sh"),
                                         *arguments], cwd=self.root, env=environment,
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                self.assertEqual(result.returncode, 23 if failure else 0, result.stdout)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                source = Path(calls[0]["args"][2])
                self.assertEqual(source.name, "asahi-installer")
                self.assertEqual(source.parent.parent, Path("build with spaces"))
                self.assertNotEqual(source, Path("build with spaces/asahi-installer"))
                expected = ["scripts/packaging/asahi_source.py", "--directory",
                            str(source), "--cache-directory", "build with spaces/cache"]
                if arguments and arguments[-1]:
                    expected += ["--archive", archive]
                expected_calls = [{"args": expected, "source": None}]
                if failure != "prepare":
                    expected_calls.append({
                        "args": ["-m", "unittest", "discover", "-s", "tests", "-t", ".", "-v"],
                        "source": str((self.project / source).resolve()),
                    })
                self.assertEqual(calls, expected_calls)
                self.assertFalse((self.project / source.parent).exists())
                self.assertEqual(old_source.read_text(), "keep this edit")


if __name__ == "__main__":
    unittest.main()
