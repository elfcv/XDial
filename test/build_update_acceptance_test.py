import contextlib
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
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
        self.plist_overrides = {}

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

    def fake_run(self, command, *arguments, **options):
        if command[0] == "make":
            return self.fake_make(command, **options)
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

    def fake_make(self, command, cwd, env, stdout, stderr, check):
        self.assertEqual(command[:2], ["make", "release"])
        self.assertTrue(check)
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
            raise subprocess.CalledProcessError(2, command)
        release = directory / "build/release"
        contents = release / "XDial.app/Contents"
        contents.mkdir(parents=True, exist_ok=True)
        info = {
            "CFBundleShortVersionString": re.match(CORE, tag).group(0)[1:],
            "CFBundleVersion": values["RELEASE_BUILD_NUMBER"],
            "CFBundleIdentifier": "com.kafeifei.xdial.app",
            "XDialUpdateAcceptanceID": values["RELEASE_UPDATE_ACCEPTANCE_ID"],
            "LSMinimumSystemVersion": "15.0",
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
        return subprocess.CompletedProcess(command, 0)

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

    def test_lower_ref_builds_A_in_a_temporary_worktree(self):
        self.run_main("--lower-ref", "v1.0.0")

        number = self.first_build_number()
        lower, higher = self.builds
        # v1.0.0's Makefile predates RELEASE_CHANNEL, so A does not receive it.
        self.assertEqual(lower["command"],
                         self.expected_command("v1.0.0", number, None, "A-1.0.0/RELEASE_NOTES.md"))
        self.assertEqual(higher["command"], self.expected_command(
            "v1.1.0", number + 1, "stable", "B-1.1.0/RELEASE_NOTES.md"))
        self.assertEqual(lower["head"], git(self.root, "rev-parse", "v1.0.0^{commit}"))
        self.assertNotEqual(lower["cwd"], self.root)
        self.assertTrue(lower["registered"])
        self.assertEqual(higher["cwd"], self.root)
        self.assertFalse(lower["cwd"].exists())
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

    def test_rejects_a_package_whose_identity_differs_and_still_cleans_up(self):
        for tag, override in [("v1.1.0-beta.1", {"XDialReleaseTag": ""}),
                              ("v1.1.0", {"XDialReleaseTag": "v1.1.0-beta.1"}),
                              ("v1.0.0", {"XDialUpdateAcceptanceID": "other"})]:
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

    def test_beta_refuses_private_configuration_before_building(self):
        for name in PRIVATE_VARIABLES:
            with self.subTest(name=name):
                message = self.rejected("--beta", environment={name: "/private/preset.json"})
                self.assertIn(f"${name}", message)
                self.assertFalse(self.output.exists())
        tracked = self.root / "macos/PrivateConfig/RuleSetPresets.json"
        tracked.parent.mkdir(parents=True)
        tracked.write_text("{}\n")
        git(self.root, "add", "--force", str(tracked))
        git(self.root, "commit", "--quiet", "-m", "tracked private configuration")
        message = self.rejected("--beta")
        self.assertIn("macos/PrivateConfig/RuleSetPresets.json", message)
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
