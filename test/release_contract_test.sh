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
expect_failure_with 'exact stable SemVer' "$contract" validate-inputs v1.4.0-beta.1 98

# Beta ships the same formal identity; the channel only picks the tag syntax
# and the branch the tag must be on.
beta_contract() {
    XDIAL_RELEASE_CHANNEL=beta "$contract" "$@"
}
beta_contract validate-inputs v1.4.0-beta.1 98
beta_contract validate-inputs v12.34.56-beta.789 1787300000
for tag in v1.4.0 v1.4.0-beta.0 v1.4.0-beta.01 v1.4.0-rc.1 v1.4.0-beta \
    v1.4.0-beta.1.2 v01.4.0-beta.1 1.4.0-beta.1; do
    expect_failure_with 'beta release tag must be exact' \
        beta_contract validate-inputs "$tag" 98
done
expect_failure beta_contract validate-inputs v1.4.0-beta.1 0
[[ "$("$contract" version-from-tag v1.4.0)" == 1.4.0 ]] \
    || fail "stable version-from-tag changed"
[[ "$(beta_contract version-from-tag v1.4.0-beta.1)" == 1.4.0 ]] \
    || fail "beta version-from-tag must drop -beta.N"
expect_failure "$contract" version-from-tag v1.4.0-beta.1
[[ "$("$contract" release-branch)" == main ]] || fail "stable must release from main"
[[ "$(beta_contract release-branch)" == xdial-beta ]] \
    || fail "beta must release from xdial-beta"
expect_failure_with 'unknown release channel' \
    env XDIAL_RELEASE_CHANNEL=next "$contract" release-branch

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

beta_output="$test_root/beta-output"
beta_contract archive "$fixture_app" v1.4.0-beta.1 "$beta_output" >/dev/null
[[ -f "$beta_output/XDial-v1.4.0-beta.1.zip" \
    && -f "$beta_output/XDial-v1.4.0-beta.1.zip.sha256" ]] \
    || fail "beta archive is not named XDial-v1.4.0-beta.1.zip"
beta_contract verify-archive-shape "$beta_output/XDial-v1.4.0-beta.1.zip"
beta_contract verify-checksum "$beta_output/XDial-v1.4.0-beta.1.zip" \
    "$beta_output/XDial-v1.4.0-beta.1.zip.sha256"
expect_failure "$contract" archive "$fixture_app" v1.4.0-beta.1 "$beta_output"
expect_failure beta_contract archive "$fixture_app" v1.4.0 "$beta_output"

beta_notes="$test_root/BETA_RELEASE_NOTES.md"
printf '%s\n' '# XDial v1.4.0-beta.1' '' '## 更新了什么' '' '- 实验功能。' >"$beta_notes"
beta_contract validate-notes v1.4.0-beta.1 "$beta_notes"
expect_failure beta_contract validate-notes v1.4.0-beta.2 "$beta_notes"
expect_failure "$contract" validate-notes v1.4.0-beta.1 "$beta_notes"

# A beta tag sits on origin/xdial-beta's first-parent history, contains the
# newest stable tag and sorts above it.
beta_git_fixture="$test_root/beta-git-fixture"
mkdir -p "$beta_git_fixture"
(
    cd "$beta_git_fixture"
    git init -q -b main
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' fixture >tracked.txt
    git add tracked.txt
    git commit -qm fixture
    git switch -qc xdial-beta
    printf '%s\n' experiment >experiment.txt
    git add experiment.txt
    git commit -qm experiment
    git tag v1.4.0-beta.1
    git update-ref refs/remotes/origin/xdial-beta HEAD
    expect_failure_with 'no stable vMAJOR.MINOR.PATCH tag' \
        beta_contract assert-git-tag v1.4.0-beta.1
    git tag v1.3.0 main
    beta_contract assert-git-tag v1.4.0-beta.1
    expect_failure "$contract" assert-git-tag v1.4.0-beta.1
    git tag v1.3.0-beta.9
    expect_failure_with 'must be newer than the latest stable tag v1.3.0' \
        beta_contract assert-git-tag v1.3.0-beta.9
    git tag -d v1.3.0-beta.9 >/dev/null
    git update-ref -d refs/remotes/origin/xdial-beta
    expect_failure_with 'fetch origin/xdial-beta' \
        beta_contract assert-git-tag v1.4.0-beta.1
    git update-ref refs/remotes/origin/main HEAD
    expect_failure beta_contract assert-git-tag v1.4.0-beta.1
    git update-ref -d refs/remotes/origin/main

    # A stable hotfix that xdial-beta has not merged yet.
    git switch -q main
    printf '%s\n' hotfix >hotfix.txt
    git add hotfix.txt
    git commit -qm hotfix
    git tag v1.3.1
    git switch -q xdial-beta
    printf '%s\n' more >>experiment.txt
    git commit -qam more
    git tag v1.4.0-beta.2
    git update-ref refs/remotes/origin/xdial-beta HEAD
    expect_failure_with 'must contain the latest stable tag v1.3.1' \
        beta_contract assert-git-tag v1.4.0-beta.2
    git merge --no-ff -qm 'merge main' main
    git tag v1.4.0-beta.3
    git update-ref refs/remotes/origin/xdial-beta HEAD
    beta_contract assert-git-tag v1.4.0-beta.3

    # A tag on a feature branch merged into xdial-beta is off its first parent.
    git switch -qc feature/experiment
    printf '%s\n' feature >feature.txt
    git add feature.txt
    git commit -qm feature
    git tag v1.4.0-beta.4
    git switch -q xdial-beta
    git merge --no-ff -qm 'merge feature' feature/experiment
    git update-ref refs/remotes/origin/xdial-beta HEAD
    git switch -q --detach v1.4.0-beta.4
    expect_failure_with "origin/xdial-beta's first-parent history" \
        beta_contract assert-git-tag v1.4.0-beta.4
)

