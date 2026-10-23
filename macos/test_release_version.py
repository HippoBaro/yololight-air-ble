"""Version arguments and metadata-only commits, using disposable Git repositories."""

import contextlib
import io
from pathlib import Path
import plistlib
import shutil
import subprocess
import unittest
from unittest.mock import Mock, patch

import release
import test_release_git


@unittest.skipUnless(shutil.which("git"), "Git required for isolated version regression tests")
class VersionTests(unittest.TestCase):
    def setUp(self):
        test_release_git.GitSafetyTests.setUp(self)
        self.path = self.root / release.METADATA_PATH
        self.path.parent.mkdir(parents=True)
        self.baseline = release.read_metadata(Path(__file__).resolve().parent / "Support/Info.plist")
        self.baseline.update(CFBundleShortVersionString="0.1.0", CFBundleVersion="1")
        self.updated = {**self.baseline, "CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "2"}
        self.path.write_bytes(plistlib.dumps(self.baseline, sort_keys=False))
        release.git(self.root, "add", "--", release.METADATA_PATH)
        release.git(self.root, "commit", "-m", "Synthetic app metadata")
        self.source = release.git(self.root, "rev-parse", "HEAD")
        self.original = self.path.read_bytes()
        self.stdout = io.StringIO()

    def update(self, version="0.1.1"):
        with contextlib.redirect_stdout(self.stdout):
            return release.set_release_version(self.root, version)

    def assert_unchanged(self):
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual(release.git(self.root, "rev-parse", "HEAD"), self.source)

    def test_new_version_commits_only_metadata_and_retries_do_not_increment(self):
        mode = self.path.stat().st_mode
        self.assertTrue(self.update())
        self.assertEqual(release.read_metadata(self.path), self.updated)
        self.assertEqual(self.path.stat().st_mode, mode)
        self.assertEqual(release.git(self.root, "diff", "--name-only", self.source, "HEAD"), release.METADATA_PATH)
        self.assertEqual(release.git(self.root, "status", "--porcelain"), "")
        self.assertEqual(release.git(self.root, "rev-list", "--count", f"{self.source}..HEAD"), "1")
        head = release.git(self.root, "rev-parse", "HEAD")
        self.assertFalse(self.update())
        self.assertEqual(release.git(self.root, "rev-parse", "HEAD"), head)
        self.assertEqual(release.read_metadata(self.path), self.updated)
        # A prepared cask is validated by prepare_release, not silently committed by this step.
        self.cask.parent.mkdir()
        self.cask.write_text("pending cask\n")
        self.assertFalse(self.update())
        self.assertEqual(release.git(self.root, "rev-parse", "HEAD"), head)
        self.assertEqual(release.git(self.root, "tag", "--list"), "")
        self.assertFalse((self.root / "dist").exists())

    def test_numeric_order_and_one_build_increment_per_new_version(self):
        self.update("0.1.9")
        self.update("0.1.10")
        self.assertEqual(release.read_metadata(self.path)["CFBundleVersion"], "3")
        self.assertFalse(self.update("0.1.10"))
        self.update("2.0.0")
        self.assertEqual(release.read_metadata(self.path)["CFBundleVersion"], "4")

    def test_invalid_or_older_versions_do_not_change_the_checkout(self):
        for version in ("", "v0.1.1", "0.1", "01.2.3", "0.1.1-beta", "../escape", "0.0.9"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                self.update(version)
            self.assert_unchanged()

    def test_dirty_source_is_never_staged_or_committed(self):
        for state in ("modified", "staged", "untracked"):
            with self.subTest(state=state):
                path = self.root / ("new-source.txt" if state == "untracked" else "source.txt")
                original = path.read_bytes() if path.exists() else None
                path.write_text("unreviewed source\n")
                if state == "staged":
                    release.git(self.root, "add", "--", path.name)
                status = release.git(self.root, "status", "--porcelain")
                with self.assertRaisesRegex(ValueError, "clean checkout"):
                    self.update()
                self.assert_unchanged()
                self.assertEqual(release.git(self.root, "status", "--porcelain"), status)
                self.assertEqual(path.read_text(), "unreviewed source\n")
                if original is None:
                    path.unlink()
                else:
                    path.write_bytes(original)
                    release.git(self.root, "add", "--", path.name)

    def test_unrelated_working_or_staged_metadata_is_preserved(self):
        unexpected = {**self.updated, "CFBundleDisplayName": "Unreviewed name"}
        self.path.write_bytes(plistlib.dumps(unexpected))
        with self.assertRaisesRegex(ValueError, "beyond the requested"):
            self.update()
        release.git(self.root, "add", "--", release.METADATA_PATH)
        self.path.write_bytes(plistlib.dumps(self.updated, sort_keys=False))
        index = release.git(self.root, "show", f":{release.METADATA_PATH}")
        with self.assertRaisesRegex(ValueError, "Staged Info.plist"):
            self.update()
        self.assertEqual(release.git(self.root, "show", f":{release.METADATA_PATH}"), index)
        self.assertEqual(release.read_metadata(self.path), self.updated)
        self.assertEqual(release.git(self.root, "rev-parse", "HEAD"), self.source)

    def test_current_version_does_not_allow_a_different_uncommitted_version(self):
        self.path.write_bytes(plistlib.dumps(self.updated))
        with self.assertRaisesRegex(ValueError, "uncommitted changes"):
            self.update("0.1.0")
        self.assertEqual(release.read_metadata(self.path), self.updated)
        self.assertEqual(release.git(self.root, "rev-parse", "HEAD"), self.source)

    def test_exact_unstaged_metadata_bump_can_resume(self):
        self.path.write_bytes(plistlib.dumps(self.updated, sort_keys=False))
        self.assertTrue(self.update())
        self.assertEqual(release.read_metadata(self.path), self.updated)
        self.assertEqual(release.git(self.root, "status", "--porcelain"), "")

    def test_failed_commit_resumes_without_an_extra_build_increment(self):
        original_git = release.git

        def fail_commit(root, *args):
            if args[0] == "commit":
                raise subprocess.CalledProcessError(1, ["git", *args], stderr="synthetic commit failure")
            return original_git(root, *args)

        with patch.object(release, "git", side_effect=fail_commit):
            with self.assertRaises(subprocess.CalledProcessError):
                self.update()
        self.assertEqual(release.read_metadata(self.path), self.updated)
        self.assertEqual(release.git(self.root, "rev-parse", "HEAD"), self.source)
        self.assertTrue(self.update())
        self.assertEqual(release.read_metadata(self.path), self.updated)
        self.assertEqual(release.git(self.root, "rev-list", "--count", f"{self.source}..HEAD"), "1")
        self.assertFalse(self.update())

    def test_existing_artifacts_are_not_overwritten_or_committed(self):
        (self.root / "dist").mkdir()
        for path in release.artifact_paths(self.root, "0.1.1"):
            with self.subTest(path=path):
                path.write_bytes(b"immutable fixture")
                with self.assertRaisesRegex(ValueError, "Artifacts already exist"):
                    self.update()
                self.assert_unchanged()
                self.assertEqual(path.read_bytes(), b"immutable fixture")
                path.unlink()

    def test_existing_tag_is_not_moved(self):
        release.git(self.root, "tag", "v0.1.1")
        with self.assertRaisesRegex(ValueError, "tag already exists"):
            self.update()
        self.assert_unchanged()
        self.assertEqual(release.git(self.root, "rev-parse", "v0.1.1"), self.source)

    def test_cask_version_is_also_a_lower_bound(self):
        self.cask.parent.mkdir()
        self.cask.write_text('cask "yololight-air" do\n  version "0.2.0"\nend\n')
        release.git(self.root, "add", "--", release.CASK_PATH)
        release.git(self.root, "commit", "-m", "Synthetic newer cask")
        self.source = release.git(self.root, "rev-parse", "HEAD")
        with self.assertRaisesRegex(ValueError, "Increase the app version"):
            self.update()
        self.assert_unchanged()

    def test_automatic_bumps_require_main_not_another_branch_or_detached_head(self):
        release.git(self.root, "checkout", "-b", "fixture-branch")
        with self.assertRaisesRegex(ValueError, "require branch main"):
            self.update()
        self.assert_unchanged()
        release.git(self.root, "checkout", "--detach")
        with self.assertRaisesRegex(ValueError, "require branch main"):
            self.update()
        self.assert_unchanged()

    def test_failed_atomic_write_preserves_original_metadata(self):
        with patch.object(release.os, "replace", side_effect=OSError("synthetic replace failure")):
            with self.assertRaisesRegex(OSError, "replace failure"):
                self.update()
        self.assert_unchanged()
        self.assertEqual(list(self.path.parent.glob(".Info.plist-*")), [])
        self.assertEqual(release.git(self.root, "status", "--porcelain"), "")

    def test_unexpected_commit_hook_metadata_changes_stop_the_release(self):
        original_git = release.git

        def alter_commit(root, *args):
            if args[0] == "commit":
                self.path.write_bytes(plistlib.dumps({**self.updated, "CFBundleVersion": "99"}))
            return original_git(root, *args)

        with patch.object(release, "git", side_effect=alter_commit):
            with self.assertRaisesRegex(ValueError, "unexpected content"):
                self.update()

    def test_pending_bump_does_not_commit_unrelated_xml_comments(self):
        generated = plistlib.dumps(self.updated, sort_keys=False)
        unexpected = generated.replace(b"</plist>", b"<!-- unrelated draft note -->\n</plist>")
        self.path.write_bytes(unexpected)
        with self.assertRaisesRegex(ValueError, "beyond the requested"):
            self.update()
        self.assertEqual(self.path.read_bytes(), unexpected)
        self.assertEqual(release.git(self.root, "rev-parse", "HEAD"), self.source)
        self.assertEqual(release.git(self.root, "diff", "--cached", "--name-only"), "")

    def test_pending_bump_preserves_unrelated_staged_xml_comments(self):
        unexpected = self.original.replace(b"</plist>", b"<!-- staged draft note -->\n</plist>")
        self.path.write_bytes(unexpected)
        release.git(self.root, "add", "--", release.METADATA_PATH)
        generated = plistlib.dumps(self.updated, sort_keys=False)
        self.path.write_bytes(generated)
        index = release.git(self.root, "show", f":{release.METADATA_PATH}")
        with self.assertRaisesRegex(ValueError, "Staged Info.plist"):
            self.update()
        self.assertEqual(release.git(self.root, "show", f":{release.METADATA_PATH}"), index)
        self.assertEqual(self.path.read_bytes(), generated)
        self.assertEqual(release.git(self.root, "rev-parse", "HEAD"), self.source)

    def test_pending_bump_preserves_working_and_staged_file_mode_changes(self):
        release.git(self.root, "config", "core.filemode", "true")
        mode = self.path.stat().st_mode
        self.path.write_bytes(plistlib.dumps(self.updated, sort_keys=False))
        for staged in (False, True):
            with self.subTest(staged=staged):
                if staged:
                    release.git(self.root, "add", "--", release.METADATA_PATH)
                    release.git(self.root, "update-index", "--chmod=+x", "--", release.METADATA_PATH)
                else:
                    self.path.chmod(mode | 0o111)
                status = release.git(self.root, "status", "--porcelain")
                with self.assertRaisesRegex(ValueError, "file mode"):
                    self.update()
                self.assertEqual(release.git(self.root, "rev-parse", "HEAD"), self.source)
                self.assertEqual(release.git(self.root, "status", "--porcelain"), status)
                self.assertEqual(self.path.stat().st_mode, mode if staged else mode | 0o111)
                self.path.chmod(mode)

    def test_commit_hook_cannot_add_unrelated_xml_content(self):
        original_git = release.git

        def alter_commit(root, *args):
            if args[0] == "commit":
                self.path.write_bytes(self.path.read_bytes().replace(
                    b"</plist>", b"<!-- unrelated hook content -->\n</plist>"))
            return original_git(root, *args)

        with patch.object(release, "git", side_effect=alter_commit):
            with self.assertRaisesRegex(ValueError, "unexpected content"):
                self.update()


class VersionArgumentTests(unittest.TestCase):
    def setUp(self):
        self.calls = Mock()
        self.output = io.StringIO()
        for name in ("validate_configuration", "set_release_version", "prepare_release", "publish_release"):
            item = patch.object(release, name)
            self.calls.attach_mock(item.start(), name)
            self.addCleanup(item.stop)
        for manager in (contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output)):
            manager.__enter__()
            self.addCleanup(manager.__exit__, None, None, None)
        self.root = Path(release.__file__).resolve().parent.parent

    def test_version_is_applied_before_local_packaging_without_publishing(self):
        release.main(["0.1.1"])
        self.calls.set_release_version.assert_called_once_with(self.root, "0.1.1")
        self.calls.prepare_release.assert_called_once_with(self.root, None, None)
        self.calls.publish_release.assert_not_called()
        self.assertEqual([call[0] for call in self.calls.mock_calls],
                         ["validate_configuration", "set_release_version", "prepare_release"])
        self.assertIn("Nothing was published.", self.output.getvalue())
        self.assertNotIn("or committed", self.output.getvalue())

    def test_version_with_publication_and_optional_signing(self):
        release.main(["0.1.1", "--publish", "--identity", "fixture identity", "--notary-profile", "fixture profile"])
        self.calls.set_release_version.assert_called_once_with(self.root, "0.1.1")
        self.calls.prepare_release.assert_called_once_with(self.root, "fixture identity", "fixture profile")
        self.calls.publish_release.assert_called_once_with(self.root)
        self.assertEqual([call[0] for call in self.calls.mock_calls],
                         ["validate_configuration", "set_release_version", "prepare_release", "publish_release"])

    def test_omitted_version_preserves_existing_commands(self):
        release.main([])
        self.calls.set_release_version.assert_not_called()
        self.calls.publish_release.assert_not_called()
        release.main(["--publish"])
        self.calls.set_release_version.assert_not_called()
        self.calls.publish_release.assert_called_once_with(self.root)

    def test_invalid_versions_are_rejected_before_any_side_effects(self):
        for version in ("v0.1.1", "1.2", "1.2.3.4", "01.2.3", "1.2.3-beta", "1.2.3+build", "../escape"):
            with self.subTest(version=version), self.assertRaises(SystemExit) as error:
                release.main([version, "--publish"])
            self.assertEqual(error.exception.code, 2)
        self.assertEqual(self.calls.mock_calls, [])
        self.assertIn("major.minor.patch", self.output.getvalue())

    def test_invalid_host_or_signing_configuration_cannot_commit_a_version(self):
        self.calls.validate_configuration.side_effect = ValueError("synthetic invalid configuration")
        with self.assertRaises(SystemExit) as error:
            release.main(["0.1.1", "--publish"])
        self.assertEqual(error.exception.code, 1)
        self.calls.set_release_version.assert_not_called()
        self.calls.prepare_release.assert_not_called()
        self.calls.publish_release.assert_not_called()

    def test_version_update_failure_prevents_packaging_and_publication(self):
        self.calls.set_release_version.side_effect = ValueError("synthetic version failure")
        with self.assertRaises(SystemExit) as error:
            release.main(["0.1.1", "--publish"])
        self.assertEqual(error.exception.code, 1)
        self.calls.prepare_release.assert_not_called()
        self.calls.publish_release.assert_not_called()


if __name__ == "__main__":
    unittest.main()
