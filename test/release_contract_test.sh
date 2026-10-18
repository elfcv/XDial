#!/bin/bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
contract="$repository_root/scripts/release-contract.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/xdial-release-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

fail() {
    echo "release contract test failed: $*" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "command unexpectedly succeeded: $*"
    fi
}

# Also pins the reason, so a fixture cannot fail for an unrelated defect.
expect_failure_with() {
    local message="$1"
    shift
    local output
    if output="$("$@" 2>&1)"; then
        fail "command unexpectedly succeeded: $*"
    fi
    grep -Fq -- "$message" <<<"$output" \
        || fail "expected '$message' from: $*; got: $output"
}

"$contract" validate-inputs v0.7.0 98
"$contract" validate-inputs v12.34.56 1787300000
expect_failure "$contract" validate-inputs 0.7.0 98
expect_failure "$contract" validate-inputs v0.7 98
expect_failure "$contract" validate-inputs v01.7.0 98
expect_failure "$contract" validate-inputs v0.7.0-rc.1 98
expect_failure "$contract" validate-inputs next-v0.7.0 98
expect_failure "$contract" validate-inputs v0.7.0 0
expect_failure "$contract" validate-inputs v0.7.0 build-98

check_debug_entitlement() (
    source "$contract"
    assert_get_task_allow_absent_in_plist fixture "$1"
)

entitlement_plist_prefix='<?xml version="1.0"?><plist version="1.0"><dict>'
entitlement_plist_suffix='</dict></plist>'
debug_entitlement='<key>com.apple.security.get-task-allow</key>'
expect_failure check_debug_entitlement \
    "$entitlement_plist_prefix$debug_entitlement<true/>$entitlement_plist_suffix"
check_debug_entitlement \
    "$entitlement_plist_prefix$debug_entitlement<false/>$entitlement_plist_suffix"
check_debug_entitlement "$entitlement_plist_prefix$entitlement_plist_suffix"
check_debug_entitlement ''
expect_failure check_debug_entitlement 'invalid plist'

check_hardened_signature_details() (
    source "$contract"
    assert_hardened_signature_details fixture "$1"
)

# Shape of a notarized Developer ID signature as printed by codesign -dvvv.
hardened_details='Identifier=com.kafeifei.xdial.app
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=29092 flags=0x10000(runtime) hashes=898+7 location=embedded
Authority=Developer ID Application: XDial Fixture (UVZM439VGU)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Timestamp=Oct 11, 2026 at 23:06:00
TeamIdentifier=UVZM439VGU
Runtime Version=26.0.0'
check_hardened_signature_details "$hardened_details"
check_hardened_signature_details \
    "${hardened_details/0x10000(runtime)/0x12000(library-validation,runtime)}"
expect_failure_with 'not signed with the hardened runtime' \
    check_hardened_signature_details "${hardened_details/0x10000(runtime)/0x0(none)}"
expect_failure_with 'not signed with the hardened runtime' \
    check_hardened_signature_details \
    "${hardened_details/0x10000(runtime)/0x10000(runtime-disabled)}"
expect_failure_with 'no secure signing timestamp' \
    check_hardened_signature_details "${hardened_details/Timestamp=/Signed Time=}"
expect_failure check_hardened_signature_details ''

distribution_root="$test_root/distribution"
mkdir -p "$distribution_root/go-helper"
printf '%s\n' '#include <stdio.h>' \
    'int main(void) { puts("XDial fixture"); return 0; }' \
    >"$distribution_root/host.c"
printf '%s\n' '#include <stdio.h>' \
    'int main(void) { puts("DebugServer: ready on localhost:19877"); return 0; }' \
    >"$distribution_root/debug-host.c"
/usr/bin/xcrun clang -mmacosx-version-min=15.0 "$distribution_root/host.c" \
    -o "$distribution_root/host"
/usr/bin/xcrun clang -mmacosx-version-min=15.0 "$distribution_root/debug-host.c" \
    -o "$distribution_root/debug-host"