# Offline, like the stable release-inputs fixture: origin is a local bare
# repository. Beta fetches xdial-beta and the v* tags, never main.
beta_source="$test_root/beta-source.git"
beta_work="$test_root/beta-work"
git init -q --bare "$beta_source"
git init -q -b main "$beta_work"
(
    cd "$beta_work"
    git config user.name 'XDial Test'
    git config user.email 'xdial-test@example.invalid'
    printf '%s\n' source >tracked.txt
    git add tracked.txt
    git commit -qm source
    git tag v2.3.4
    git remote add origin "$beta_source"
    git push -q origin main refs/tags/v2.3.4
    git switch -qc xdial-beta
    printf '%s\n' experiment >experiment.txt
    git add experiment.txt
    git commit -qm experiment
    git push -q origin xdial-beta
    git tag v2.4.0-beta.1
    git update-ref -d refs/remotes/origin/main
    git update-ref -d refs/remotes/origin/xdial-beta
    # The newest stable tag exists only on origin until release-inputs runs.
    git tag -d v2.3.4 >/dev/null
    beta_input_notes="$test_root/beta-input-notes.md"
    printf '%s\n' '# XDial v2.4.0-beta.1' '' '## 更新了什么' '' '- 门禁测试。' \
        >"$beta_input_notes"
    make -s --no-print-directory -f "$repository_root/Makefile" release-inputs \
        RELEASE_CONTRACT_SCRIPT="$contract" RELEASE_CHANNEL=beta \
        RELEASE_TAG=v2.4.0-beta.1 RELEASE_BUILD_NUMBER=240 \
        RELEASE_NOTES_FILE="$beta_input_notes"
    [[ "$(git rev-parse refs/remotes/origin/xdial-beta)" == "$(git rev-parse HEAD)" ]] \
        || fail "beta release-inputs did not refresh origin/xdial-beta"
    git rev-parse -q --verify refs/tags/v2.3.4 >/dev/null \
        || fail "beta release-inputs did not refresh the stable tags"
    if git rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
        fail "beta release-inputs fetched main"
    fi
    beta_input_plan="$(make -n -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT_SCRIPT="$contract" RELEASE_CHANNEL=beta \
        RELEASE_TAG=v2.4.0-beta.1 RELEASE_BUILD_NUMBER=240)"
    grep -Fq 'validate-notes "v2.4.0-beta.1" "BETA_RELEASE_NOTES.md"' <<<"$beta_input_plan" \
        || fail "beta release-inputs does not default to BETA_RELEASE_NOTES.md"

    # Acceptance builds (PR-6) skip the xdial-beta gate, and publish refuses them.
    printf '%s\n' '# XDial v9.9.9-beta.1' '' '## 更新了什么' '' '- 验收包。' \
        >"$beta_input_notes"
    acceptance_output="$(make -s --no-print-directory -f "$repository_root/Makefile" \
        release-inputs RELEASE_CONTRACT_SCRIPT="$contract" RELEASE_CHANNEL=beta \
        RELEASE_TAG=v9.9.9-beta.1 RELEASE_BUILD_NUMBER=999 \
        RELEASE_NOTES_FILE="$beta_input_notes" RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture)"
    grep -Fq 'beta tag/xdial-beta gate is intentionally skipped' <<<"$acceptance_output" \
        || fail "beta acceptance build did not skip the branch gate"
    expect_failure_with 'an acceptance build cannot be published to beta' \
        make -s --no-print-directory -f "$repository_root/Makefile" publish \
        RELEASE_CHANNEL=beta RELEASE_TAG=v9.9.9-beta.1 \
        RELEASE_UPDATE_ACCEPTANCE_ID=pages-fixture
)

