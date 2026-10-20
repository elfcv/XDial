import contextlib
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "build_update_acceptance", ROOT / "scripts/build-update-acceptance.py")
ACCEPTANCE = importlib.util.module_from_spec(SPEC)
# dataclasses resolve the script's string annotations through sys.modules.
sys.modules[SPEC.name] = ACCEPTANCE
SPEC.loader.exec_module(ACCEPTANCE)
REAL_RUN = subprocess.run
REAL_POPEN = subprocess.Popen
REAL_RMTREE = shutil.rmtree

ACCEPTANCE_ID = "pages-test"
PRIVATE_VARIABLES = ("XDIAL_RULE_SET_PRESETS_FILE", "XDIAL_SEED_PROFILE_FILE")
LEGACY_INFO_KEYS = ["sourceCommit", "acceptanceID", "createdAt", "packages",
                    "installed", "launched", "uploaded"]
LEGACY_PACKAGE_KEYS = ["role", "version", "tag", "build", "acceptanceID", "minimumSystemVersion",
                       "archive", "archiveSize", "archiveSHA256", "releaseNotes"]
# AppUpdateManifestParser and AppUpdateReleasePolicy.selectCandidate on the
# client; the feed repository writes the keys in this order.
FEED_KEYS = ["schemaVersion", "revision", "channel", "generatedAt", "release"]
RELEASE_KEYS = ["tag", "version", "build", "minimumSystemVersion", "publishedAt",
                "releaseNotes", "archiveURL", "archiveSize", "archiveSHA256"]
CORE = r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
CHANNEL_TAGS = {"stable": re.compile(CORE + r"\Z"),
                "beta": re.compile(CORE + r"-beta\.[1-9][0-9]*\Z")}
# Each package carries its own minimum, so a feed cannot borrow another's.
MINIMUM_SYSTEM = {"v1.0.0": "15.0", "v1.1.0-beta.1": "15.4", "v1.1.0": "15.5"}
TERMINATION_SIGNALS = (signal.SIGTERM, signal.SIGHUP)
STOP_SIGNALS = (signal.SIGINT, *TERMINATION_SIGNALS)
# Stands in for make release when a stop signal arrives during a build. Like
# make running xcodebuild, it starts a build step and, on SIGINT, cancels the
# step and waits for it, while SIGTERM ends it at once. It reports how it was
# started, signals the script (0 sends nothing) and then waits to be stopped
# or exits.
MAKE_STAND_IN = r'''
import json, os, signal, subprocess, sys, time

def note(record, **values):
    with open(record, "a") as stream:
        stream.write(json.dumps(values) + "\n")

if sys.argv[1] == "step":
    # Like a build task xcodebuild runs in a process group of its own, a task
    # step writes into the worktree on its way out, after the script is asked
    # to stop once more. A stubborn step stays in make's group and ignores
    # SIGINT and SIGTERM.
    record, mode, script, again = sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
    def finish(signum, frame):
        os.kill(script, again)
        time.sleep(0.3)
        os.makedirs("build/late", exist_ok=True)
        note(record, step_stopped=signum)
        sys.exit(0)
    for name in (signal.SIGINT, signal.SIGTERM):
        signal.signal(name, signal.SIG_IGN if mode == "stubborn" else finish)
    print("ready", flush=True)
else:
    record, signum, then, mode = sys.argv[2], int(sys.argv[3]), sys.argv[4], sys.argv[5]
    step = None
    def cancel(received, frame):
        if step:
            os.kill(step.pid, signal.SIGINT)
            step.wait()
        stopped(received, frame)
    def stopped(received, frame):
        note(record, make_stopped=received)
        sys.exit(128 + received)
    # Like make, it leaves SIGINT ignored when started with it ignored.
    interrupt_ignored = signal.getsignal(signal.SIGINT) is signal.SIG_IGN
    if mode == "stubborn":
        for name in (signal.SIGINT, signal.SIGTERM):
            signal.signal(name, signal.SIG_IGN)
    else:
        if not interrupt_ignored:
            signal.signal(signal.SIGINT, cancel)
        signal.signal(signal.SIGTERM, stopped)
    if mode != "none":
        step = subprocess.Popen([sys.executable, sys.argv[0], "step", record, mode,
                                 str(os.getppid()), str(signum)], stdout=subprocess.PIPE,
                                start_new_session=mode == "task")
        step.stdout.readline()
    note(record, make=os.getpid(), session=os.getsid(0), step=step and step.pid,
         step_group=step and os.getpgid(step.pid),
         blocked=sorted(signal.pthread_sigmask(signal.SIG_BLOCK, ())),
         hangup_ignored=signal.getsignal(signal.SIGHUP) is signal.SIG_IGN,
         interrupt_ignored=interrupt_ignored)
    os.kill(os.getppid(), signum)
    if then == "exit":
        sys.exit(0)
# Outliving a script that never stops it fails the test instead of hanging it.
time.sleep(15)
sys.exit(1)
'''


