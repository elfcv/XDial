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

# Older plutil (macOS 15) prints extraction errors on stdout, so its output
# counts only when it succeeds.
installed_revision="$(plutil -extract XDialSourceRevision raw -o - "$info_plist" 2>/dev/null)" \
	|| installed_revision=""
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

# Captured rather than streamed so git never starts a pager on a terminal.
# "=" marks a commit whose change HEAD already carries under another ID.
dropped="$(git --no-pager log --oneline --no-decorate --cherry-mark --right-only "HEAD...${installed_revision}")"
main_revision="$(git rev-parse --verify --quiet 'refs/remotes/origin/main^{commit}' || true)"
{
	echo "✗ installed Debug ${installed_revision:0:12} has commits that HEAD lacks; installing this build would drop:"
	echo "$dropped"
	if grep -q '^=' <<<"$dropped"; then
		echo "(= HEAD already has that change as an amended or rebased copy)"
	fi
	# Work branches carry one fix or feature and target main, so another
	# branch's commits are never the remedy; only main is.
	if [[ -n "$main_revision" ]] && git merge-base --is-ancestor "$installed_revision" "$main_revision"; then
		echo "they are all on origin/main: merge the latest main into this branch first"
	else
		containing="$(git --no-pager branch --all --no-color --contains "$installed_revision" --format='  %(refname:short)')"
		echo "they are not on origin/main: another branch's unmerged work, or an earlier version of this branch since amended or rebased"
		echo "branches containing ${installed_revision:0:12}:"
		echo "${containing:-  none}"
		echo "do not merge them into this work branch; confirm with the user that this Debug may be replaced, then ${override_hint}"
	fi
} >&2
exit 1
