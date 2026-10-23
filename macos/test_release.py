"""Offline release-tool tests. No signing keys, Apple services, or Bluetooth."""

import contextlib
import hashlib
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import release


SUPPORT = Path(__file__).resolve().parent / "Support"
IDENTITY = "Developer ID Application: Example Developer (TEAMID0000)"


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.support = self.root / "macos/Support"
        self.support.mkdir(parents=True)
        self.metadata = plistlib.loads((SUPPORT / "Info.plist").read_bytes())
        self.metadata.update(CFBundleShortVersionString="1.2.3", CFBundleVersion="4")
        self.write_metadata()
        self.template = (SUPPORT / "yololight-air.rb.in").read_text()
        (self.support / "yololight-air.rb.in").write_text(self.template)
        self.cask = self.root / "Casks/yololight-air.rb"
        self.archive = self.root / "dist/YoloLight-Air-1.2.3-arm64.zip"
        self.checksum = self.archive.with_suffix(".zip.sha256")
        self.calls = []
        self.architectures = "arm64\n"
        self.notarization = json.dumps({"status": "Accepted", "id": "synthetic-submission"})
        self.failure = None
        self.stapled = False
        self.signed = False
        self.verified = False
        self.identity_present = True
        self.built_metadata = None
        self.head = "1" * 40
        self.checkout_status = ""
        self.source_changes = ""
        self.stdout = io.StringIO()
        patches = [
            patch.object(release.platform, "system", return_value="Darwin"),
            patch.object(release.platform, "machine", return_value="arm64"),
            patch.object(release.shutil, "which", side_effect=lambda name: f"/tools/{name}"),
            patch.object(release, "command", side_effect=self.fake_command),
        ]
        for item in patches:
            item.start()
            self.addCleanup(item.stop)

    def write_metadata(self):
        (self.support / "Info.plist").write_bytes(plistlib.dumps(self.metadata))

    def fake_command(self, *args, capture=False):
        args = tuple(str(arg) for arg in args)
        self.calls.append(args)
        if self.failure and args[:len(self.failure)] == self.failure:
            raise subprocess.CalledProcessError(1, args)
        if args[0] == "git":
            operation = args[3:]
            if operation == ("rev-parse", "--show-toplevel"):
                return str(self.root)
            if operation == ("rev-parse", "HEAD"):
                return self.head
            if operation[0] == "status":
                return self.checkout_status
            if operation[0] == "diff":
                return self.source_changes
            return ""
        if args[:3] == ("xcrun", "--find", "swiftc"):
            return "/toolchain/usr/bin/swiftc\n"
        if args[:2] == ("security", "find-identity"):
            return f'1) SYNTHETIC "{IDENTITY}"\n' if self.identity_present else "0 valid identities found"
        if args[0].endswith("build-app.sh"):
            app = Path(args[1])
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.built_metadata or self.metadata))
            (app / "Contents/MacOS/YoloLightMenu").write_bytes(b"synthetic executable")
        elif args[:2] == ("lipo", "-archs"):
            return self.architectures
        elif args[:2] == ("codesign", "--force"):
            self.assertIn("runtime", args)
            self.assertIn("--timestamp", args)
            self.assertEqual(args[args.index("--sign") + 1], IDENTITY)
            self.signed = True
        elif args[:3] == ("xcrun", "notarytool", "submit"):
            self.assertTrue(self.signed)
            self.assertIn("--wait", args)
            self.assertEqual(args[args.index("--keychain-profile") + 1], "test profile")
            self.assertEqual(Path(args[3]).read_bytes(), b"signed submission")
            return self.notarization
        elif args[:3] == ("xcrun", "stapler", "staple"):
            self.stapled = True
        elif args[0] == "spctl":
            self.assertTrue(self.stapled)
            self.verified = True
        elif args[0] == "ditto":
            if self.stapled:
                self.assertTrue(self.verified)
            payload = b"stapled release" if self.stapled else b"signed submission" if self.signed else b"ad-hoc release"
            Path(args[-1]).write_bytes(payload)
        return ""

    def prepare(self):
        with contextlib.redirect_stdout(self.stdout):
            return release.prepare_release(self.root, IDENTITY, "test profile")

    def seed_previous_cask(self):
        self.cask.parent.mkdir(exist_ok=True)
        previous = release.render_cask(self.template, "1.2.2", hashlib.sha256(b"previous").hexdigest())
        self.cask.write_text(previous)
        return previous

    def assert_no_artifacts(self):
        self.assertFalse(self.archive.exists())
        self.assertFalse(self.checksum.exists())
        self.assertFalse(self.archive.with_suffix(".release.json").exists())
        self.assertEqual(list((self.root / "dist").glob(".yololight-release-*")), [])

    def test_final_stapled_archive_drives_checksum_and_cask(self):
        self.seed_previous_cask()
        local_app = self.root / "build/YoloLight Air.app/Contents/MacOS/YoloLightMenu"
        local_app.parent.mkdir(parents=True)
        local_app.write_bytes(b"running local app")
        self.assertEqual(self.prepare(), self.archive)
        digest = hashlib.sha256(b"stapled release").hexdigest()
        self.assertEqual(self.archive.read_bytes(), b"stapled release")
        self.assertEqual(self.checksum.read_text(), f"{digest}  {self.archive.name}\n")
        cask = self.cask.read_text()
        self.assertIn('version "1.2.3"', cask)
        self.assertIn(f'sha256 "{digest}"', cask)
        self.assertIn('/releases/download/v#{version}/YoloLight-Air-#{version}-arm64.zip', cask)
        self.assertIn('depends_on arch: :arm64', cask)
        self.assertIn('depends_on macos: :sonoma', cask)
        self.assertIn('app "YoloLight Air.app"', cask)
        self.assertNotIn(":no_check", cask)
        self.assertNotIn("@SHA256@", cask)
        self.assertEqual(local_app.read_bytes(), b"running local app")
        self.assertEqual(list((self.root / "dist").glob(".yololight-release-*")), [])
        self.assertFalse(any(args[0] in ("gh", "brew", "open") for args in self.calls))
        self.assertFalse(any(args[0] == "git" and args[3] in ("commit", "push", "add", "tag") for args in self.calls))

    def test_default_is_free_ad_hoc_without_apple_services(self):
        with contextlib.redirect_stdout(self.stdout):
            release.prepare_release(self.root)
        state = json.loads(self.archive.with_suffix(".release.json").read_text())
        self.assertEqual(state["signing"], "ad-hoc")
        self.assertEqual(state["source_commit"], self.head)
        self.assertEqual(self.archive.read_bytes(), b"ad-hoc release")
        self.assertFalse(any(args[0] in ("security", "spctl", "gh") for args in self.calls))
        self.assertFalse(any("notarytool" in args or "stapler" in args for args in self.calls))
        self.assertTrue(any(args[:2] == ("swift", "test") for args in self.calls))
        self.assertTrue(any("unittest" in args for args in self.calls))

    def test_existing_verified_artifacts_resume_without_rebuilding(self):
        self.prepare()
        self.calls.clear()
        self.checkout_status = "?? Casks/yololight-air.rb\n"
        self.prepare()
        self.assertTrue(self.calls)
        self.assertTrue(all(args[0] == "git" for args in self.calls))
        self.assertIn("Reusing verified", self.stdout.getvalue())

    def test_corrupted_artifacts_and_cask_are_rejected(self):
        self.prepare()
        for path in (self.archive, self.checksum, self.cask, self.archive.with_suffix(".release.json")):
            with self.subTest(path=path):
                original = path.read_bytes()
                path.write_text("corrupted")
                with self.assertRaises(ValueError):
                    self.prepare()
                path.write_bytes(original)

    def test_a_different_signing_mode_cannot_reuse_an_existing_version(self):
        self.prepare()
        with self.assertRaisesRegex(ValueError, "different signing mode"):
            release.prepare_release(self.root)

    def test_dirty_checkout_is_not_committed_or_built(self):
        self.checkout_status = " M README.md\n?? new-source.swift\n"
        with self.assertRaisesRegex(ValueError, "clean checkout"):
            self.prepare()
        self.assertFalse(any(args[0].endswith("build-app.sh") for args in self.calls))
        self.assertFalse(any(args[0] == "git" and args[3] in ("commit", "add", "push") for args in self.calls))
        self.assert_no_artifacts()

    def test_source_changes_prevent_reusing_stale_artifacts(self):
        self.prepare()
        self.source_changes = "macos/Sources/YoloLightMenu/App.swift\n"
        with self.assertRaisesRegex(ValueError, "source changed"):
            self.prepare()

    def test_test_failure_prevents_build_and_artifacts(self):
        previous = self.seed_previous_cask()
        self.failure = ("swift", "test")
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()
        self.assertFalse(any(args[0].endswith("build-app.sh") for args in self.calls))
        self.assertEqual(self.cask.read_text(), previous)
        self.assert_no_artifacts()

    def test_first_release_creates_cask_directory(self):
        self.prepare()
        self.assertTrue(self.cask.is_file())

    def test_notarization_requires_explicit_acceptance(self):
        previous = self.seed_previous_cask()
        for result in ({"status": "Invalid"}, {"status": "In Progress"}, {}, [], {"status": "accepted"}):
            with self.subTest(result=result):
                self.notarization = json.dumps(result)
                with self.assertRaisesRegex(ValueError, "Notarization was not accepted"):
                    self.prepare()
                self.assertEqual(self.cask.read_text(), previous)
                self.assert_no_artifacts()
        self.assertFalse(self.stapled)

    def test_malformed_notarization_reply_does_not_generate_cask(self):
        self.notarization = "not JSON"
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertFalse(self.cask.exists())
        self.assert_no_artifacts()

    def test_external_tool_failures_leave_existing_cask_untouched(self):
        previous = self.seed_previous_cask()
        for failure in (("codesign", "--force"), ("codesign", "--verify"),
                        ("xcrun", "notarytool", "submit"), ("xcrun", "stapler", "staple"),
                        ("xcrun", "stapler", "validate"), ("spctl", "--assess")):
            with self.subTest(failure=failure):
                self.failure = failure
                self.stapled = False
                self.verified = False
                with self.assertRaises(subprocess.CalledProcessError):
                    self.prepare()
                self.assertEqual(self.cask.read_text(), previous)
                self.assert_no_artifacts()

    def test_wrong_architecture_is_rejected_before_notarization(self):
        for arch in ("x86_64", "arm64 x86_64", ""):
            with self.subTest(arch=arch):
                self.architectures = arch
                with self.assertRaisesRegex(ValueError, "exactly the arm64"):
                    self.prepare()
                self.assertFalse(self.signed)
                self.assert_no_artifacts()

    def test_changed_built_metadata_is_rejected(self):
        self.built_metadata = {**self.metadata, "CFBundleVersion": "5"}
        with self.assertRaisesRegex(ValueError, "metadata differs"):
            self.prepare()
        self.assertFalse(self.signed)
        self.assert_no_artifacts()

    def test_missing_identity_fails_before_building(self):
        self.identity_present = False
        with self.assertRaisesRegex(ValueError, "not available in the keychain"):
            self.prepare()
        self.assertFalse(any(args[0].endswith("build-app.sh") for args in self.calls))
        self.assert_no_artifacts()

    def test_invalid_configuration_does_not_call_tools(self):
        with self.assertRaisesRegex(ValueError, "Developer ID"):
            release.prepare_release(self.root, "-", "test profile")
        with self.assertRaisesRegex(ValueError, "profile is required"):
            release.prepare_release(self.root, IDENTITY, " ")
        for field, value in (("CFBundleShortVersionString", "../escape"),
                             ("CFBundleShortVersionString", "1.2.3-beta"),
                             ("CFBundleShortVersionString", 3),
                             ("CFBundleVersion", "0"),
                             ("CFBundleIdentifier", "example.invalid"),
                             ("CFBundleExecutable", "AnotherExecutable"),
                             ("LSMinimumSystemVersion", "15.0")):
            with self.subTest(field=field, value=value):
                original = self.metadata[field]
                self.metadata[field] = value
                self.write_metadata()
                with self.assertRaises(ValueError):
                    self.prepare()
                self.metadata[field] = original
        self.assertEqual(self.calls, [])

    def test_unsupported_hosts_fail_before_using_tools(self):
        for system, machine in (("Linux", "arm64"), ("Darwin", "x86_64")):
            with patch.object(release.platform, "system", return_value=system), \
                    patch.object(release.platform, "machine", return_value=machine):
                with self.assertRaisesRegex(ValueError, "Apple Silicon"):
                    self.prepare()
        self.assertEqual(self.calls, [])

    def test_missing_tools_fail_before_building(self):
        with patch.object(release.shutil, "which", return_value=None):
            with self.assertRaisesRegex(ValueError, "Required tool not found"):
                self.prepare()
        self.assertEqual(self.calls, [])

    def test_existing_archive_or_checksum_is_never_overwritten(self):
        self.archive.parent.mkdir()
        for path in (self.archive, self.checksum):
            with self.subTest(path=path):
                path.write_bytes(b"existing release")
                with self.assertRaisesRegex(ValueError, "already exist"):
                    self.prepare()
                self.assertEqual(path.read_bytes(), b"existing release")
                path.unlink()
        self.assertEqual(self.calls, [])

    def test_cask_versions_must_increase_numerically(self):
        self.cask.parent.mkdir()
        for version in ("1.2.3", "1.2.4", "1.10.0", "2.0.0"):
            self.cask.write_text(release.render_cask(self.template, version, hashlib.sha256(b"old").hexdigest()))
            with self.assertRaisesRegex(ValueError, "Increase the app version"):
                self.prepare()
        self.cask.write_text("not a valid cask")
        with self.assertRaisesRegex(ValueError, "Cannot read"):
            self.prepare()
        self.assertEqual(self.calls, [])
        self.seed_previous_cask()
        release.ensure_new_version(self.cask, "1.10.0")

    def test_failed_cask_replace_rolls_back_new_artifacts(self):
        previous = self.seed_previous_cask()
        with patch.object(release.os, "replace", side_effect=OSError("cannot replace cask")):
            with self.assertRaisesRegex(OSError, "cannot replace"):
                self.prepare()
        self.assertEqual(self.cask.read_text(), previous)
        self.assert_no_artifacts()

    def test_render_rejects_invalid_versions_checksums_and_tokens(self):
        checksum = hashlib.sha256(b"fixture").hexdigest()
        for version, digest in (("../escape", checksum), ("1.2.3", ":no_check"), ("1.2.3", "abc")):
            with self.assertRaises(ValueError):
                release.render_cask(self.template, version, digest)
        for template in (self.template + "@SHA256@", self.template.replace("@VERSION@", "0"),
                         self.template + "@UNKNOWN@"):
            with self.assertRaises(ValueError):
                release.render_cask(template, "1.2.3", checksum)


if __name__ == "__main__":
    unittest.main()
