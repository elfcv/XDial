#!/usr/bin/env bash

# Beta shares the formal identity, configuration library, App Group and helper
# with stable. Persistent formats, cross-process protocols and dependency
# versions therefore evolve only through main: relative to where it last
# merged main, a beta commit may not change the files below. CI runs this on
# xdial-beta, release.yml before it builds a beta tag, and publish-release.py
# against the remote tag before a beta becomes public; the last one uses the
# operator's checkout, so xdial-beta cannot shorten the list it is held to.
#
# Usage: check-beta-shared-formats.sh [<main-ref> [<beta-ref>]]
#        (default origin/main and HEAD; the caller fetches main)
#        check-beta-shared-formats.sh --paths

set -euo pipefail

shared_paths=(
	# Dependency versions, and the local patches prepare-patched-go-mod.sh
	# applies to sing-box, tailscale and sslcon.
	go.mod
	go.sum
	third_party
	patches
	scripts/prepare-patched-go-mod.sh
	# Configuration library (profiles.enc) model, schema, storage and migration.
	macos/Sources/XDial/Models.swift
	macos/Sources/XDial/ProfileLibrary.swift
	macos/Sources/XDial/ProfileLibraryStore.swift
	macos/Sources/XDial/ProfileLibraryMigration.swift
	macos/Sources/XDial/GlobalConfiguration.swift
	macos/Sources/XDial/ConfigurationStorage.swift
	macos/Shared/JSONValue.swift
	# The core's Profile model and the portable Profile document.
	core/config/model.go
	core/config/profile_document.go
	# This list itself changes only through main.
	scripts/check-beta-shared-formats.sh
)

fail() {
	echo "error: $*" >&2
	exit 1
}

if [[ "${1:-}" == --paths ]]; then
	[[ $# -eq 1 ]] || fail "--paths takes no arguments"
	printf '%s\n' "${shared_paths[@]}"
	exit 0
fi
[[ $# -le 2 ]] || fail "usage: check-beta-shared-formats.sh [<main-ref> [<beta-ref>]]"

main_ref="${1:-origin/main}"
beta_ref="${2:-HEAD}"
git rev-parse --verify --quiet "$main_ref^{commit}" >/dev/null \
	|| fail "cannot resolve $main_ref; fetch main before checking a beta"
git rev-parse --verify --quiet "$beta_ref^{commit}" >/dev/null \
	|| fail "cannot resolve $beta_ref"

# Three dots: only what the beta side changed since its merge base with main.
status=0
git diff --quiet "$main_ref...$beta_ref" -- "${shared_paths[@]}" || status=$?
case "$status" in
	0) echo "$beta_ref keeps main's shared formats" ;;
	1)
		echo "error: $beta_ref changes files whose formats evolve only through main:" >&2
		git --no-pager diff --stat "$main_ref...$beta_ref" -- "${shared_paths[@]}" >&2
		exit 1
		;;
	*) fail "cannot compare $beta_ref with $main_ref" ;;
esac
