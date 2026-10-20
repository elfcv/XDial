#!/usr/bin/env python3
"""Build notarized, formal-identity applications for an isolated update test.

By default this builds a stable A/B pair. --beta builds a stable A, a beta B
and a stable C with one acceptance ID, plus the acceptance feeds every step
needs. --lower-ref builds A from an older git ref instead of HEAD.

This creates local artifacts only. It never installs, launches, uploads, or
changes the public feeds or the feed repository.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import datetime as dt
import hashlib
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
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
ACCEPTANCE_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,79}\Z")
NOTES = """- 从 GitHub Pages 获取版本、完整更新说明和安装包信息。
- 下载后核对大小、SHA-256、签名及组件版本，安装前重新确认更新仍有效。
- 此包仅用于正式身份的更新验收，不进入正式更新清单。
"""
BETA_NOTES = """- 开启“接收 beta 版本”的 A 应升级到此 beta；关闭开关后停留在此版本，显示“等待正式版”。
- 同一版本号的正式版 C 发布后，应从此 beta 升级到 C。
- 此包仅用于正式身份的更新验收，不进入正式更新清单。
"""
APPLICATION_IDENTIFIER = "com.kafeifei.xdial.app"
# An acceptance feed's archives must come from the feed repository's releases.
ACCEPTANCE_ARCHIVES = "https://github.com/saymiao/xdial-updates/releases/download"
# What a Release build embeds for a preset configuration package
# (macos/project.yml); the beta contract rejects a bundle that carries either.
PRIVATE_CONFIGURATION_VARIABLES = ("XDIAL_RULE_SET_PRESETS_FILE", "XDIAL_SEED_PROFILE_FILE")
PRIVATE_CONFIGURATION_PATH = "macos/PrivateConfig"
# The preference behind "接收 beta 版本"; a client without it cannot open step 1.
BETA_SWITCH_KEY = "xdial.update.channel"
# Variables an older ref's Makefile must declare to build an acceptance package.
LOWER_REF_VARIABLES = ("RELEASE_UPDATE_ACCEPTANCE_ID", "RELEASE_NOTES_FILE")
# `kill` sends SIGTERM and a closed terminal SIGHUP; by default either ends
# Python without running finally blocks. Ctrl-C (SIGINT) already raises.
TERMINATION_SIGNALS = (signal.SIGTERM, signal.SIGHUP)
STOP_SIGNALS = (signal.SIGINT, *TERMINATION_SIGNALS)
# What make release's process group receives on a stop request, in turn, and
# how many seconds each signal gets. SIGINT comes first, as from Ctrl-C in a
# terminal: xcodebuild then cancels the build tasks it runs in process groups
# of their own and waits for them, where SIGTERM ends xcodebuild at once and
# leaves them writing into the worktree.
STOP_SEQUENCE = ((signal.SIGINT, 30.0), (signal.SIGTERM, 5.0), (signal.SIGKILL, 5.0))


@dataclasses.dataclass(frozen=True)
class Source:
    """A commit make release runs in, and the variables its Makefile declares."""

    ref: str
    commit: str
    directory: Path
    variables: frozenset


@dataclasses.dataclass(frozen=True)
class Package:
    role: str
    channel: str
    version: str
    tag: str
    build: int
    source: Source

    @property
    def directory_name(self) -> str:
        return f"{self.role}-{self.tag[1:]}"

    @property
    def archive_name(self) -> str:
        return f"XDial-{self.tag}.zip"

    @property
    def notes_name(self) -> str:
        return "BETA_RELEASE_NOTES.md" if self.channel == "beta" else "RELEASE_NOTES.md"

    @property
    def notes_title(self) -> str:
        return f"# XDial {self.tag}"

    @property
    def notes(self) -> str:
        return BETA_NOTES if self.channel == "beta" else NOTES


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def git(*arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], cwd=ROOT, text=True).strip()


def resolve_commit(ref: str) -> str | None:
    result = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"],
                            cwd=ROOT, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None


def makefile_variables(commit: str) -> frozenset:
    """Variables the commit's Makefile assigns; an older Makefile ignores the rest."""
    return frozenset(re.findall(r"^([A-Z][A-Z0-9_]*)[ \t]*[:?+]?=",
                                git("show", f"{commit}:Makefile"), re.MULTILINE))