def git(directory: Path, *arguments: str) -> str:
    return REAL_RUN(["git", "-C", str(directory), *arguments],
                    check=True, capture_output=True, text=True).stdout.strip()


class BuildUpdateAcceptanceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        base = Path(temporary.name).resolve()
        self.output = base / "run"
        self.root = base / "repo"
        self.root.mkdir()
        git(self.root, "init", "--quiet", "--initial-branch=main")
        git(self.root, "config", "user.name", "XDial Test")
        git(self.root, "config", "user.email", "xdial-test@example.invalid")
        (self.root / ".gitignore").write_text("build/\nPrivateConfig/\n")
        # Each tag adds what a later stage of the release tooling introduced.
        makefile = ["RELEASE_TAG ?=", "RELEASE_BUILD_NUMBER ?="]
        self.commit("v0.1.0", makefile)
        makefile += ["RELEASE_UPDATE_ACCEPTANCE_ID ?=", "RELEASE_NOTES_FILE ?= RELEASE_NOTES.md"]
        self.commit("v1.0.0", makefile)
        switch = self.root / "macos/Sources/XDial/AppUpdateChecker.swift"
        switch.parent.mkdir(parents=True)
        switch.write_text('    static let key = "xdial.update.channel"\n')
        self.commit("v1.1.0", makefile)
        self.commit(None, makefile + ["RELEASE_CHANNEL ?= stable"])
        self.head = git(self.root, "rev-parse", "HEAD")
        self.builds = []
        self.fail_on = None
        self.signal_on = None
        self.signal_on_start = None
        self.make_then = "wait"
        self.make_step = "task"
        self.signal_on_cleanup = None
        self.worktree_remove_fails = False
        self.plist_overrides = {}
        self.stand_in = base / "make-stand-in.py"
        self.stand_in.write_text(MAKE_STAND_IN)
        self.record = base / "make-record.jsonl"
        # A stop signal the script leaves unhandled fails the test instead of
        # ending the test process; Ctrl-C raises as in a terminal.
        for signum in TERMINATION_SIGNALS:
            self.addCleanup(signal.signal, signum, signal.signal(signum, self.unexpected_signal))
        self.addCleanup(signal.signal, signal.SIGINT,
                        signal.signal(signal.SIGINT, signal.default_int_handler))
        self.addCleanup(signal.pthread_sigmask, signal.SIG_UNBLOCK, STOP_SIGNALS)
        self.addCleanup(self.kill_stand_ins)

    def unexpected_signal(self, signum, frame):
        raise AssertionError(f"signal {signum} reached the test")

    def stand_in_reports(self):
        if not self.record.exists():
            return {}
        reports = {}
        for line in self.record.read_text().splitlines():
            reports.update(json.loads(line))
        return reports

    def kill_stand_ins(self):
        """Leave nothing running when the script under test failed to stop it."""
        reports = self.stand_in_reports()
        for pid in filter(None, [reports.get("make"), reports.get("step")]):
            command = REAL_RUN(["ps", "-p", str(pid), "-o", "command="],
                               capture_output=True, text=True).stdout
            if str(self.stand_in) in command:
                os.kill(pid, signal.SIGKILL)

    def assert_gone(self, pid):
        with self.assertRaises(ProcessLookupError, msg=f"process {pid} still exists"):
            os.kill(pid, 0)

    def commit(self, tag, makefile):
        (self.root / "Makefile").write_text("\n".join(makefile) + "\n")
        git(self.root, "add", "--all")
        git(self.root, "commit", "--quiet", "-m", tag or "head")
        if tag:
            git(self.root, "tag", tag)

    def worktrees(self):
        listing = git(self.root, "worktree", "list", "--porcelain")
        return [Path(line[len("worktree "):]).resolve()
                for line in listing.splitlines() if line.startswith("worktree ")]

    def signal_cleanup(self, step):
        """Send the stop signal once, as the named cleanup step begins."""
        if self.signal_on_cleanup and self.signal_on_cleanup[0] == step:
            signum = self.signal_on_cleanup[1]
            self.signal_on_cleanup = None
            os.kill(os.getpid(), signum)

    def fake_rmtree(self, path, *arguments, **options):
        if Path(path).name.startswith("xdial-acceptance-"):
            self.signal_cleanup("scratch")
        return REAL_RMTREE(path, *arguments, **options)

    def reset_run(self):
        self.kill_stand_ins()
        with contextlib.suppress(FileNotFoundError):
            self.record.unlink()
        shutil.rmtree(self.output, ignore_errors=True)
        self.builds = []

    def fake_popen(self, command, *arguments, **options):
        if command[0] != "make":
            # subprocess.run starts git through Popen as well; nothing else may run.
            self.assertEqual(command[0], "git", command)
            return REAL_POPEN(command, *arguments, **options)
        # make runs for real as a stand-in process, started exactly as asked.
        stand_in = self.fake_make(command, options["cwd"], options["env"])
        process = REAL_POPEN(stand_in, *arguments, **options)
        if self.signal_on_start and str(self.stand_in) in stand_in:
            # The request lands once make runs, before the script holds it.
            deadline = time.monotonic() + 10
            while "make" not in self.stand_in_reports():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.02)
            signum, self.signal_on_start = self.signal_on_start, None
            os.kill(os.getpid(), signum)
        return process

    def fake_run(self, command, *arguments, **options):
        if command[:3] == ["git", "worktree", "remove"]:
            self.signal_cleanup("worktree")
            if self.worktree_remove_fails:
                return subprocess.CompletedProcess(command, 128)
        if command[0] == "ditto":
            source, target = map(Path, command[1:])
            if source.is_dir():
                shutil.copytree(source, target, symlinks=True)
            else:
                shutil.copy2(source, target)
            return subprocess.CompletedProcess(command, 0)
        # Nothing else may run: no xcodebuild, codesign, notarytool or stapler.
        self.assertEqual(command[0], "git", command)
        return REAL_RUN(command, *arguments, **options)

    def fake_make(self, command, cwd, env):
        """Record the build, write what make release leaves behind and return
        the command of the process that stands in for make."""
        self.assertEqual(command[:2], ["make", "release"])
        values = dict(argument.split("=", 1) for argument in command[2:])
        directory = Path(cwd).resolve()
        notes = Path(values["RELEASE_NOTES_FILE"])
        self.builds.append({
            "command": command, "cwd": directory, "head": git(directory, "rev-parse", "HEAD"),
            "registered": directory in self.worktrees(),
            "private": (directory / "macos/PrivateConfig").exists(),
            "notary": env.get("NOTARY_KEYCHAIN_PROFILE"), "notes": notes.read_text(),
        })
        tag = values["RELEASE_TAG"]
        if tag == self.fail_on:
            return ["/bin/sh", "-c", "exit 2"]
        release = directory / "build/release"
        contents = release / "XDial.app/Contents"
        contents.mkdir(parents=True, exist_ok=True)
        info = {
            "CFBundleShortVersionString": re.match(CORE, tag).group(0)[1:],
            "CFBundleVersion": values["RELEASE_BUILD_NUMBER"],
            "CFBundleIdentifier": "com.kafeifei.xdial.app",
            "XDialUpdateAcceptanceID": values["RELEASE_UPDATE_ACCEPTANCE_ID"],
            "LSMinimumSystemVersion": MINIMUM_SYSTEM[tag],
        }
        # Only Makefiles with the channel also write the release tag key.
        if "RELEASE_CHANNEL" in values:
            info["XDialReleaseTag"] = tag
        info.update(self.plist_overrides.get(tag, {}))
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        archive = release / f"XDial-{tag}.zip"
        archive.write_bytes(f"archive {tag}".encode())
        (release / f"XDial-{tag}.zip.sha256").write_text(f"checksum {tag}\n")
        (release / f"XDial-{tag}-notarization.json").write_text("{}\n")
        if self.signal_on and self.signal_on[0] == tag:
            return [sys.executable, str(self.stand_in), "make", str(self.record),
                    str(int(self.signal_on[1])), self.make_then, self.make_step]
        return ["/bin/sh", "-c", "exit 0"]

    def run_main(self, *arguments, environment=None, acceptance_id=ACCEPTANCE_ID,
                 lower="1.0.0", higher="1.1.0"):
        values = {name: value for name, value in os.environ.items()
                  if name not in PRIVATE_VARIABLES}
        values.update(environment or {})
        argv = ["--id", acceptance_id, "--lower-version", lower, "--higher-version", higher,
                "--output", str(self.output), "--notary-profile", "xdial-notary", *arguments]
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(ACCEPTANCE, "ROOT", self.root))
            stack.enter_context(patch.object(ACCEPTANCE.subprocess, "run", self.fake_run))
            stack.enter_context(patch.object(ACCEPTANCE.subprocess, "Popen", self.fake_popen))
            stack.enter_context(patch.object(ACCEPTANCE.shutil, "rmtree", self.fake_rmtree))
            stack.enter_context(patch.dict(os.environ, values, clear=True))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            ACCEPTANCE.main(argv)

    def rejected(self, *arguments, **options):
        stderr = io.StringIO()
        with self.assertRaises(SystemExit) as raised, contextlib.redirect_stderr(stderr):
            self.run_main(*arguments, **options)
        self.assertEqual(raised.exception.code, 2)
        self.assertEqual(self.builds, [])
        self.assertEqual(self.worktrees(), [self.root])
        return stderr.getvalue()

    def build_info(self):
        return json.loads((self.output / "BUILD-INFO.json").read_text(encoding="utf-8"))

    def expected_command(self, tag, build, channel, notes):
        command = ["make", "release", f"RELEASE_TAG={tag}", f"RELEASE_BUILD_NUMBER={build}"]
        if channel:
            command.append(f"RELEASE_CHANNEL={channel}")
        return command + [f"RELEASE_UPDATE_ACCEPTANCE_ID={ACCEPTANCE_ID}",
                          f"RELEASE_NOTES_FILE={self.output / notes}"]

    def first_build_number(self):
        return int(self.builds[0]["command"][3].split("=", 1)[1])

    def assert_client_accepts(self, text, channel):
        manifest = json.loads(text)
        self.assertEqual(text, json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
        self.assertEqual(list(manifest), FEED_KEYS)
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertIs(type(manifest["revision"]), int)
        self.assertGreater(manifest["revision"], 0)
        self.assertEqual(manifest["channel"], channel)
        timestamp = r"\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\Z"
        self.assertRegex(manifest["generatedAt"], timestamp)
        release = manifest["release"]
        self.assertEqual(list(release), RELEASE_KEYS)
        tag = CHANNEL_TAGS[channel].fullmatch(release["tag"])
        self.assertIsNotNone(tag, release["tag"])
        self.assertEqual(release["version"], ".".join(tag.groups()))
        self.assertRegex(release["build"], r"\A[1-9][0-9]*\Z")
        self.assertRegex(release["minimumSystemVersion"], r"\A(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){1,2}\Z")
        self.assertRegex(release["publishedAt"], timestamp)
        self.assertLessEqual(release["publishedAt"], manifest["generatedAt"])
        self.assertTrue(release["releaseNotes"].strip())
        self.assertEqual(release["archiveURL"],
                         "https://github.com/saymiao/xdial-updates/releases/download/"
                         f"{release['tag']}/XDial-{release['tag']}.zip")
        self.assertIs(type(release["archiveSize"]), int)
        self.assertGreater(release["archiveSize"], 0)
        self.assertRegex(release["archiveSHA256"], r"\A[0-9a-f]{64}\Z")
        return manifest

    def test_pair_mode_keeps_its_commands_and_build_info(self):
        self.run_main()

        number = self.first_build_number()
        self.assertEqual([build["command"] for build in self.builds], [
            self.expected_command("v1.0.0", number, "stable", "A-1.0.0/RELEASE_NOTES.md"),
            self.expected_command("v1.1.0", number + 1, "stable", "B-1.1.0/RELEASE_NOTES.md"),
        ])
        self.assertEqual({build["cwd"] for build in self.builds}, {self.root})
        self.assertEqual({build["notary"] for build in self.builds}, {"xdial-notary"})
        self.assertEqual(sorted(path.name for path in self.output.iterdir()),
                         ["A-1.0.0", "B-1.1.0", "BUILD-INFO.json"])
        info = self.build_info()
        self.assertEqual(list(info), LEGACY_INFO_KEYS)
        self.assertEqual(info["sourceCommit"], self.head)
        self.assertEqual([list(record) for record in info["packages"]], [LEGACY_PACKAGE_KEYS] * 2)
        self.assertEqual([(record["tag"], record["build"]) for record in info["packages"]],
                         [("v1.0.0", str(number)), ("v1.1.0", str(number + 1))])
        self.assertEqual(self.worktrees(), [self.root])

    def test_beta_builds_stable_beta_stable_in_one_clean_worktree(self):
        private = self.root / "macos/PrivateConfig/SeedProfile/preset.json"
        private.parent.mkdir(parents=True)
        private.write_text("{}\n")

        self.run_main("--beta")

        number = self.first_build_number()
        self.assertEqual([build["command"] for build in self.builds], [
            self.expected_command("v1.0.0", number, "stable", "A-1.0.0/RELEASE_NOTES.md"),
            self.expected_command("v1.1.0-beta.1", number + 1, "beta",
                                  "B-1.1.0-beta.1/BETA_RELEASE_NOTES.md"),
            self.expected_command("v1.1.0", number + 2, "stable", "C-1.1.0/RELEASE_NOTES.md"),
        ])
        checkout = self.builds[0]["cwd"]
        self.assertNotEqual(checkout, self.root)
        for build in self.builds:
            self.assertEqual(build["cwd"], checkout)
            self.assertEqual(build["head"], self.head)
            self.assertTrue(build["registered"])
            self.assertFalse(build["private"])
            self.assertEqual(build["notary"], "xdial-notary")
        for build, tag in zip(self.builds, ["v1.0.0", "v1.1.0-beta.1", "v1.1.0"]):
            self.assertTrue(build["notes"].startswith(f"# XDial {tag}\n\n## 更新了什么\n\n- "))
        self.assertFalse(checkout.exists())
        self.assertFalse(checkout.parent.exists())
        self.assertEqual(self.worktrees(), [self.root])

        info = self.build_info()
        self.assertEqual(info["sourceCommit"], self.head)
        self.assertEqual(
            [(record["role"], record["channel"], record["tag"], record["version"], record["build"],
              record["archiveName"], record["notesTitle"], record["sourceRef"],
              record["sourceCommit"], record["acceptanceID"])
             for record in info["packages"]],
            [("A", "stable", "v1.0.0", "1.0.0", str(number), "XDial-v1.0.0.zip",
              "# XDial v1.0.0", "HEAD", self.head, ACCEPTANCE_ID),
             ("B", "beta", "v1.1.0-beta.1", "1.1.0", str(number + 1),
              "XDial-v1.1.0-beta.1.zip", "# XDial v1.1.0-beta.1", "HEAD", self.head,
              ACCEPTANCE_ID),
             ("C", "stable", "v1.1.0", "1.1.0", str(number + 2), "XDial-v1.1.0.zip",
              "# XDial v1.1.0", "HEAD", self.head, ACCEPTANCE_ID)])
        for record in info["packages"]:
            archive = Path(record["archive"])
            self.assertEqual(archive.parent.parent, self.output)
            self.assertEqual(archive.name, record["archiveName"])
            self.assertEqual(record["archiveSHA256"], hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertEqual(record["archiveSize"], archive.stat().st_size)
            self.assertTrue((archive.parent / "XDial.app/Contents/Info.plist").is_file())
        # Only B's notes describe the beta; the stable packages keep the stable text.
        self.assertEqual(["beta" in record["releaseNotes"] for record in info["packages"]],
                         [False, True, False])
        self.assertEqual(["beta" in build["notes"] for build in self.builds],
                         [False, True, False])
        self.assertEqual(info["packages"][0]["releaseNotes"], info["packages"][2]["releaseNotes"])
        self.assertEqual(info["installed"], False)
        self.assertEqual(info["launched"], False)
        self.assertEqual(info["uploaded"], False)

    def test_beta_writes_the_feeds_each_step_needs(self):
        self.run_main("--beta")

        packages = {record["role"]: record for record in self.build_info()["packages"]}
        self.assertEqual([packages[role]["minimumSystemVersion"] for role in "ABC"],
                         [MINIMUM_SYSTEM[tag] for tag in ["v1.0.0", "v1.1.0-beta.1", "v1.1.0"]])
        feeds = self.output / "feeds"
        self.assertEqual(sorted(path.name for path in feeds.iterdir()), ["step-1", "step-3"])
        files = {}
        for step in ["step-1", "step-3"]:
            directory = feeds / step / "acceptance" / ACCEPTANCE_ID
            self.assertEqual(sorted(path.name for path in directory.iterdir()),
                             ["beta.json", "stable.json"])
            for channel in ["stable", "beta"]:
                text = (directory / f"{channel}.json").read_text(encoding="utf-8")
                files[step, channel] = (text, self.assert_client_accepts(text, channel))

        def release_of(role):
            record = packages[role]
            return {key: record[key] for key in
                    ["tag", "version", "build", "minimumSystemVersion", "releaseNotes",
                     "archiveSize", "archiveSHA256"]}

        def published(step, channel):
            release = dict(files[step, channel][1]["release"])
            for key in ["publishedAt", "archiveURL"]:
                release.pop(key)
            return release

        # Step 1 (and 2): stable stays at A, beta offers B. Step 3 publishes C.
        self.assertEqual(published("step-1", "stable"), release_of("A"))
        self.assertEqual(published("step-1", "beta"), release_of("B"))
        self.assertEqual(published("step-3", "stable"), release_of("C"))
        self.assertEqual(files["step-3", "beta"][0], files["step-1", "beta"][0])
        revision = files["step-1", "stable"][1]["revision"]
        self.assertEqual(files["step-1", "beta"][1]["revision"], revision)
        self.assertEqual(files["step-3", "stable"][1]["revision"], revision + 1)
        # Milliseconds, like the public feeds, so reruns never roll back.
        self.assertGreater(revision, 10 ** 12)
        self.assertEqual(self.build_info()["feeds"], [
            {"name": "step-1", "directory": str(feeds / "step-1/acceptance" / ACCEPTANCE_ID),
             "stable": {"revision": revision, "tag": "v1.0.0"},
             "beta": {"revision": revision, "tag": "v1.1.0-beta.1"}},
            {"name": "step-3", "directory": str(feeds / "step-3/acceptance" / ACCEPTANCE_ID),
             "stable": {"revision": revision + 1, "tag": "v1.1.0"},
             "beta": {"revision": revision, "tag": "v1.1.0-beta.1"}},
        ])

    def test_lower_ref_builds_both_packages_in_temporary_worktrees(self):
        # Ignored private configuration in the checkout reaches neither package,
        # so A and B differ only in their source refs.
        private = self.root / "macos/PrivateConfig/SeedProfile/preset.json"
        private.parent.mkdir(parents=True)
        private.write_text("{}\n")

        self.run_main("--lower-ref", "v1.0.0")

        number = self.first_build_number()
        lower, higher = self.builds
        # v1.0.0's Makefile predates RELEASE_CHANNEL, so A does not receive it.
        self.assertEqual(lower["command"],
                         self.expected_command("v1.0.0", number, None, "A-1.0.0/RELEASE_NOTES.md"))
        self.assertEqual(higher["command"], self.expected_command(
            "v1.1.0", number + 1, "stable", "B-1.1.0/RELEASE_NOTES.md"))
        self.assertEqual(lower["head"], git(self.root, "rev-parse", "v1.0.0^{commit}"))
        self.assertEqual(higher["head"], self.head)
        self.assertEqual(len({self.root, lower["cwd"], higher["cwd"]}), 3)
        for build in self.builds:
            self.assertTrue(build["registered"])
            self.assertFalse(build["private"])
            self.assertFalse(build["cwd"].exists())
        self.assertEqual(self.worktrees(), [self.root])
        info = self.build_info()
        self.assertEqual([(record["sourceRef"], record["sourceCommit"], record["channel"])
                          for record in info["packages"]],
                         [("v1.0.0", lower["head"], "stable"), ("HEAD", self.head, "stable")])
        self.assertNotIn("feeds", info)
        self.assertFalse((self.output / "feeds").exists())

    def test_beta_with_lower_ref_builds_A_from_the_ref(self):
        self.run_main("--beta", "--lower-ref", "v1.1.0")

        number = self.first_build_number()
        lower, beta, stable = self.builds
        self.assertEqual(lower["command"],
                         self.expected_command("v1.0.0", number, None, "A-1.0.0/RELEASE_NOTES.md"))
        self.assertEqual(lower["head"], git(self.root, "rev-parse", "v1.1.0^{commit}"))
        self.assertEqual({beta["cwd"], stable["cwd"]}, {beta["cwd"]})
        self.assertNotIn(beta["cwd"], {self.root, lower["cwd"]})
        self.assertEqual((beta["head"], stable["head"]), (self.head, self.head))
        self.assertEqual(beta["command"][4], "RELEASE_CHANNEL=beta")
        for build in self.builds:
            self.assertFalse(build["cwd"].exists())
        self.assertEqual(self.worktrees(), [self.root])
        self.assertEqual(self.build_info()["packages"][0]["sourceRef"], "v1.1.0")

    def test_worktrees_are_removed_when_a_build_fails(self):
        self.fail_on = "v1.1.0-beta.1"
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_main("--beta", "--lower-ref", "v1.1.0")

        self.assertEqual(len(self.builds), 2)
        for build in self.builds:
            self.assertTrue(build["registered"])
            self.assertFalse(build["cwd"].exists())
        self.assertEqual(self.worktrees(), [self.root])
        self.assertEqual([record["role"] for record in self.build_info()["packages"]], ["A"])
        self.assertFalse((self.output / "feeds").exists())

    def test_worktrees_are_unregistered_when_git_cannot_remove_them(self):
        self.worktree_remove_fails = True
        self.run_main("--beta", "--lower-ref", "v1.1.0")

        self.assertEqual(len(self.builds), 3)
        for build in self.builds:
            self.assertTrue(build["registered"])
            self.assertFalse(build["cwd"].exists())
        self.assertEqual(self.worktrees(), [self.root])

    def stopped_by(self, signum):
        """Ctrl-C raises KeyboardInterrupt; kill and a closed terminal exit."""
        return KeyboardInterrupt if signum == signal.SIGINT else SystemExit

    def assert_stopped_and_cleaned(self, raised, signum, interrupt=signal.default_int_handler):
        if signum != signal.SIGINT:
            self.assertEqual(raised.exception.code, 128 + signum)
        for build in self.builds:
            self.assertTrue(build["registered"])
            self.assertFalse(build["cwd"].exists())
            self.assertFalse(build["cwd"].parent.exists())
        self.assertEqual(self.worktrees(), [self.root])
        self.assertFalse((self.output / "feeds").exists())
        # The script hands the signals back as it found them.
        for name in TERMINATION_SIGNALS:
            self.assertEqual(signal.getsignal(name), self.unexpected_signal)
        self.assertIs(signal.getsignal(signal.SIGINT), interrupt)
        self.assertFalse(signal.pthread_sigmask(signal.SIG_BLOCK, set()) & set(STOP_SIGNALS))

    def assert_make_stopped(self, stopped=signal.SIGINT):
        """make ran in a session of its own with no stop signal held, stopped on
        the given signal (None: only SIGKILL ended it), and neither it nor the
        step it started outlived the cleanup."""
        reports = self.stand_in_reports()
        self.assertEqual(reports["session"], reports["make"])
        self.assertFalse(set(reports["blocked"]) & set(STOP_SIGNALS))
        self.assertFalse(reports["interrupt_ignored"])
        # A task step runs outside make's group, as xcodebuild's build tasks do.
        self.assertEqual(reports["step_group"] == reports["make"], self.make_step == "stubborn")
        self.assertEqual(reports.get("make_stopped"), stopped)
        # The step wrote into the worktree on its way out, before it was removed.
        self.assertEqual(reports.get("step_stopped"), stopped)
        self.assert_gone(reports["make"])
        self.assert_gone(reports["step"])

    def short_stop_sequence(self):
        """The stop sequence with short waits for what make ignores. Only for a
        make that ignores SIGINT: one that obeys it takes about as long as its
        task step's 0.3-second wind-down, so a 0.3-second grace races it."""
        return tuple((signum, 0.3 if signum != signal.SIGKILL else grace)
                     for signum, grace in ACCEPTANCE.STOP_SEQUENCE)

    def test_termination_signals_still_remove_the_worktrees(self):
        # kill and a closed terminal end Python without finally blocks by
        # default; make runs in its own session, so for all three the script
        # has to stop it and every step it started.
        for signum in STOP_SIGNALS:
            with self.subTest(signal=signum):
                self.reset_run()
                self.signal_on = ("v1.1.0-beta.1", signum)
                with self.assertRaises(self.stopped_by(signum)) as raised:
                    self.run_main("--beta", "--lower-ref", "v1.1.0")
                self.assertEqual(len(self.builds), 2)
                self.assert_make_stopped()
                self.assert_stopped_and_cleaned(raised, signum)

    def test_a_stop_signal_while_make_starts_still_stops_it(self):
        for signum in STOP_SIGNALS:
            with self.subTest(signal=signum):
                self.reset_run()
                self.signal_on = ("v1.1.0-beta.1", 0)
                self.signal_on_start = signum
                with self.assertRaises(self.stopped_by(signum)) as raised:
                    self.run_main("--beta", "--lower-ref", "v1.1.0")
                self.assertIsNone(self.signal_on_start)
                self.assertEqual(len(self.builds), 2)
                self.assert_make_stopped()
                self.assert_stopped_and_cleaned(raised, signum)

    def test_make_receives_sigint_even_when_the_script_ignores_it(self):
        # A non-interactive shell starts a background job with SIGINT ignored.
        self.addCleanup(signal.signal, signal.SIGINT, signal.signal(signal.SIGINT, signal.SIG_IGN))
        self.signal_on = ("v1.1.0-beta.1", signal.SIGTERM)
        # make obeys SIGINT here, so it keeps the full grace that SIGINT gets.
        with self.assertRaises(SystemExit) as raised:
            self.run_main("--beta", "--lower-ref", "v1.1.0")
        self.assert_make_stopped()
        self.assert_stopped_and_cleaned(raised, signal.SIGTERM, interrupt=signal.SIG_IGN)

    def test_make_that_ignores_sigint_and_sigterm_is_killed_before_the_cleanup(self):
        self.signal_on = ("v1.1.0-beta.1", signal.SIGTERM)
        self.make_step = "stubborn"
        stderr = io.StringIO()
        with patch.object(ACCEPTANCE, "STOP_SEQUENCE", self.short_stop_sequence()), \
                contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
            self.run_main("--beta", "--lower-ref", "v1.1.0")
        self.assert_make_stopped(stopped=None)
        self.assert_stopped_and_cleaned(raised, signal.SIGTERM)
        self.assertIn("did not stop on SIGINT", stderr.getvalue())

    def test_an_ignored_hangup_stays_ignored(self):
        # Under nohup a closed terminal must stop neither the script nor make.
        self.addCleanup(signal.signal, signal.SIGHUP, signal.signal(signal.SIGHUP, signal.SIG_IGN))
        self.signal_on = ("v1.1.0-beta.1", signal.SIGHUP)
        self.make_then = "exit"
        self.make_step = "none"

        self.run_main("--beta", "--lower-ref", "v1.1.0")

        self.assertEqual(len(self.builds), 3)
        self.assertTrue(self.stand_in_reports()["hangup_ignored"])
        self.assertTrue((self.output / "feeds").is_dir())
        self.assertEqual(self.worktrees(), [self.root])
        self.assertIs(signal.getsignal(signal.SIGHUP), signal.SIG_IGN)
        self.assertEqual(signal.getsignal(signal.SIGTERM), self.unexpected_signal)

    def test_a_stop_signal_during_cleanup_waits_for_it(self):
        # Each signal once the builds are done; Ctrl-C also as the second of
        # two presses, the first stopping B's build.
        cases = [(signum, None) for signum in STOP_SIGNALS] + [(signal.SIGINT, "v1.1.0-beta.1")]
        for step in ["worktree", "scratch"]:
            for signum, interrupted in cases:
                with self.subTest(step=step, signal=signum, interrupted=interrupted):
                    self.reset_run()
                    self.signal_on = interrupted and (interrupted, signum)
                    self.signal_on_cleanup = (step, signum)
                    with self.assertRaises(self.stopped_by(signum)) as raised:
                        self.run_main("--beta", "--lower-ref", "v1.1.0")
                    self.assertIsNone(self.signal_on_cleanup)
                    self.assertEqual(len(self.builds), 2 if interrupted else 3)
                    if interrupted:
                        self.assert_make_stopped()
                    self.assert_stopped_and_cleaned(raised, signum)

    def test_one_stop_request_is_enough(self):
        cleaned = False
        with self.assertRaises(SystemExit) as raised:
            with ACCEPTANCE.exit_on_termination():
                try:
                    os.kill(os.getpid(), signal.SIGTERM)
                finally:
                    # A second request while cleaning up must not cut it short.
                    os.kill(os.getpid(), signal.SIGHUP)
                    cleaned = True
        self.assertEqual(raised.exception.code, 128 + signal.SIGTERM)
        self.assertTrue(cleaned)
        for name in TERMINATION_SIGNALS:
            self.assertEqual(signal.getsignal(name), self.unexpected_signal)

    def test_rejects_a_package_whose_identity_differs_and_still_cleans_up(self):
        for tag, override in [("v1.1.0-beta.1", {"XDialReleaseTag": ""}),
                              ("v1.1.0", {"XDialReleaseTag": "v1.1.0-beta.1"}),
                              ("v1.0.0", {"XDialUpdateAcceptanceID": "other"}),
                              ("v1.1.0-beta.1", {"CFBundleVersion": "1"}),
                              ("v1.1.0", {"CFBundleShortVersionString": "1.0.0"}),
                              ("v1.0.0", {"CFBundleIdentifier": "com.kafeifei.xdial.debug"})]:
            with self.subTest(tag=tag, override=override):
                shutil.rmtree(self.output, ignore_errors=True)
                self.builds = []
                self.plist_overrides = {tag: override}
                with self.assertRaisesRegex(RuntimeError, "identity does not match"):
                    self.run_main("--beta")
                self.assertEqual(self.worktrees(), [self.root])
                self.assertFalse(self.builds[0]["cwd"].exists())

    def test_rejects_lower_refs_that_cannot_build_the_package(self):
        self.assertIn("does not name a commit", self.rejected("--lower-ref", "v9.9.9"))
        message = self.rejected("--lower-ref", "v0.1.0")
        self.assertIn("predates acceptance builds", message)
        self.assertIn("RELEASE_UPDATE_ACCEPTANCE_ID, RELEASE_NOTES_FILE", message)
        message = self.rejected("--beta", "--lower-ref", "v1.0.0")
        self.assertIn("has no beta switch (xdial.update.channel)", message)
        self.assertFalse(self.output.exists())

    def test_worktree_sets_refuse_private_configuration_before_building(self):
        modes = [("--beta",), ("--lower-ref", "v1.0.0"), ("--beta", "--lower-ref", "v1.1.0")]
        for mode in modes:
            for name in PRIVATE_VARIABLES:
                with self.subTest(mode=mode, name=name):
                    message = self.rejected(*mode, environment={name: "/private/preset.json"})
                    self.assertIn(f"${name}", message)
                    self.assertFalse(self.output.exists())
        path = "macos/PrivateConfig/RuleSetPresets.json"
        tracked = self.root / path
        tracked.parent.mkdir(parents=True)
        tracked.write_text("{}\n")
        git(self.root, "add", "--force", str(tracked))
        git(self.root, "commit", "--quiet", "-m", "tracked private configuration")
        git(self.root, "tag", "v1.2.0")
        for mode in modes:
            with self.subTest(mode=mode, tracked="HEAD"):
                self.assertIn(path, self.rejected(*mode))
                self.assertFalse(self.output.exists())
        # A lower ref that tracks it is refused too, though HEAD no longer does.
        git(self.root, "rm", "--quiet", "--cached", path)
        git(self.root, "commit", "--quiet", "-m", "untrack private configuration")
        for mode in [("--lower-ref", "v1.2.0"), ("--beta", "--lower-ref", "v1.2.0")]:
            with self.subTest(mode=mode, tracked="v1.2.0"):
                self.assertIn(path, self.rejected(*mode))
                self.assertFalse(self.output.exists())

        # Stable packages may carry it, so the pair keeps its old behavior.
        self.run_main(environment={"XDIAL_SEED_PROFILE_FILE": "/private/preset.json"})
        self.assertEqual(len(self.builds), 2)

    def test_validates_arguments_before_building(self):
        cases = [
            ({"lower": "1.1.0"}, "must be newer"),
            ({"lower": "1.2.0"}, "must be newer"),
            ({"higher": "1.1"}, "canonical"),
            ({"higher": "v1.1.0"}, "canonical"),
            ({"lower": "1.01.0"}, "canonical"),
            ({"acceptance_id": "pages_test"}, "invalid acceptance ID"),
            ({"acceptance_id": "pages.test"}, "invalid acceptance ID"),
            ({"acceptance_id": "a" * 81}, "invalid acceptance ID"),
        ]
        for options, message in cases:
            for mode in [(), ("--beta",)]:
                with self.subTest(options=options, mode=mode):
                    self.assertIn(message, self.rejected(*mode, **options))
                    self.assertFalse(self.output.exists())

        self.output.mkdir()
        self.assertIn("already exists", self.rejected("--beta"))
        self.assertEqual(list(self.output.iterdir()), [])
        self.output.rmdir()

        (self.root / "uncommitted.txt").write_text("change\n")
        self.assertIn("commit the accepted source changes", self.rejected("--beta"))
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
