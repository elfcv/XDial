#!/usr/bin/env bash

# Debug is built from whichever work branch is being verified, so installing
# from a branch that lacks commits the installed Debug already carries would
# silently drop them. This read-only check compares the installed bundle's
# XDialSourceRevision with HEAD of the current repository and stops before
# such an install. The revision is HEAD at build time: uncommitted changes in
# the installed build are not recorded and cannot be detected here.

set -euo pipefail

installed_bundle="${XDIAL_DEBUG_APP_PATH:-/Applications/XDial Debug.app}"
info_plist="${installed_bundle}/Contents/Info.plist"
override_hint="set ALLOW_DEBUG_ROLLBACK=1 to replace it anyway"

fail() {
	echo "✗ $*" >&2
	exit 1
}

if [[ ! -e "$installed_bundle" ]]; then
	echo "no Debug installed at ${installed_bundle}; nothing to roll back"
	exit 0
fi

if [[ "${ALLOW_DEBUG_ROLLBACK:-}" == 1 ]]; then
	echo "⚠ ALLOW_DEBUG_ROLLBACK=1: ${installed_bundle} may be replaced by a build that lacks some of its commits" >&2
	exit 0
fi

git rev-parse --verify --quiet HEAD >/dev/null \
	|| fail "rollback check must run inside a git work tree with a HEAD commit"

installed_revision="$(plutil -extract XDialSourceRevision raw -o - "$info_plist" 2>/dev/null || true)"
[[ -n "$installed_revision" ]] \
	|| fail "cannot read XDialSourceRevision from ${info_plist}; ${override_hint}"

# A non-hex value (the project default "unversioned", or a ref name) must not
# be resolved against this repository's refs.
[[ "$installed_revision" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] \
	|| fail "installed Debug records no source commit (${installed_revision}); ${override_hint}"

git cat-file -e "${installed_revision}^{commit}" 2>/dev/null \
	|| fail "installed Debug was built from ${installed_revision}, which this repository does not have; run git fetch, or ${override_hint}"

if git merge-base --is-ancestor "$installed_revision" HEAD; then
	echo "installed Debug ${installed_revision:0:12} is contained in HEAD"
	exit 0
fi

{
	echo "✗ installed Debug ${installed_revision:0:12} has commits that HEAD lacks; installing this build would drop:"
	git log --oneline "HEAD..${installed_revision}"
	echo "merge them into this branch first, or ${override_hint}"
} >&2
exit 1
