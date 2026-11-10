# SPDX-FileCopyrightText: 2026 Harish Narayanan
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check system-build routing, record retention and failure handling."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[2]


class SystemBuildTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.project = self.root / "project"
        (self.project / "scripts/system").mkdir(parents=True)
        for name in ("Makefile", "scripts/system/build.sh", "scripts/system/runtime-profile.scm"):
            shutil.copyfile(PROJECT / name, self.project / name)
        self.configuration = self.root / "reviewed config.scm"
        self.configuration.write_text("(operating-system)\n")
        self.commands = self.root / "commands"
        self.commands.mkdir()
        for name, value in (("uname", "Linux"), ("id", "1000")):
            command = self.commands / name
            command.write_text("#!/bin/sh\nprintf '%s\\n' " + value + "\n")
            command.chmod(0o755)
        self.profile = self.root / "complete profile"
        (self.profile / "bin").mkdir(parents=True)
        self.output = self.root / "built system"
        self.output.mkdir()
        self.calls = self.root / "calls"
        self.failure = self.root / "failure"
        self.fake_guix = self.profile / "bin/guix"
        self.fake_guix.write_text("#!" + sys.executable + "\n" + f'''
import json, os, pathlib, sys
args = sys.argv[1:]
with pathlib.Path({str(self.calls)!r}).open("a") as stream:
    stream.write(json.dumps({{"args": args, "env": dict(os.environ)}}) + "\\n")
if args[0] == "repl":
    sys.stdin.read()
    print({str(self.profile)!r})
elif args == ["describe", "-f", "channels"]:
    print("(list (channel (name 'guix)))")
elif args[:2] == ["system", "build"]:
    if pathlib.Path({str(self.failure)!r}).exists():
        print("build failed", file=sys.stderr)
        sys.exit(23)
    root = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--root="))
    pathlib.Path(root).symlink_to({str(self.output)!r})
    print({str(self.output)!r})
else:
    sys.exit("Unexpected operation")
''')
        self.fake_guix.chmod(0o755)
        self.environment = {key: os.environ[key] for key in ("PATH", "TMPDIR")
                            if key in os.environ}
        self.environment["PATH"] = str(self.commands) + os.pathsep + self.environment["PATH"]
        self.environment["GUIX"] = str(self.fake_guix)
        self.environment["GUILE_LOAD_PATH"] = "/untrusted/local/modules"

    def make(self, *arguments):
        return subprocess.run(["make", *arguments], cwd=self.project,
                              env=self.environment, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def test_plan_needs_no_guix_and_creates_no_records(self):
        self.environment["GUIX"] = "/nonexistent/guix"
        result = self.make("plan", "system", f"configuration={self.configuration}")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Dependencies and downloads", result.stdout)
        self.assertFalse((self.project / "build").exists())
        self.assertFalse(self.calls.exists())

    def test_build_retains_normal_graft_result_with_exact_selected_profile(self):
        self.environment["GUIX_DAEMON_SOCKET"] = "/fixture/daemon"
        result = self.make("build", "system", f"configuration={self.configuration}",
                           "jobs=1", "cores=2", "build_dir=build/system trial")
        self.assertEqual(result.returncode, 0, result.stdout)
        records, = (self.project / "build/system trial").iterdir()
        self.assertEqual((records / "system").resolve(), self.output)
        self.assertEqual((records / "profile").read_text().strip(), str(self.profile))
        self.assertEqual((records / "status").read_text(), "0\n")
        self.assertIn("(channel", (records / "channels.scm").read_text())
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual([call["args"][:2] for call in calls],
                         [["repl", "scripts/system/runtime-profile.scm"], ["describe", "-f"], ["system", "build"]])
        self.assertEqual(calls[-1]["args"],
                         ["system", "build", "--save-provenance", f"--root={records}/system",
                          "--max-jobs=1", "--cores=2", str(self.configuration)])
        self.assertEqual(calls[-1]["env"]["PATH"], str(self.profile / "bin"))
        self.assertEqual(calls[-1]["env"]["GUIX_DAEMON_SOCKET"], "/fixture/daemon")
        self.assertNotIn("GUILE_LOAD_PATH", calls[-1]["env"])

    def test_failed_build_keeps_log_and_nonzero_status_without_success_root(self):
        self.failure.touch()
        result = self.make("build", "system", f"configuration={self.configuration}")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        records, = (self.project / "build").iterdir()
        self.assertEqual((records / "status").read_text(), "23\n")
        self.assertIn("build failed", (records / "build.log").read_text())
        self.assertFalse((records / "system").exists())

    def test_missing_or_relative_configuration_is_rejected_before_guix(self):
        for option in ([], ["configuration=relative.scm"], ["configuration=/missing/config.scm"]):
            with self.subTest(option=option):
                result = self.make("build", "system", *option)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.calls.exists())
                self.assertFalse((self.project / "build").exists())


if __name__ == "__main__":
    unittest.main()