printf '%s\n' 'module example.invalid/helper' '' 'go 1.21' \
    >"$distribution_root/go-helper/go.mod"
cat >"$distribution_root/go-helper/main.go" <<'EOF'
package main

import (
	"fmt"
	"os"
)

var version = "dev"
var buildFlavor string

// Mirrors cmd/xdial's versionLine.
func main() {
	if len(os.Args) == 2 && os.Args[1] == "version" {
		line := "xdial " + version
		if buildFlavor != "" {
			line += " (buildFlavor=" + buildFlavor + ")"
		}
		fmt.Println(line)
	}
}
EOF
build_fixture_helper() {
    local output="$1"
    shift
    (
        cd "$distribution_root/go-helper"
        GOWORK=off GOFLAGS= go build -buildvcs=false "$@" -o "$output" .
    )
}
build_fixture_helper "$distribution_root/helper" -ldflags '-X main.version=v0.7.0'
build_fixture_helper "$distribution_root/flavored-helper" \
    -ldflags '-X main.version=v0.7.0 -X main.buildFlavor=x'
build_fixture_helper "$distribution_root/trimmed-flavored-helper" -trimpath \
    -ldflags '-X main.version=v0.7.0 -X main.buildFlavor=x'
debug_entitlements="$distribution_root/debug.entitlements"
printf '%s\n' "$entitlement_plist_prefix$debug_entitlement<true/>$entitlement_plist_suffix" \
    >"$debug_entitlements"

write_bundle_info() {
    local bundle="$1" executable="$2" identifier="$3"
    mkdir -p "$bundle/Contents/MacOS"
    cat >"$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$executable</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleShortVersionString</key><string>0.7.0</string>
<key>CFBundleVersion</key><string>98</string>
<key>NSLocationUsageDescription</key><string>fixture</string>
</dict></plist>
EOF
}

distribution_app="$distribution_root/clean/XDial.app"
distribution_settings="$distribution_app/Contents/Helpers/XDial Settings UI.app"
distribution_extension_name=com.kafeifei.xdial.app.transparent-proxy
distribution_extension="$distribution_app/Contents/Library/SystemExtensions/$distribution_extension_name.systemextension"
write_bundle_info "$distribution_app" XDial com.kafeifei.xdial.app
write_bundle_info "$distribution_settings" 'XDial Settings UI' \
    com.kafeifei.xdial.app.settings-ui
write_bundle_info "$distribution_extension" "$distribution_extension_name" \
    "$distribution_extension_name"
cp "$distribution_root/host" "$distribution_app/Contents/MacOS/XDial"
cp "$distribution_root/host" "$distribution_settings/Contents/MacOS/XDial Settings UI"
cp "$distribution_root/host" \
    "$distribution_extension/Contents/MacOS/$distribution_extension_name"
cp "$distribution_root/helper" "$distribution_app/Contents/MacOS/xdial-daemon"

# Ad-hoc signs inside-out; the component named by $2 gets get-task-allow.
sign_distribution_fixture() {
    local app="$1" debuggable="${2:-}"
    local settings="$app/Contents/Helpers/XDial Settings UI.app"
    local extension="$app/Contents/Library/SystemExtensions/$distribution_extension_name.systemextension"
    local name path arguments
    for name in helper settings extension app; do
        case "$name" in
            helper) path="$app/Contents/MacOS/xdial-daemon" ;;
            settings) path="$settings" ;;
            extension) path="$extension" ;;
            app) path="$app" ;;
        esac
        arguments=(-f -s -)
        if [[ "$name" == "$debuggable" ]]; then
            arguments+=(--entitlements "$debug_entitlements")
        fi
        /usr/bin/codesign "${arguments[@]}" "$path" 2>/dev/null
    done
}

distribution_variant() {
    local name="$1"
    local variant="$distribution_root/variants/$name/XDial.app"
    mkdir -p "$distribution_root/variants/$name"
    /usr/bin/ditto "$distribution_app" "$variant"
    printf '%s\n' "$variant"
}