def has_beta_switch(commit: str) -> bool:
    return subprocess.run(["git", "grep", "--quiet", "--fixed-strings", BETA_SWITCH_KEY, commit,
                           "--", "macos/Sources"], cwd=ROOT).returncode == 0


def private_configuration(commits: list, environment: dict) -> list:
    """Private inputs a build of the commits would embed. A temporary worktree
    holds only tracked files, so the ignored macos/PrivateConfig never reaches it."""
    found = [f"${name}" for name in PRIVATE_CONFIGURATION_VARIABLES if environment.get(name)]
    for commit in dict.fromkeys(commits):
        found += git("ls-tree", "-r", "--name-only", commit, "--",
                     PRIVATE_CONFIGURATION_PATH).splitlines()
    return found


@contextlib.contextmanager
def exit_on_termination():
    """Raise SystemExit for SIGTERM and SIGHUP, as Ctrl-C raises
    KeyboardInterrupt, so the temporary worktrees are still removed. One stop
    request is enough: later termination signals are ignored. A signal ignored
    on entry, such as SIGHUP under nohup, stays ignored, for make as well."""
    def terminate(signum, frame):
        for name in TERMINATION_SIGNALS:
            signal.signal(name, signal.SIG_IGN)
        sys.exit(128 + signum)
    previous = {name: signal.signal(name, terminate) for name in TERMINATION_SIGNALS
                if signal.getsignal(name) is not signal.SIG_IGN}
    try:
        yield
    finally:
        for name, handler in previous.items():
            signal.signal(name, handler)


@contextlib.contextmanager
def signals_deferred():
    """Hold stop signals while a cleanup runs, so none can cut it short; they
    arrive once it is done. Yields the mask to restore."""
    held = signal.pthread_sigmask(signal.SIG_BLOCK, STOP_SIGNALS)
    try:
        yield held
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, held)


def process_group_ended(process: subprocess.Popen, seconds: float) -> bool:
    """Whether every process in make's group is gone within seconds."""
    deadline = time.monotonic() + seconds
    while True:
        process.poll()  # reaps make, the group leader, once it has exited
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            pass  # macOS answers EPERM while the group holds only unreaped zombies
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.05)


def stop_release(process: subprocess.Popen, directory: Path) -> None:
    """Signal make's process group along STOP_SEQUENCE until none of it runs:
    a survivor would write build/ into the worktree again after it is removed."""
    for attempt, (signum, grace) in enumerate(STOP_SEQUENCE):
        with contextlib.suppress(ProcessLookupError, PermissionError):
            os.killpg(process.pid, signum)
        if process_group_ended(process, grace):
            if attempt:
                print(f"warning: make release did not stop on SIGINT; build tasks xcodebuild "
                      f"started may still write into {directory}", file=sys.stderr, flush=True)
            return
    print(f"warning: make release (process group {process.pid}) is still running; stop it "
          f"with kill -KILL -{process.pid}", file=sys.stderr, flush=True)


def run_release(command: list, directory: Path, environment: dict, stream) -> None:
    """Run make release in a session of its own, so only this script receives
    the terminal's Ctrl-C and hangup, and stop it on any stop request before
    the worktree is removed."""
    process = None
    try:
        # A signal arriving while make starts waits until process is set.
        with signals_deferred() as held:
            def prepare():
                # make must not inherit the held signals, and acts on the
                # SIGINT stop_release sends even if this script ignores it.
                signal.signal(signal.SIGINT, signal.SIG_DFL)
                signal.pthread_sigmask(signal.SIG_SETMASK, held)
            process = subprocess.Popen(
                command, cwd=directory, env=environment, stdout=stream,
                stderr=subprocess.STDOUT, start_new_session=True, preexec_fn=prepare)
        returncode = process.wait()
    except BaseException:
        if process is not None:
            with signals_deferred():
                stop_release(process, directory)
        raise
    if returncode:
        raise subprocess.CalledProcessError(returncode, command)