# Both release-app builds get the version from the contract and the tag as
# XDialReleaseTag; every contract call carries the channel.
for channel_tag in stable:v1.4.0 beta:v1.4.0-beta.1; do
    plan_channel="${channel_tag%%:*}"
    plan_tag="${channel_tag#*:}"
    release_app_plan="$(make -n --no-print-directory -C "$repository_root" release-app \
        BUILD_DIR="$test_root/release-app-plan" RELEASE_CHANNEL="$plan_channel" \
        RELEASE_TAG="$plan_tag" RELEASE_BUILD_NUMBER=98)"
    [[ "$(grep -c -F 'MARKETING_VERSION="1.4.0"' <<<"$release_app_plan")" == 2 ]] \
        || fail "$plan_channel release-app does not build version 1.4.0 twice"
    [[ "$(grep -c -F "XDIAL_RELEASE_TAG=\"$plan_tag\"" <<<"$release_app_plan")" == 2 ]] \
        || fail "$plan_channel release-app does not pass XDialReleaseTag to both builds"
    grep -Fq "XDIAL_RELEASE_CHANNEL=$plan_channel scripts/release-contract.sh verify-app" \
        <<<"$release_app_plan" || fail "$plan_channel verify-app does not carry the channel"
done

# XDialReleaseTag is how clients recognize an installed beta: beta requires the
# exact tag, stable also accepts an empty key. Private configuration is
# refused only by beta here; official CI refuses it for both channels.
check_release_bundle() (
    XDIAL_RELEASE_CHANNEL="$1"
    source "$contract"
    assert_release_tag_key "$2" "$3" \
        "$3/Contents/Helpers/XDial Settings UI.app" \
        "$3/Contents/Library/SystemExtensions/com.kafeifei.xdial.app.transparent-proxy.systemextension"
    assert_private_configuration_absent "$3"
)

write_bundle_plist() {
    mkdir -p "$1/Contents"
    cat >"$1/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>1.4.0</string>
$2
</dict></plist>
EOF
}

release_bundle() {
    local app="$test_root/release-bundle/$1/XDial.app"
    write_bundle_plist "$app" "$2"
    write_bundle_plist "$app/Contents/Helpers/XDial Settings UI.app" "${3:-}"
    write_bundle_plist "$app/Contents/Library/SystemExtensions/com.kafeifei.xdial.app.transparent-proxy.systemextension" "${3:-}"
    printf '%s\n' "$app"
}

beta_tag=v1.4.0-beta.1
tag_key() {
    printf '<key>XDialReleaseTag</key><string>%s</string>' "$1"
}
missing_key="$(release_bundle missing '')"
empty_key="$(release_bundle empty "$(tag_key '')")"
tagged="$(release_bundle tagged "$(tag_key "$beta_tag")")"
other_tag="$(release_bundle other "$(tag_key v1.4.0)")"
component_tag="$(release_bundle component "$(tag_key "$beta_tag")" "$(tag_key v1.3.0)")"
integer_key="$(release_bundle integer '<key>XDialReleaseTag</key><integer>1</integer>')"
for app in "$missing_key" "$empty_key"; do
    check_release_bundle stable "$beta_tag" "$app"
    expect_failure_with "XDialReleaseTag is '', expected '$beta_tag'" \
        check_release_bundle beta "$beta_tag" "$app"
done
check_release_bundle beta "$beta_tag" "$tagged"
check_release_bundle stable "$beta_tag" "$tagged"
check_release_bundle stable v1.4.0 "$other_tag"
for channel in stable beta; do
    expect_failure_with "XDialReleaseTag is 'v1.4.0'" \
        check_release_bundle "$channel" "$beta_tag" "$other_tag"
    expect_failure_with "XDialReleaseTag is 'v1.3.0'" \
        check_release_bundle "$channel" "$beta_tag" "$component_tag"
    expect_failure_with 'must be a string' \
        check_release_bundle "$channel" "$beta_tag" "$integer_key"
done

# A beta archive that embeds a first-launch Profile, or private presets.
private_root="$test_root/private-configuration"
mkdir -p "$private_root/source" "$private_root/seed" "$private_root/presets"
/usr/bin/ditto "$tagged" "$private_root/source/XDial.app"
mkdir -p "$private_root/source/XDial.app/Contents/Resources/SeedProfile"
printf '%s\n' '{}' >"$private_root/source/XDial.app/Contents/Resources/SeedProfile/Preset.json"
/usr/bin/ditto -c -k --keepParent "$private_root/source/XDial.app" "$private_root/seed.zip"
/usr/bin/ditto -x -k "$private_root/seed.zip" "$private_root/seed"
expect_failure_with 'beta releases must not embed private configuration' \
    check_release_bundle beta "$beta_tag" "$private_root/seed/XDial.app"
check_release_bundle stable "$beta_tag" "$private_root/seed/XDial.app"
/usr/bin/ditto "$tagged" "$private_root/presets/XDial.app"
mkdir -p "$private_root/presets/XDial.app/Contents/Resources"
printf '%s\n' '{}' >"$private_root/presets/XDial.app/Contents/Resources/RuleSetPresets.json"
expect_failure_with 'beta releases must not embed private configuration' \
    check_release_bundle beta "$beta_tag" "$private_root/presets/XDial.app"

echo "release contract tests passed"
