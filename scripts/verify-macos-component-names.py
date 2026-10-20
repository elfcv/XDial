#!/usr/bin/env python3
"""Verify that every component's system-visible name follows the build identity.

macOS shows the host, the Settings carrier and the System Extension by their
CFBundleDisplayName. A localized InfoPlist.strings entry overrides the
identity-derived value, so no component may localize its name. Read only.
"""

import json
import pathlib
import subprocess
import sys


NAME_KEYS = ("CFBundleDisplayName", "CFBundleName")


class ComponentNameError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ComponentNameError(message)


def read_plist(path):
    # Built strings files are UTF-16 text and Info.plist may be binary; plutil
    # reads every encoding the build can produce.
    if not path.is_file():
        raise ComponentNameError(f"missing property list: {path}")
    if path.stat().st_size == 0:
        return {}
    result = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", str(path)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise ComponentNameError(f"cannot read {path}: {detail}")
    value = json.loads(result.stdout)
    require(isinstance(value, dict), f"{path} is not a dictionary")
    return value


def unexpanded(value):
    if isinstance(value, str):
        return "$(" in value
    if isinstance(value, dict):
        return any(unexpanded(key) or unexpanded(item) for key, item in value.items())
    if isinstance(value, list):
        return any(unexpanded(item) for item in value)
    return False


def verify_component(bundle, expected):
    require(bundle.is_dir() and not bundle.is_symlink(), f"missing component: {bundle}")
    info_path = bundle / "Contents/Info.plist"
    info = read_plist(info_path)
    require(not unexpanded(info), f"unexpanded build setting in {info_path}")
    for key, value in expected.items():
        require(info.get(key) == value,
                f"{bundle.name} {key} is {info.get(key)!r}, expected {value!r}")
    for strings_path in sorted((bundle / "Contents/Resources").glob("*.lproj/InfoPlist.strings")):
        localized = read_plist(strings_path)
        require(not unexpanded(localized), f"unexpanded build setting in {strings_path}")
        overrides = [key for key in NAME_KEYS if key in localized]
        require(not overrides,
                f"{strings_path} overrides the identity name with {', '.join(overrides)}")


def verify(app, product):
    require(app.suffix == ".app", f"not a macOS application bundle: {app}")
    names = {"CFBundleDisplayName": product, "CFBundleName": product}
    verify_component(app, names)
    verify_component(app / "Contents/Helpers/XDial Settings UI.app", names)
    extensions = sorted((app / "Contents/Library/SystemExtensions").glob("*.systemextension"))
    require(extensions, f"missing System Extension in {app}")
    for extension in extensions:
        verify_component(extension, {"CFBundleDisplayName": product + " Network Extension"})
    return {"bundle": str(app), "product": product, "componentNames": "verified"}


def main(arguments):
    if len(arguments) != 2 or not arguments[1]:
        print("usage: verify-macos-component-names.py <application.app> <product-name>",
              file=sys.stderr)
        return 2
    try:
        result = verify(pathlib.Path(arguments[0]).resolve(), arguments[1])
    except (ComponentNameError, OSError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