def remove_directory(directory: Path) -> None:
    with signals_deferred():
        shutil.rmtree(directory, ignore_errors=True)


@contextlib.contextmanager
def temporary_worktree(commit: str, directory: Path):
    """A detached checkout of commit, removed on success and on any failure."""
    try:
        subprocess.run(["git", "worktree", "add", "--quiet", "--detach", str(directory), commit],
                       cwd=ROOT, check=True)
        yield directory
    finally:
        with signals_deferred():
            subprocess.run(["git", "worktree", "remove", "--force", str(directory)],
                           cwd=ROOT, stderr=subprocess.DEVNULL, check=False)
            shutil.rmtree(directory, ignore_errors=True)
            subprocess.run(["git", "worktree", "prune"], cwd=ROOT, check=False)
            if directory.exists():
                print(f"warning: could not remove the temporary worktree {directory}; run "
                      f"git worktree remove --force {directory}", file=sys.stderr, flush=True)


def plan_packages(lower: str, higher: str, beta: bool, build_number: int,
                  lower_source: Source, higher_source: Source) -> list:
    packages = [Package("A", "stable", lower, f"v{lower}", build_number, lower_source)]
    if not beta:
        return packages + [
            Package("B", "stable", higher, f"v{higher}", build_number + 1, higher_source),
        ]
    return packages + [
        Package("B", "beta", higher, f"v{higher}-beta.1", build_number + 1, higher_source),
        Package("C", "stable", higher, f"v{higher}", build_number + 2, higher_source),
    ]


def release_command(package: Package, acceptance_id: str, notes: Path) -> list:
    command = ["make", "release", f"RELEASE_TAG={package.tag}",
               f"RELEASE_BUILD_NUMBER={package.build}"]
    # A Makefile from before the beta channel builds stable only and has no
    # RELEASE_CHANNEL; only a Makefile that declares it receives it.
    if "RELEASE_CHANNEL" in package.source.variables:
        command.append(f"RELEASE_CHANNEL={package.channel}")
    return command + [f"RELEASE_UPDATE_ACCEPTANCE_ID={acceptance_id}",
                      f"RELEASE_NOTES_FILE={notes}"]


def build_package(package: Package, acceptance_id: str, output: Path, environment: dict,
                  extended: bool) -> dict:
    target = output / package.directory_name
    target.mkdir()
    notes = target / package.notes_name
    notes.write_text(f"{package.notes_title}\n\n## 更新了什么\n\n{package.notes}", encoding="utf-8")
    log = target / "build.log"
    origin = "" if package.source.directory == ROOT else f" from {package.source.ref}"
    print(f"Building and notarizing {package.role}: {package.tag[1:]} / {package.build}{origin}",
          flush=True)
    with log.open("w") as stream:
        run_release(release_command(package, acceptance_id, notes), package.source.directory,
                    environment, stream)
    source = package.source.directory / "build/release"
    names = ["XDial.app", package.archive_name, f"{package.archive_name}.sha256",
             f"XDial-{package.tag}-notarization.json"]
    for name in names:
        subprocess.run(["ditto", str(source / name), str(target / name)], check=True)
    info = plistlib.loads((target / "XDial.app/Contents/Info.plist").read_bytes())
    # Mirrors the release contract: a beta carries its exact tag, stable may leave it empty.
    release_tag = info.get("XDialReleaseTag", "")
    if (info.get("CFBundleShortVersionString") != package.version
            or info.get("CFBundleVersion") != str(package.build)
            or info.get("CFBundleIdentifier") != APPLICATION_IDENTIFIER
            or info.get("XDialUpdateAcceptanceID") != acceptance_id
            or release_tag not in ("", package.tag)
            or (package.channel == "beta" and release_tag != package.tag)):
        raise RuntimeError("signed acceptance package identity does not match the requested build")
    archive = target / package.archive_name
    record = {
        "role": package.role, "version": package.version, "tag": package.tag,
        "build": str(package.build), "acceptanceID": acceptance_id,
        "minimumSystemVersion": info["LSMinimumSystemVersion"],
        "archive": str(archive), "archiveSize": archive.stat().st_size,
        "archiveSHA256": digest(archive), "releaseNotes": package.notes.strip(),
    }
    if extended:
        record.update({
            "channel": package.channel, "archiveName": package.archive_name,
            "notesTitle": package.notes_title, "sourceRef": package.source.ref,
            "sourceCommit": package.source.commit,
        })
    return record


