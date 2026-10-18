#!/bin/bash

set -euo pipefail

readonly project_path="${1:-macos/XDial.xcodeproj}"
readonly application_identifier="com.kafeifei.xdial.app"
readonly settings_identifier="com.kafeifei.xdial.app.settings-ui"
readonly extension_identifier="com.kafeifei.xdial.app.transparent-proxy"
readonly settings_cache="$(mktemp -d "${TMPDIR:-/tmp}/xdial-build-settings.XXXXXX")"
trap 'rm -rf "$settings_cache"' EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

build_setting() {
    local configuration="$1"
    local target="$2"
    local key="$3"

    local cached="$settings_cache/$configuration-$target.txt"
    if [[ ! -f "$cached" ]]; then
        /usr/bin/xcodebuild -project "$project_path" -target "$target" \
            -configuration "$configuration" -showBuildSettings \
            >"$cached" 2>"$cached.stderr" \
            || { cat "$cached.stderr" >&2; fail "cannot read $configuration/$target settings"; }
    fi
    /usr/bin/awk -F ' = ' -v key="$key" '
        $1 ~ "^[[:space:]]*" key "$" { value=$2 }
        END { print value }
    ' "$cached"
}

assert_setting() {
    local configuration="$1"
    local target="$2"
    local expected="$3"
    local actual

    actual="$(build_setting \
        "$configuration" "$target" PRODUCT_BUNDLE_IDENTIFIER)"
    [[ "$actual" == "$expected" ]] \
        || fail "$configuration/$target uses '$actual', expected '$expected'"
}

assert_build_setting() {
    local configuration="$1"
    local target="$2"
    local key="$3"
    local expected="$4"
    local actual

    actual="$(build_setting "$configuration" "$target" "$key")"
    [[ "$actual" == "$expected" ]] \
        || fail "$configuration/$target $key is '$actual', expected '$expected'"
}

assert_plist_boolean() {
    local plist="$1"
    local key="$2"
    local actual

    [[ -f "$plist" ]] || fail "missing plist: $plist"
    actual="$(/usr/bin/plutil -extract "$key" raw -o - "$plist" 2>/dev/null \
        || true)"
    [[ "$actual" == true ]] \
        || fail "$plist is missing required boolean entitlement $key"
}

assert_plist_nonempty() {
    local plist="$1"
    local key="$2"
    local actual

    [[ -f "$plist" ]] || fail "missing plist: $plist"
    actual="$(/usr/bin/plutil -extract "$key" raw -o - "$plist" 2>/dev/null \
        || true)"
    [[ -n "$actual" ]] || fail "$plist is missing required key $key"
}

[[ -f "$project_path/project.pbxproj" ]] \
    || fail "generated Xcode project is missing: $project_path"

# Exactly two identities: Debug and the formal one. A beta release is a
# Release build, so no other configuration may exist.
project_listing="$(/usr/bin/xcodebuild -list -project "$project_path" \
    2>"$settings_cache/list.stderr")" \
    || { cat "$settings_cache/list.stderr" >&2; fail "cannot list $project_path"; }
configurations="$(/usr/bin/awk '/^[[:space:]]*Build Configurations:/ { listing = 1; next }
        listing && /^[[:space:]]*$/ { listing = 0 }
        listing { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }' <<<"$project_listing" \
    | /usr/bin/sort | /usr/bin/paste -sd ' ' -)"
[[ "$configurations" == 'Debug FormalDevelopment Release' ]] \
    || fail "build configurations are '$configurations', expected 'Debug FormalDevelopment Release'"

for configuration in FormalDevelopment Release; do
    assert_setting "$configuration" XDial "$application_identifier"
    assert_setting "$configuration" XDialSettingsUI "$settings_identifier"
    assert_setting \
        "$configuration" XDialTransparentProxy "$extension_identifier"
done