hardened_record="$distribution_root/hardened-components"
# Everything that needs Developer ID signing or provisioning is stubbed, so
# verify-app exercises the real distribution checks on an ad-hoc bundle.
verify_distribution_fixture() (
    source "$contract"
    assert_app_deployment_target() { :; }
    assert_component_names() { :; }
    assert_developer_id_signature() { :; }
    assert_system_extension_authorization() { :; }
    assert_location_entitlement() { :; }
    # Ad-hoc signatures cannot carry a secure timestamp.
    assert_hardened_signature() { printf '%s\n' "$1" >>"$hardened_record"; }
    verify_app "$1" v0.7.0 98
)

sign_distribution_fixture "$distribution_app"
rm -f "$hardened_record"
if ! clean_output="$(verify_distribution_fixture "$distribution_app" 2>&1)"; then
    fail "verify-app rejected a clean distribution fixture: $clean_output"
fi
[[ "$(cat "$hardened_record")" == "$(printf '%s\n' "$distribution_app" \
    "$distribution_settings" "$distribution_extension" \
    "$distribution_app/Contents/MacOS/xdial-daemon")" ]] \
    || fail "verify-app did not check the signature of every distribution component"

for component in app settings extension helper; do
    variant="$(distribution_variant "debuggable-$component")"
    sign_distribution_fixture "$variant" "$component"
    expect_failure_with 'forbidden get-task-allow entitlement' \
        verify_distribution_fixture "$variant"
done

variant="$(distribution_variant debug-server)"
cp "$distribution_root/debug-host" "$variant/Contents/MacOS/XDial"
sign_distribution_fixture "$variant"
expect_failure_with 'contains the development DebugServer' \
    verify_distribution_fixture "$variant"

# The Debug configuration's layout: a clean stub executable, with the host's
# code in a debug dylib beside it.
variant="$(distribution_variant debug-dylib)"
cp "$distribution_root/debug-host" "$variant/Contents/MacOS/XDial.debug.dylib"
/usr/bin/codesign -f -s - "$variant/Contents/MacOS/XDial.debug.dylib" 2>/dev/null
sign_distribution_fixture "$variant"
expect_failure_with 'XDial.debug.dylib contains the development DebugServer' \
    verify_distribution_fixture "$variant"

variant="$(distribution_variant flavored-helper)"
cp "$distribution_root/flavored-helper" "$variant/Contents/MacOS/xdial-daemon"
sign_distribution_fixture "$variant"
expect_failure_with 'main.buildFlavor override' \
    verify_distribution_fixture "$variant"

# -trimpath drops -ldflags from the build information, so only the helper's
# version line reveals this flavor.
variant="$(distribution_variant trimmed-flavored-helper)"
cp "$distribution_root/trimmed-flavored-helper" "$variant/Contents/MacOS/xdial-daemon"
sign_distribution_fixture "$variant"
expect_failure_with "bundled helper reports 'xdial v0.7.0 (buildFlavor=x)'" \
    verify_distribution_fixture "$variant"

# The helper must be a Go executable whose build information is readable.
variant="$(distribution_variant native-helper)"
cp "$distribution_root/host" "$variant/Contents/MacOS/xdial-daemon"
sign_distribution_fixture "$variant"
expect_failure_with 'cannot read Go build information' \
    verify_distribution_fixture "$variant"

check_hardened_signature() (
    source "$contract"
    assert_hardened_signature "$1"
)

# Real codesign output: an ad-hoc signature never has a secure timestamp, and
# the hardened runtime flag is parsed from the CodeDirectory line.
cp "$distribution_root/host" "$distribution_root/plain-signed"
/usr/bin/codesign -s - "$distribution_root/plain-signed" 2>/dev/null
expect_failure_with 'not signed with the hardened runtime' \
    check_hardened_signature "$distribution_root/plain-signed"