def acceptance_feed(channel: str, revision: int, generated_at: str, release: dict | None) -> str:
    """acceptance/<ID>/<channel>.json with the public feeds' keys, order and bytes."""
    return json.dumps({
        "schemaVersion": 1, "revision": revision, "channel": channel,
        "generatedAt": generated_at, "release": release,
    }, indent=2, ensure_ascii=False) + "\n"


def feed_release(package: dict, published_at: str) -> dict:
    tag = package["tag"]
    return {
        "tag": tag, "version": package["version"], "build": package["build"],
        "minimumSystemVersion": package["minimumSystemVersion"], "publishedAt": published_at,
        "releaseNotes": package["releaseNotes"],
        "archiveURL": f"{ACCEPTANCE_ARCHIVES}/{tag}/XDial-{tag}.zip",
        "archiveSize": package["archiveSize"], "archiveSHA256": package["archiveSHA256"],
    }


def write_acceptance_feeds(output: Path, acceptance_id: str, packages: list,
                           now: dt.datetime) -> list:
    """step-1 (stable A, beta B) serves steps 1 and 2; step-3 publishes C to
    stable.json and leaves beta.json byte-for-byte unchanged. Revisions use
    milliseconds like the public feeds, so a rerun with the same ID never rolls
    back the client's cached revision."""
    generated_at = now.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    revision = int(now.timestamp() * 1000)
    lower, beta, higher = packages
    beta_feed = acceptance_feed("beta", revision, generated_at, feed_release(beta, generated_at))
    steps = []
    for name, stable_revision, stable in (("step-1", revision, lower),
                                          ("step-3", revision + 1, higher)):
        directory = output / "feeds" / name / "acceptance" / acceptance_id
        directory.mkdir(parents=True)
        (directory / "stable.json").write_text(acceptance_feed(
            "stable", stable_revision, generated_at, feed_release(stable, generated_at),
        ), encoding="utf-8")
        (directory / "beta.json").write_text(beta_feed, encoding="utf-8")
        steps.append({
            "name": name, "directory": str(directory),
            "stable": {"revision": stable_revision, "tag": stable["tag"]},
            "beta": {"revision": revision, "tag": beta["tag"]},
        })
    return steps


