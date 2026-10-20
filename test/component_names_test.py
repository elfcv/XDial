import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = pathlib.Path(__file__).resolve().parents[1]
VERIFIER = REPOSITORY / "scripts/verify-macos-component-names.py"
EXTENSION_SOURCES = REPOSITORY / "macos/TransparentProxyExtension"


class ComponentNamesTests(unittest.TestCase):
    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="xdial-component-names."))
        self.addCleanup(shutil.rmtree, self.root)

    def write_plist(self, path, values, binary=False):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps(
            values, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML))

    def update_plist(self, path, **values):
        current = plistlib.loads(path.read_bytes())
        current.update(values)
        self.write_plist(path, current)

    def write_strings(self, path, text):
        # Xcode copies InfoPlist.strings into the product as UTF-16 text.
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode("utf-16"))

    def make_app(self, product):
        app = self.root / f"{product}.app"
        self.write_plist(app / "Contents/Info.plist", {
            "CFBundleDisplayName": product,
            "CFBundleName": product,
            "CFBundleExecutable": "XDial",
        }, binary=True)
        self.write_plist(app / "Contents/Helpers/XDial Settings UI.app/Contents/Info.plist", {
            "CFBundleDisplayName": product,
            "CFBundleName": product,
        })
        extension = app / "Contents/Library/SystemExtensions/fixture.transparent-proxy.systemextension"
        self.write_plist(extension / "Contents/Info.plist", {
            "CFBundleDisplayName": product + " Network Extension",
            "CFBundleName": "fixture.transparent-proxy",
            "NSSystemExtensionUsageDescription": "fixture",
        }, binary=True)
        # The real source localizations must pass the same check as the product.
        for source in sorted(EXTENSION_SOURCES.glob("*.lproj/InfoPlist.strings")):
            self.write_strings(
                extension / "Contents/Resources" / source.parent.name / source.name,
                source.read_text(encoding="utf-8"),
            )
        return app, extension

    def verify(self, app, product):
        return subprocess.run(
            [sys.executable, str(VERIFIER), str(app), product],
            capture_output=True,
            text=True,
        )

    def assert_accepted(self, app, product):
        result = self.verify(app, product)
        self.assertEqual(result.returncode, 0, result.stderr)

    def assert_rejected(self, app, product, fragment):
        result = self.verify(app, product)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn(fragment, result.stderr)

    def test_source_localizations_keep_every_identity_name(self):
        self.assertTrue(list(EXTENSION_SOURCES.glob("*.lproj/InfoPlist.strings")))
        for product in ("XDial", "XDial Debug"):
            with self.subTest(product=product):
                app, _ = self.make_app(product)
                self.assert_accepted(app, product)

    def test_localized_extension_display_name_is_rejected(self):
        app, extension = self.make_app("XDial Debug")
        strings = extension / "Contents/Resources/zh-Hans.lproj/InfoPlist.strings"
        self.write_strings(strings, '"CFBundleDisplayName" = "XDial 网络扩展";\n')
        self.assert_rejected(app, "XDial Debug", "overrides the identity name with CFBundleDisplayName")

    def test_localized_name_in_host_or_settings_is_rejected(self):
        for component in ("", "Contents/Helpers/XDial Settings UI.app"):
            with self.subTest(component=component or "host"):
                app, _ = self.make_app("XDial Debug")
                strings = app / component / "Contents/Resources/en.lproj/InfoPlist.strings"
                self.write_strings(strings, '"CFBundleName" = "XDial";\n')
                self.assert_rejected(app, "XDial Debug", "overrides the identity name with CFBundleName")
                shutil.rmtree(app)

    def test_empty_localization_is_accepted(self):
        app, _ = self.make_app("XDial Debug")
        (app / "Contents/Resources/en.lproj").mkdir(parents=True)
        (app / "Contents/Resources/en.lproj/InfoPlist.strings").write_bytes(b"")
        self.assert_accepted(app, "XDial Debug")

    def test_extension_name_from_another_identity_is_rejected(self):
        app, extension = self.make_app("XDial Debug")
        self.update_plist(extension / "Contents/Info.plist",
                          CFBundleDisplayName="XDial Network Extension")
        self.assert_rejected(app, "XDial Debug", "expected 'XDial Debug Network Extension'")

    def test_host_and_settings_names_follow_the_product(self):
        cases = [
            ("Contents/Info.plist", "CFBundleDisplayName"),
            ("Contents/Info.plist", "CFBundleName"),
            ("Contents/Helpers/XDial Settings UI.app/Contents/Info.plist", "CFBundleDisplayName"),
            ("Contents/Helpers/XDial Settings UI.app/Contents/Info.plist", "CFBundleName"),
        ]
        for path, key in cases:
            with self.subTest(path=path, key=key):
                app, _ = self.make_app("XDial Debug")
                self.update_plist(app / path, **{key: "XDial"})
                self.assert_rejected(app, "XDial Debug", f"{key} is 'XDial'")
                shutil.rmtree(app)

    def test_unexpanded_build_setting_is_rejected(self):
        app, extension = self.make_app("XDial")
        self.update_plist(extension / "Contents/Info.plist",
                          NSSystemExtensionUsageDescription="$(PRODUCT_NAME) fixture")
        self.assert_rejected(app, "XDial", "unexpanded build setting")
        app, extension = self.make_app("XDial Debug")
        self.write_strings(extension / "Contents/Resources/en.lproj/InfoPlist.strings",
                           '"NSSystemExtensionUsageDescription" = "$(PRODUCT_NAME)";\n')
        self.assert_rejected(app, "XDial Debug", "unexpanded build setting")

    def test_missing_component_is_rejected(self):
        app, extension = self.make_app("XDial")
        shutil.rmtree(extension)
        self.assert_rejected(app, "XDial", "missing System Extension")
        app, _ = self.make_app("XDial Debug")
        shutil.rmtree(app / "Contents/Helpers/XDial Settings UI.app")
        self.assert_rejected(app, "XDial Debug", "missing component")

    def test_product_name_is_required(self):
        app, _ = self.make_app("XDial")
        self.assertEqual(self.verify(app, "").returncode, 2)

    def test_release_contract_checks_the_stable_product(self):
        command = 'source "$1"; assert_component_names "$2"'
        contract = REPOSITORY / "scripts/release-contract.sh"
        environment = dict(os.environ, XDIAL_RELEASE_CHANNEL="stable")
        for product, accepted in (("XDial", True), ("XDial Debug", False)):
            with self.subTest(product=product):
                app, _ = self.make_app(product)
                result = subprocess.run(
                    ["bash", "-c", command, "release-contract-test", str(contract), str(app)],
                    env=environment,
                    capture_output=True,
                    text=True,
                )
                if accepted:
                    self.assertEqual(result.returncode, 0, result.stderr)
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("do not follow the XDial identity", result.stderr)


if __name__ == "__main__":
    unittest.main()