cp "$distribution_root/host" "$distribution_root/runtime-signed"
/usr/bin/codesign -s - -o runtime "$distribution_root/runtime-signed" 2>/dev/null
expect_failure_with 'no secure signing timestamp' \
    check_hardened_signature "$distribution_root/runtime-signed"
expect_failure check_hardened_signature "$distribution_root/missing"

check_deployment_target() (
    source "$contract"
    assert_app_deployment_target "$1"
)

deployment_fixture="$test_root/DeploymentFixture.app"
mkdir -p "$deployment_fixture/Contents/MacOS"
cat >"$deployment_fixture/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DeploymentFixture</string>
<key>CFBundleIdentifier</key><string>com.kafeifei.xdial.deployment-fixture</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
EOF
printf '%s\n' 'int main(void) { return 0; }' >"$test_root/deployment-fixture.c"
/usr/bin/xcrun clang -mmacosx-version-min=15.0 \
    "$test_root/deployment-fixture.c" \
    -o "$deployment_fixture/Contents/MacOS/DeploymentFixture"
/usr/bin/xcrun clang -mmacosx-version-min=15.0 \
    "$test_root/deployment-fixture.c" \
    -o "$deployment_fixture/Contents/MacOS/xdial-daemon"
check_deployment_target "$deployment_fixture"

# Older Mach-O files use LC_VERSION_MIN_MACOSX instead of LC_BUILD_VERSION.
/usr/bin/vtool -set-version-min macos 15.0 26.5 -replace \
    -output "$test_root/legacy-helper" \
    "$deployment_fixture/Contents/MacOS/xdial-daemon"
mv "$test_root/legacy-helper" \
    "$deployment_fixture/Contents/MacOS/xdial-daemon"
check_deployment_target "$deployment_fixture"

# Every architecture in a universal executable must target macOS.
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=15.0 \
    "$test_root/deployment-fixture.c" -o "$test_root/helper-arm64-15"
/usr/bin/xcrun clang -arch x86_64 -mmacosx-version-min=26.0 \
    "$test_root/deployment-fixture.c" -o "$test_root/helper-x86_64-26"
/usr/bin/lipo -create "$test_root/helper-arm64-15" \
    "$test_root/helper-x86_64-26" \
    -output "$deployment_fixture/Contents/MacOS/xdial-daemon"
expect_failure check_deployment_target "$deployment_fixture"

/usr/bin/vtool -set-build-version iossim 26.0 26.5 -replace \
    -output "$test_root/helper-x86_64-iossim" \
    "$test_root/helper-x86_64-26"
/usr/bin/lipo -create "$test_root/helper-arm64-15" \
    "$test_root/helper-x86_64-iossim" \
    -output "$deployment_fixture/Contents/MacOS/xdial-daemon"
expect_failure check_deployment_target "$deployment_fixture"

# A valid first slice must not hide a second slice with no deployment command.
/usr/bin/vtool -remove-build-version macos \
    -output "$test_root/helper-x86_64-no-deployment" \
    "$test_root/helper-x86_64-26"
/usr/bin/lipo -create "$test_root/helper-arm64-15" \
    "$test_root/helper-x86_64-no-deployment" \
    -output "$deployment_fixture/Contents/MacOS/xdial-daemon"
expect_failure check_deployment_target "$deployment_fixture"

/usr/bin/xcrun clang -mmacosx-version-min=26.0 \
    "$test_root/deployment-fixture.c" \
    -o "$deployment_fixture/Contents/MacOS/xdial-daemon"
expect_failure check_deployment_target "$deployment_fixture"

check_system_extension_authorization() (
    source "$contract"
    assert_system_extension_authorization_plists "$1" "$2" "$3" 1800000000
)

for identifier in com.kafeifei.xdial.app com.kafeifei.xdial.app.transparent-proxy; do
    authorization_dictionary="<dict>