def write_build_info(output: Path, info: dict) -> None:
    (output / "BUILD-INFO.json").write_text(json.dumps(
        info, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def main(argv: list | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--id", required=True, dest="acceptance_id",
                        help="acceptance ID shared by every package; the feeds live at "
                             "acceptance/<ID>/<channel>.json")
    parser.add_argument("--lower-version", required=True,
                        help="X.Y.Z of the starting stable package A")
    parser.add_argument("--higher-version", required=True,
                        help="X.Y.Z of the target: stable B, or with --beta beta B "
                             "(vX.Y.Z-beta.1) and stable C")
    parser.add_argument("--output", required=True, type=Path,
                        help="new directory for the packages, BUILD-INFO.json and feeds")
    parser.add_argument("--notary-profile", required=True,
                        help="notarytool keychain profile")
    parser.add_argument("--beta", action="store_true",
                        help="build stable A, beta B and stable C in a clean temporary worktree "
                             "of HEAD, and write the acceptance feeds for each step")
    parser.add_argument("--lower-ref", metavar="REF",
                        help="build A from this git ref (for example the current stable tag) and "
                             "the higher packages from HEAD, each in a clean temporary worktree")
    args = parser.parse_args(argv)
    if not ACCEPTANCE_ID.fullmatch(args.acceptance_id):
        parser.error("invalid acceptance ID")
    versions = [args.lower_version, args.higher_version]
    if not all(VERSION.fullmatch(version) for version in versions):
        parser.error("both versions must be canonical MAJOR.MINOR.PATCH")
    if tuple(map(int, versions[0].split("."))) >= tuple(map(int, versions[1].split("."))):
        parser.error("the target version must be newer than the starting version")
    output = args.output.expanduser().resolve()
    if output.exists():
        parser.error("output directory already exists; choose a new acceptance run")
    if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip():
        parser.error("commit the accepted source changes before building the packages")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    environment = dict(os.environ, NOTARY_KEYCHAIN_PROFILE=args.notary_profile)
    lower_commit = None
    if args.lower_ref is not None:
        lower_commit = resolve_commit(args.lower_ref)
        if lower_commit is None:
            parser.error(f"--lower-ref {args.lower_ref} does not name a commit; fetch it first")
        missing = [name for name in LOWER_REF_VARIABLES
                   if name not in makefile_variables(lower_commit)]
        if missing:
            parser.error(f"--lower-ref {args.lower_ref} predates acceptance builds: its Makefile "
                         f"has no {', '.join(missing)}")
        if args.beta and not has_beta_switch(lower_commit):
            parser.error(f"--lower-ref {args.lower_ref} has no beta switch ({BETA_SWITCH_KEY}), so "
                         "step 1 cannot run; pick the first stable tag with the client beta "
                         "channel, or test this ref without --beta")
    extended = args.beta or args.lower_ref is not None
    # B's beta contract rejects private configuration, and a lower ref's A must
    # not differ from the higher packages in it, so these sets carry none.
    if extended:
        commits = [commit] if lower_commit is None else [commit, lower_commit]
        found = private_configuration(commits, environment)
        if found:
            parser.error("--beta and --lower-ref build every package without private "
                         f"configuration, which this build would embed: {', '.join(found)}; "
                         f"unset the variables and remove tracked {PRIVATE_CONFIGURATION_PATH} "
                         "files first")
    output.mkdir(parents=True)
    build_number = int(time.time())
    with contextlib.ExitStack() as stack:
        stack.enter_context(exit_on_termination())
        higher = Source("HEAD", commit, ROOT, makefile_variables(commit))
        if extended:
            scratch = Path(tempfile.mkdtemp(prefix="xdial-acceptance-"))
            stack.callback(remove_directory, scratch)
            # Only tracked files: the ignored macos/PrivateConfig stays behind.
            higher = dataclasses.replace(higher, directory=stack.enter_context(
                temporary_worktree(commit, scratch / "head")))
        lower = higher
        if lower_commit is not None:
            lower = Source(args.lower_ref, lower_commit, stack.enter_context(
                temporary_worktree(lower_commit, scratch / "lower")),
                makefile_variables(lower_commit))
        packages = plan_packages(args.lower_version, args.higher_version, args.beta,
                                 build_number, lower, higher)
        records = []
        info = {"sourceCommit": commit, "acceptanceID": args.acceptance_id}
        for package in packages:
            records.append(build_package(package, args.acceptance_id, output, environment,
                                         extended))
            write_build_info(output, dict(
                info, createdAt=dt.datetime.now(dt.timezone.utc).isoformat(), packages=records,
                installed=False, launched=False, uploaded=False,
            ))
    if args.beta:
        steps = write_acceptance_feeds(output, args.acceptance_id, records,
                                       dt.datetime.now(dt.timezone.utc))
        write_build_info(output, dict(
            info, createdAt=dt.datetime.now(dt.timezone.utc).isoformat(), packages=records,
            feeds=steps, installed=False, launched=False, uploaded=False,
        ))
        print(f"Acceptance set ready: {output}", flush=True)
        return
    print(f"Acceptance pair ready: {output}", flush=True)


if __name__ == "__main__":
    main()