assert_setting Debug XDial com.kafeifei.xdial.debug
assert_setting Debug XDialSettingsUI com.kafeifei.xdial.debug.settings-ui
assert_setting Debug XDialTransparentProxy com.kafeifei.xdial.debug.transparent-proxy
assert_build_setting Debug XDial PRODUCT_NAME 'XDial Debug'
assert_build_setting Debug XDial EXECUTABLE_NAME XDial
assert_build_setting Debug XDial XDIAL_HELPER_IDENTIFIER com.kafeifei.xdial.debug.helper
assert_build_setting Debug XDial XDIAL_DAEMON_PLIST com.kafeifei.xdial.debug.daemon.plist
assert_build_setting Debug XDial XDIAL_DAEMON_ENTITLEMENTS XDialDaemonDebug.entitlements
assert_build_setting Debug XDial CODE_SIGN_ENTITLEMENTS XDialDebug.entitlements
assert_build_setting Debug XDialTransparentProxy CODE_SIGN_ENTITLEMENTS TransparentProxyExtension/XDialTransparentProxyDebug.entitlements
for target in XDial XDialSettingsUI XDialTransparentProxy XDialTests; do
    [[ " $(build_setting Debug "$target" SWIFT_ACTIVE_COMPILATION_CONDITIONS) " == *' XDIAL_DEVELOPMENT_IDENTITY '* ]] \
        || fail "Debug/$target missing development identity condition"
done
for configuration in FormalDevelopment Release; do
    for target in XDial XDialSettingsUI XDialTransparentProxy; do
        conditions=" $(build_setting "$configuration" "$target" SWIFT_ACTIVE_COMPILATION_CONDITIONS) "
        [[ "$conditions" != *' XDIAL_DEVELOPMENT_IDENTITY '* ]] \
            || fail "$configuration/$target incorrectly uses development identity"
        [[ "$conditions" != *' DEBUG '* ]] \
            || fail "$configuration/$target compiles DebugServer and other DEBUG code"
    done
    assert_build_setting "$configuration" XDial PRODUCT_NAME XDial
    assert_build_setting "$configuration" XDial XDIAL_HELPER_IDENTIFIER com.kafeifei.xdial.app.helper
    assert_build_setting "$configuration" XDial XDIAL_DAEMON_PLIST com.kafeifei.xdial.app.daemon.plist
done
for target in XDial XDialSettingsUI XDialTransparentProxy; do
    assert_build_setting Debug "$target" XDIAL_PRODUCT_DISPLAY_NAME 'XDial Debug'
    assert_build_setting Debug "$target" XDIAL_BUILD_FLAVOR debug
    for configuration in FormalDevelopment Release; do
        assert_build_setting "$configuration" "$target" XDIAL_PRODUCT_DISPLAY_NAME XDial
        assert_build_setting "$configuration" "$target" XDIAL_BUILD_FLAVOR release
    done
done
for target in XDial XDialSettingsUI XDialTransparentProxy; do
    assert_build_setting Debug "$target" CODE_SIGN_IDENTITY 'Apple Development'
    assert_build_setting Release "$target" CODE_SIGN_IDENTITY 'Developer ID Application'
done
assert_build_setting Release XDial PROVISIONING_PROFILE_SPECIFIER 'XDial Developer ID App Host 2026'
assert_build_setting Release XDialTransparentProxy PROVISIONING_PROFILE_SPECIFIER 'XDial Developer ID App Transparent Proxy'
for configuration in FormalDevelopment; do
    assert_build_setting \
        "$configuration" XDial CODE_SIGN_ENTITLEMENTS XDial.entitlements
done
assert_build_setting \
    Release XDial CODE_SIGN_ENTITLEMENTS XDialRelease.entitlements

assert_plist_boolean macos/XDialDebug.entitlements \
    'com\.apple\.security\.personal-information\.location'
assert_plist_boolean macos/XDial.entitlements \
    'com\.apple\.security\.personal-information\.location'
assert_plist_boolean macos/XDialRelease.entitlements \
    'com\.apple\.security\.personal-information\.location'
assert_plist_nonempty macos/Info.plist NSLocationUsageDescription