<key>com.apple.application-identifier</key><string>UVZM439VGU.$identifier</string>
<key>com.apple.developer.team-identifier</key><string>UVZM439VGU</string>
<key>com.apple.developer.networking.networkextension</key>
<array><string>app-proxy-provider-systemextension</string></array>
<key>com.apple.developer.system-extension.install</key><true/>
</dict>"
    signed="<plist version=\"1.0\">$authorization_dictionary</plist>"
    profile="<plist version=\"1.0\"><dict>
<key>TeamIdentifier</key><array><string>UVZM439VGU</string></array>
<key>ProvisionsAllDevices</key><true/>
<key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
<key>ExpirationDate</key><date>2044-01-01T00:00:00Z</date>
<key>Entitlements</key>$authorization_dictionary
</dict></plist>"
    check_system_extension_authorization "$identifier" "$signed" "$profile"
    expect_failure check_system_extension_authorization "$identifier" '' "$profile"
    expect_failure check_system_extension_authorization "$identifier" "$signed" ''
    expect_failure check_system_extension_authorization "$identifier" "$signed" 'invalid plist'
    expect_failure check_system_extension_authorization "$identifier" \
        "${signed/UVZM439VGU.$identifier/UVZM439VGU.wrong}" "$profile"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/UVZM439VGU.$identifier/UVZM439VGU.wrong}"
    expect_failure check_system_extension_authorization "$identifier" \
        "${signed/<string>UVZM439VGU<\//<string>WRONGTEAM<\/}" "$profile"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/<string>UVZM439VGU<\//<string>WRONGTEAM<\/}"
    expect_failure check_system_extension_authorization "$identifier" \
        "${signed/app-proxy-provider-systemextension/app-proxy-provider}" "$profile"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/app-proxy-provider-systemextension/app-proxy-provider}"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/2044-01-01/2000-01-01}"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/2026-01-01/2040-01-01}"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/CreationDate/MissingCreationDate}"
    expect_failure check_system_extension_authorization "$identifier" "$signed" \
        "${profile/ProvisionsAllDevices/MissingProvisionsAllDevices}"
    if [[ "$identifier" == com.kafeifei.xdial.app ]]; then
        expect_failure check_system_extension_authorization "$identifier" \
            "${signed/system-extension.install/missing.install}" "$profile"
        expect_failure check_system_extension_authorization "$identifier" "$signed" \
            "${profile/system-extension.install/missing.install}"
        expect_failure check_system_extension_authorization "$identifier" \
            "${signed/<true\//<false\/}" "$profile"
    fi
done

notes="$test_root/RELEASE_NOTES.md"
printf '%s\n' \
    '# XDial v0.7.0' \
    '' \
    '## 更新了什么' \
    '' \
    '- 新增应用内更新。' >"$notes"
"$contract" validate-notes v0.7.0 "$notes"
expect_failure "$contract" validate-notes v0.8.0 "$notes"
printf '%s\n' '# XDial v0.7.0' '' '## 更新了什么' >"$notes"
expect_failure "$contract" validate-notes v0.7.0 "$notes"

git_fixture="$test_root/git-fixture"
mkdir -p "$git_fixture"
(
    cd "$git_fixture"
    git init -q -b main
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' fixture >tracked.txt
    git add tracked.txt
    git commit -qm fixture
    git tag v1.2.3
    expect_failure "$contract" assert-git-tag v1.2.3
    git update-ref refs/remotes/origin/main HEAD
    "$contract" assert-git-tag v1.2.3
    printf '%s\n' dirty >>tracked.txt
    expect_failure "$contract" assert-git-tag v1.2.3
    git restore tracked.txt

    git switch -qc feature
    printf '%s\n' feature >feature.txt
    git add feature.txt
    git commit -qm feature
    git tag v1.2.4
    expect_failure "$contract" assert-git-tag v1.2.4
    git switch -q main
    git merge --no-ff -qm 'merge feature' feature
    git update-ref refs/remotes/origin/main HEAD
    git tag v1.2.5
    "$contract" assert-git-tag v1.2.5
    git switch -q --detach v1.2.4
    expect_failure "$contract" assert-git-tag v1.2.4

    git switch -q main
    printf '%s\n' later >later.txt
    git add later.txt
    git commit -qm later
    git update-ref refs/remotes/origin/main HEAD
    git switch -q --detach v1.2.5
    "$contract" assert-git-tag v1.2.5
)

