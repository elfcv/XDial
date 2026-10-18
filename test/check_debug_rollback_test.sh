#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
check="$repository_root/scripts/check-debug-rollback.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xdial-debug-rollback-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

# The fixture must not pick up the operator's git hooks, signing or log format.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_CEILING_DIRECTORIES="$test_root"

repository="$test_root/repository"
installed_app="$test_root/XDial Debug.app"
output="$test_root/output"

fail() {
    echo "debug rollback check test failed: $*" >&2
    exit 1
}

# run_check DIRECTORY [NAME=VALUE...]: run the check from DIRECTORY against
# the fixture bundle, ignoring any override set by the caller's environment.
run_check() {
    local directory="$1"
    shift
    (cd "$directory" && env -u ALLOW_DEBUG_ROLLBACK \
        XDIAL_DEBUG_APP_PATH="$installed_app" "$@" bash "$check") \
        >"$output" 2>&1
}

expect_output() {
    grep -qF -- "$1" "$output" || fail "output lacks \"$1\": $(cat "$output")"
}

expect_pass() {
    local expected="$1"
    shift
    run_check "$repository" "$@" || fail "check rejected: $(cat "$output")"
    expect_output "$expected"
}

expect_reject() {
    local expected="$1"
    shift
    if run_check "$repository" "$@"; then
        fail "check unexpectedly passed: $(cat "$output")"
    fi
    expect_output "$expected"
}

install_plist() {
    rm -rf "$installed_app"
    mkdir -p "$installed_app/Contents"
    cat >"$installed_app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.kafeifei.xdial.debug</string>
$1
</dict></plist>
EOF
}

install_revision() {
    install_plist "<key>XDialSourceRevision</key><string>$1</string>"
}

commit() {
    printf '%s\n' "$1" >>"$repository/history.txt"
    git -C "$repository" add history.txt
    git -C "$repository" commit -qm "$1"
    git -C "$repository" rev-parse HEAD
}

mkdir -p "$repository"
git -C "$repository" init -q -b main
git -C "$repository" config user.name 'XDial Test'
git -C "$repository" config user.email 'xdial-test@example.invalid'
commit 'base' >/dev/null
main_revision="$(commit 'main fix')"
git -C "$repository" switch -q -c installed-work
installed_revision="$(commit 'installed experiment')"
git -C "$repository" switch -q -c current-work main
current_revision="$(commit 'current fix')"

# Nothing installed: there is nothing to roll back.
rm -rf "$installed_app"
expect_pass 'nothing to roll back'

# The installed build is HEAD itself or one of its ancestors.
install_revision "$current_revision"
expect_pass 'is contained in HEAD'
install_revision "$main_revision"
expect_pass 'is contained in HEAD'
plutil -convert binary1 "$installed_app/Contents/Info.plist"
expect_pass 'is contained in HEAD'

# The installed build carries a sibling branch's commit: list only what the
# install would drop, and stop.
install_revision "$installed_revision"
expect_reject 'installed experiment'
expect_output "${installed_revision:0:7}"
if grep -qF 'current fix' "$output"; then
    fail "commits already in HEAD were listed: $(cat "$output")"
fi
expect_reject 'installed experiment' ALLOW_DEBUG_ROLLBACK=0
expect_pass 'ALLOW_DEBUG_ROLLBACK=1' ALLOW_DEBUG_ROLLBACK=1

# A main-only checkout must not overwrite a Debug built from a work branch.
git -C "$repository" switch -q main
install_revision "$current_revision"
expect_reject 'current fix'
git -C "$repository" switch -q current-work

# A revision that cannot be proven contained in HEAD is a hard stop.
install_revision unversioned
expect_reject 'records no source commit'
expect_pass 'ALLOW_DEBUG_ROLLBACK=1' ALLOW_DEBUG_ROLLBACK=1
install_revision HEAD
expect_reject 'records no source commit'
install_revision ''
expect_reject 'cannot read XDialSourceRevision'
install_plist ''
expect_reject 'cannot read XDialSourceRevision'
rm -f "$installed_app/Contents/Info.plist"
expect_reject 'cannot read XDialSourceRevision'
install_revision 0123456789abcdef0123456789abcdef01234567
expect_reject 'run git fetch'
install_revision "$(git -C "$repository" rev-parse 'HEAD^{tree}')"
expect_reject 'run git fetch'

# Outside a repository there is no HEAD to compare with.
install_revision "$current_revision"
mkdir -p "$test_root/outside"
if run_check "$test_root/outside"; then
    fail "check passed outside a repository: $(cat "$output")"
fi
expect_output 'inside a git work tree'

echo 'Debug rollback check verified'
