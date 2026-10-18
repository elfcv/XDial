#!/bin/bash

set -euo pipefail

# Official release CI only: the shipped helper must come from the clean tagged
# commit. This is not part of release-contract.sh verify-app because preset
# configuration packages are not necessarily built from a clean tag checkout.
#
# Go records vcs.* from the enclosing Git root, and recognizes a root only
# where .git is a directory. In a linked worktree (.git is a file) it stamps the
# enclosing checkout's HEAD and status, or nothing, so run this from the same
# regular clone that built the helper.

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ $# -eq 2 ]] || {
    echo "Usage: verify-release-helper-source.sh <XDial.app> <tag>" >&2
    exit 2
}
app_path="$1"
tag="$2"
helper_path="$app_path/Contents/MacOS/xdial-daemon"

[[ -f "$helper_path" && ! -L "$helper_path" ]] \
    || fail "missing bundled helper: $helper_path"
tagged_commit="$(git rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null)" \
    || fail "release tag does not exist locally: $tag"
build_info="$(go version -m "$helper_path" 2>/dev/null)" \
    || fail "cannot read Go build information from $helper_path"

build_setting() {
    awk -F '\t' -v key="$1=" \
        '$2 == "build" && index($3, key) == 1 { print substr($3, length(key) + 1) }' \
        <<<"$build_info"
}

[[ "$(build_setting vcs)" == git ]] \
    || fail "helper has no Git build stamp; build it in a regular clone with VCS stamping enabled"
revision="$(build_setting vcs.revision)"
[[ "$revision" == "$tagged_commit" ]] \
    || fail "helper was built from '$revision', not $tag ($tagged_commit)"
[[ "$(build_setting vcs.modified)" == false ]] \
    || fail "helper was built from a worktree with uncommitted changes"
echo "helper source verified: $tag ($tagged_commit), clean"