# origin is a local bare repository, so release-inputs never fetches over the
# network.
release_source="$test_root/release-source.git"
release_work="$test_root/release-work"
git init -q --bare "$release_source"
git init -q -b main "$release_work"
(
    cd "$release_work"
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' source >tracked.txt
    git add tracked.txt
    git commit -qm source
    git remote add origin "$release_source"
    git push -qu origin main
    git tag v2.3.4
    git update-ref -d refs/remotes/origin/main
    release_notes="$test_root/release-input-notes.md"

    # Notes for another version fail before origin/main is fetched, and an
    # acceptance build does not skip them.
    printf '%s\n' '# XDial v2.3.3' '' '## 更新了什么' '' '- 门禁测试。' \
        >"$release_notes"
    expect_failure make -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT="$contract" RELEASE_TAG=v2.3.4 \
        RELEASE_BUILD_NUMBER=234 RELEASE_NOTES_FILE="$release_notes"
    expect_failure make -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT="$contract" RELEASE_TAG=v2.3.4 \
        RELEASE_BUILD_NUMBER=234 RELEASE_NOTES_FILE="$release_notes" \
        RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture
    if git rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
        fail "release-inputs fetched origin/main before validating the notes"
    fi

    # Valid inputs refresh origin/main before the tag is checked against it.
    printf '%s\n' '# XDial v2.3.4' '' '## 更新了什么' '' '- 门禁测试。' \
        >"$release_notes"
    make -s --no-print-directory -f "$repository_root/Makefile" release-inputs \
        RELEASE_CONTRACT="$contract" RELEASE_TAG=v2.3.4 RELEASE_BUILD_NUMBER=234 \
        RELEASE_NOTES_FILE="$release_notes"
    [[ "$(git rev-parse refs/remotes/origin/main)" == "$(git rev-parse HEAD)" ]] \
        || fail "release-inputs did not refresh origin/main"

    # A failed refresh must not fall through to a stale, otherwise valid ref.
    git remote remove origin
    git update-ref refs/remotes/origin/main HEAD
    expect_failure make -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT="$contract" RELEASE_TAG=v2.3.4 \
        RELEASE_BUILD_NUMBER=234 RELEASE_NOTES_FILE="$release_notes"

    # Explicit formal-identity acceptance builds have synthetic versions and no
    # stable tag. They alone may bypass the stable tag/main check, and publish
    # refuses them before the stable publisher runs. This fixture has no
    # scripts/publish-release.py, so a broken guard still cannot publish.
    git tag -d v2.3.4 >/dev/null
    printf '%s\n' '# XDial v9.9.9' '' '## 更新了什么' '' '- 验收包。' \
        >"$release_notes"
    make -s --no-print-directory -f "$repository_root/Makefile" release-inputs \
        RELEASE_CONTRACT="$contract" RELEASE_TAG=v9.9.9 RELEASE_BUILD_NUMBER=999 \
        RELEASE_NOTES_FILE="$release_notes" \
        RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture
    if publish_output="$(make -s --no-print-directory -f "$repository_root/Makefile" \
        publish RELEASE_TAG=v9.9.9 RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture 2>&1)"; then
        fail "an acceptance build reached the stable publisher"
    fi
    grep -Fq 'an acceptance build cannot be published to stable' <<<"$publish_output" \
        || fail "publish did not refuse the acceptance build before running"
)

# Go stamps vcs.modified from git status when it compiles the helper, and the
# icon targets rewrite tracked .icns files, so release-app must compile the
# helper first. A fresh BUILD_DIR makes every icon rule part of the plan.
release_plan_build="$test_root/release-plan-build"
release_plan="$(make -n --no-print-directory -C "$repository_root" release-app \
    BUILD_DIR="$release_plan_build" RELEASE_TAG=v0.7.0 RELEASE_BUILD_NUMBER=98)"