python3 - <<'PYTHON'
import pathlib, plistlib
for path in ["XDialDebug.entitlements", "XDialDaemonDebug.entitlements", "TransparentProxyExtension/XDialTransparentProxyDebug.entitlements"]:
    value = plistlib.loads((pathlib.Path("macos") / path).read_bytes())
    assert value["com.apple.security.application-groups"] == ["UVZM439VGU.com.kafeifei.xdial.debug.network"], path
value = plistlib.loads(pathlib.Path("macos/com.kafeifei.xdial.debug.daemon.plist").read_bytes())
assert value["Label"] == "com.kafeifei.xdial.debug.daemon"
assert "/tmp/xdial-debug.sock" in value["ProgramArguments"]
assert value["AssociatedBundleIdentifiers"] == ["com.kafeifei.xdial.debug"]
assert value["StandardOutPath"] == value["StandardErrorPath"] == "/tmp/xdial-debug.log"
PYTHON

python3 - <<'PYTHON'
import pathlib, plistlib
for channel, name in [("debug", "XDial Debug"), ("app", "XDial")]:
    path = pathlib.Path(f"macos/com.kafeifei.xdial.{channel}.daemon.plist")
    value = plistlib.loads(path.read_bytes())
    assert value["Program"] == f"/Applications/{name}.app/Contents/MacOS/xdial-daemon", path
    assert "BundleProgram" not in value, path
PYTHON

# System Settings shows each component by CFBundleDisplayName. The name comes
# only from XDIAL_PRODUCT_DISPLAY_NAME; a localization would pin it to one identity.
python3 - <<'PYTHON'
import json, pathlib, plistlib, subprocess
for path in sorted(pathlib.Path("macos").rglob("*.lproj/InfoPlist.strings")):
    values = json.loads(subprocess.check_output(["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)]))
    for key in ("CFBundleDisplayName", "CFBundleName"):
        assert key not in values, f"{path} overrides the identity name with {key}"
for path, expected in [
    ("Info.plist", "$(XDIAL_PRODUCT_DISPLAY_NAME)"),
    ("SettingsDockUI/Info.plist", "$(XDIAL_PRODUCT_DISPLAY_NAME)"),
    ("TransparentProxyExtension/Info.plist", "$(XDIAL_PRODUCT_DISPLAY_NAME) Network Extension"),
]:
    value = plistlib.loads((pathlib.Path("macos") / path).read_bytes()).get("CFBundleDisplayName")
    assert value == expected, f"macos/{path} CFBundleDisplayName is {value!r}, expected {expected!r}"
PYTHON

# No configuration defines the retired third identity's condition any more, so
# code behind it would compile out silently. Release environments may lack rg;
# git grep exits 1 when nothing matches.
set +e
retired_identity_matches="$(git grep -n XDIAL_NEXT_IDENTITY -- macos)"
retired_identity_status=$?
set -e
(( retired_identity_status <= 1 )) || fail "cannot scan macos for XDIAL_NEXT_IDENTITY"
[[ -z "$retired_identity_matches" ]] \
    || fail "macos still references XDIAL_NEXT_IDENTITY:"$'\n'"$retired_identity_matches"

# System Settings, the Applications folder, Force Quit and the menu bar show
# Debug as "XDial Debug". Copy that sends the user there names the app through
# XDialBuildIdentity.applicationDisplayName, never a literal "XDial".
python3 - <<'PYTHON'
import pathlib, re
surface = re.compile(r"系统设置|System Settings|登录项|Login Items|位置服务|Location Services"
                     r"|“应用程序”|Applications folder|强制退出|Force Quit|菜单栏|menu bar")
literal = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
bare_name = re.compile(r"(?<![\w.])XDial(?!\w)")
failures = [
    f"{path}:{number}: {line.strip()}"
    for path in sorted(pathlib.Path("macos").rglob("*.swift")) if "Tests" not in path.parts
    for number, line in enumerate(path.read_text().splitlines(), 1)
    if any(surface.search(text) and bare_name.search(text) for text in literal.findall(line))
]
assert not failures, "system-surface copy hard-codes XDial:\n" + "\n".join(failures)
PYTHON

echo "macOS development isolation, formal identity, component-name, system-surface copy, and location-access contracts verified"