helper_step="$(grep -n -F -- "-o $release_plan_build/xdial ./cmd/xdial/" \
    <<<"$release_plan" | head -n 1 | cut -d: -f1)"
icon_step="$(grep -n -F 'iconutil -c icns' <<<"$release_plan" | head -n 1 | cut -d: -f1)"
[[ -n "$helper_step" && -n "$icon_step" ]] \
    || fail "release-app plan has no helper or icon step"
[[ "$helper_step" -lt "$icon_step" ]] \
    || fail "release-app regenerates tracked icons before compiling the helper"

# verify-release-helper-source.sh runs only in the official release workflow.
helper_source="$repository_root/scripts/verify-release-helper-source.sh"
source_repository="$test_root/helper-source"
source_app="$test_root/helper-source-app/XDial.app"
mkdir -p "$source_repository" "$source_app/Contents/MacOS"
cp "$distribution_root/go-helper/go.mod" "$distribution_root/go-helper/main.go" \
    "$source_repository/"
(
    cd "$source_repository"
    git init -q -b main
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    git add go.mod main.go
    git commit -qm source
    git tag v3.4.5

    build_stamped_helper() {
        GOWORK=off GOFLAGS= go build -trimpath "$@" \
            -o "$source_app/Contents/MacOS/xdial-daemon" .
    }

    build_stamped_helper
    "$helper_source" "$source_app" v3.4.5 >/dev/null
    expect_failure_with 'release tag does not exist' \
        "$helper_source" "$source_app" v3.4.6
    expect_failure "$helper_source" "$test_root/helper-source-app/Missing.app" v3.4.5

    printf '%s\n' '// local edit' >>main.go
    build_stamped_helper
    expect_failure_with 'uncommitted changes' "$helper_source" "$source_app" v3.4.5
    git commit -qam later
    build_stamped_helper
    expect_failure_with "not v3.4.5" "$helper_source" "$source_app" v3.4.5

    git switch -q --detach v3.4.5
    build_stamped_helper -buildvcs=false
    expect_failure_with 'no Git build stamp' "$helper_source" "$source_app" v3.4.5
)

fixture_root="$test_root/archive-fixture"
fixture_app="$fixture_root/XDial.app"
mkdir -p "$fixture_app/Contents"
printf '%s\n' fixture >"$fixture_app/Contents/payload"
output_root="$test_root/output"
archive_path="$output_root/XDial-v0.7.0.zip"
"$contract" archive "$fixture_app" v0.7.0 "$output_root" >/dev/null
[[ -f "$archive_path" ]] || fail "archive was not created"
[[ -f "$archive_path.sha256" ]] || fail "checksum was not created"
"$contract" verify-archive-shape "$archive_path"
"$contract" verify-checksum "$archive_path" "$archive_path.sha256"

ln -s "$fixture_app" "$fixture_root/Symlink.app"
expect_failure "$contract" archive "$fixture_root/Symlink.app" v0.7.0 "$output_root"

tampered_root="$test_root/tampered"
mkdir -p "$tampered_root"
/usr/bin/ditto "$fixture_app" "$tampered_root/XDial.app"
printf '%s\n' extra >"$tampered_root/extra.txt"
(
    cd "$tampered_root"
    /usr/bin/zip -qry "$test_root/tampered.zip" XDial.app extra.txt
)
expect_failure "$contract" verify-archive-shape "$test_root/tampered.zip"

other_root="$test_root/other-root"
mkdir -p "$other_root"
/usr/bin/ditto "$fixture_app" "$other_root/Other.app"
/usr/bin/ditto -c -k --keepParent "$other_root/Other.app" "$test_root/other-root.zip"
expect_failure "$contract" verify-archive-shape "$test_root/other-root.zip"

printf '%s\n' tampered >>"$archive_path"
expect_failure "$contract" verify-checksum "$archive_path" "$archive_path.sha256"

echo "release contract tests passed"
