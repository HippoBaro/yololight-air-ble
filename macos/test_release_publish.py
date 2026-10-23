"""Publication regression tests: Git/GitHub are simulated; nothing is published."""

import contextlib
import json
from pathlib import Path
import subprocess
import unittest

import release
import test_release


class PublishTests(unittest.TestCase):
    write_metadata = test_release.ReleaseTests.write_metadata

    def setUp(self):
        test_release.ReleaseTests.setUp(self)
        self.branch = "main"
        self.origin = f"https://github.com/{release.REPOSITORY}.git"
        self.push_origin = None
        self.remote_head = "0" * 40
        self.fetched_head = self.remote_head
        self.local_tag = None
        self.remote_tag = None
        self.release_exists = False
        self.draft = True
        self.prerelease = False
        self.private_repo = False
        self.assets = {}
        self.committed_cask = None
        self.fail_upload = False
        self.fail_cask_push = False
        self.corrupt_download = False
        self.dirty_during_download = False
        self.fail_auth = False
        with contextlib.redirect_stdout(self.stdout):
            release.prepare_release(self.root)
        self.checkout_status = "?? Casks/yololight-air.rb\n"
        self.calls.clear()

    def fake_command(self, *args, capture=False):
        args = tuple(str(arg) for arg in args)
        if args[0] not in ("git", "gh"):
            return test_release.ReleaseTests.fake_command(self, *args, capture=capture)
        self.calls.append(args)
        if args[0] == "git":
            op = args[3:]
            if op == ("rev-parse", "--show-toplevel"):
                return str(self.root)
            if op == ("rev-parse", "HEAD"):
                return self.head
            if op == ("rev-parse", "FETCH_HEAD"):
                return self.fetched_head
            if op[0] == "rev-parse" and "refs/tags/" in op[1]:
                return self.local_tag
            if op[0] == "status":
                return self.checkout_status
            if op[0] == "diff":
                return self.source_changes
            if op[:2] == ("branch", "--show-current"):
                return self.branch
            if op[:2] == ("remote", "get-url"):
                return self.push_origin or self.origin if "--push" in op else self.origin
            if op[0] == "fetch":
                self.fetched_head = self.remote_head
                return ""
            if op[:2] == ("merge-base", "--is-ancestor"):
                older, newer = (self.head if value == "HEAD" else value for value in op[2:])
                valid = older == newer or (older, newer) in {
                    ("0" * 40, "1" * 40), ("0" * 40, "2" * 40), ("1" * 40, "2" * 40),
                }
                if not valid:
                    raise subprocess.CalledProcessError(1, args)
                return ""
            if op[:2] == ("tag", "--list"):
                return "v1.2.3" if self.local_tag else ""
            if op[0] == "ls-remote":
                if self.remote_tag:
                    return f'{"a" * 40}\trefs/tags/v1.2.3\n{self.remote_tag}\trefs/tags/v1.2.3^{{}}\n'
                return ""
            if op[:2] == ("tag", "-a"):
                self.local_tag = op[3]
                return ""
            if op[0] == "push":
                self.assertIn("--no-follow-tags", op)
                ref = op[-1]
                if ref.startswith("refs/tags/"):
                    self.remote_tag = self.local_tag
                elif ref == "HEAD:refs/heads/main":
                    if self.fail_cask_push:
                        raise subprocess.CalledProcessError(1, args)
                    self.remote_head = self.head
                else:
                    self.remote_head = ref.split(":")[0]
                return ""
            if op[0] == "add":
                self.assertEqual(op, ("add", "--", release.CASK_PATH))
                return ""
            if op[0] == "commit":
                self.assertIn("--only", op)
                self.assertEqual(op[-2:], ("--", release.CASK_PATH))
                self.head = "2" * 40
                self.committed_cask = self.cask.read_text()
                self.checkout_status = ""
                return ""
            if op[0] == "show":
                return self.committed_cask
            self.fail(f"Unexpected Git command: {op}")
        if args[1] == "auth":
            if self.fail_auth:
                raise subprocess.CalledProcessError(1, args, stderr="authentication failed")
            return ""
        if args[1] == "api":
            self.assertIn("github.com", args)
            if "/releases?" in args[2]:
                self.assertIn("--paginate", args)
                return json.dumps({"draft": self.draft, "prerelease": self.prerelease}) if self.release_exists else ""
            return json.dumps({"private": self.private_repo, "default_branch": "main"})
        self.assertEqual(args[1], "release")
        self.assertEqual(args[-2:], ("--repo", f"github.com/{release.REPOSITORY}"))
        action = args[2]
        if action == "create":
            self.assertIn("--draft", args)
            self.assertIn("--verify-tag", args)
            self.assertIn("NOT notarized", args[args.index("--notes") + 1])
            self.assertEqual(self.remote_tag, "1" * 40)
            self.release_exists = True
            self.draft = True
        elif action == "view":
            if args[args.index("--json") + 1] == "assets":
                return "\n".join(self.assets)
            return json.dumps({"isDraft": self.draft, "isPrerelease": self.prerelease})
        elif action == "upload":
            path = Path(args[4])
            if self.fail_upload and path.name.endswith(".sha256"):
                raise subprocess.CalledProcessError(1, args)
            self.assertTrue(self.draft, "Never modify a published release")
            self.assertNotIn("--clobber", args)
            self.assertNotIn(path.name, self.assets)
            self.assets[path.name] = path.read_bytes()
        elif action == "download":
            name = args[args.index("--pattern") + 1]
            directory = Path(args[args.index("--dir") + 1])
            payload = b"corrupted" if self.corrupt_download else self.assets[name]
            (directory / name).write_bytes(payload)
            if self.dirty_during_download:
                self.checkout_status = " M README.md\n?? Casks/yololight-air.rb\n"
        elif action == "edit":
            self.assertIn("--draft=false", args)
            self.assertEqual(set(self.assets), {self.archive.name, self.checksum.name})
            self.draft = False
        else:
            self.fail(f"Unexpected GitHub command: {args}")
        return ""

    def publish(self):
        with contextlib.redirect_stdout(self.stdout):
            release.publish_release(self.root)

    def writes(self):
        return [args for args in self.calls
                if args[0] == "git" and args[3] in ("push", "commit", "add")
                or args[:2] == ("gh", "release") and args[2] in ("create", "upload", "edit")]

    def test_complete_publish_orders_assets_before_cask_and_tags_exact_source(self):
        self.publish()
        self.assertEqual(self.remote_tag, "1" * 40)
        self.assertEqual(self.remote_head, "2" * 40)
        self.assertFalse(self.draft)
        self.assertEqual(self.committed_cask, self.cask.read_text())
        published = next(i for i, args in enumerate(self.calls) if args[:3] == ("gh", "release", "edit"))
        committed = next(i for i, args in enumerate(self.calls) if args[0] == "git" and args[3] == "commit")
        downloads = [i for i, args in enumerate(self.calls) if args[:3] == ("gh", "release", "download")]
        self.assertEqual(len(downloads), 4)
        self.assertTrue(downloads[1] < published < downloads[2] < downloads[3] < committed)
        self.assertFalse(any("--force" in args or "--clobber" in args for args in self.calls))

    def test_partial_upload_resumes_same_draft_without_rebuilding_or_overwriting(self):
        self.fail_upload = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertTrue(self.draft)
        self.assertEqual(set(self.assets), {self.archive.name})
        self.assertIsNone(self.committed_cask)
        self.fail_upload = False
        self.calls.clear()
        self.publish()
        uploads = [args for args in self.calls if args[:3] == ("gh", "release", "upload")]
        self.assertEqual(len(uploads), 1)
        self.assertEqual(Path(uploads[0][4]), self.checksum)
        self.assertFalse(any(args[:3] == ("gh", "release", "create") for args in self.calls))

    def test_failed_cask_push_resumes_without_duplicate_commit(self):
        self.fail_cask_push = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertFalse(self.draft)
        self.assertEqual(self.head, "2" * 40)
        self.assertEqual(self.remote_head, "1" * 40)
        self.fail_cask_push = False
        self.calls.clear()
        self.publish()
        self.assertFalse(any(args[0] == "git" and args[3] == "commit" for args in self.calls))
        self.assertFalse(any(args[:3] == ("gh", "release", "upload") for args in self.calls))
        pushes = [args for args in self.calls if args[0] == "git" and args[3] == "push"]
        self.assertEqual(len(pushes), 1)
        self.assertEqual(pushes[0][-1], "HEAD:refs/heads/main")

    def test_completed_release_can_be_rechecked_without_recreating_assets(self):
        self.publish()
        self.calls.clear()
        self.publish()
        self.assertFalse(any(args[0] == "git" and args[3] == "commit" for args in self.calls))
        self.assertFalse(any(args[:2] == ("gh", "release") and args[2] in ("create", "upload", "edit")
                             for args in self.calls))

    def test_wrong_branch_origin_or_private_repository_blocks_writes(self):
        for field, value in (("branch", "feature"), ("origin", "https://github.com/example/elsewhere.git"),
                             ("push_origin", "git@github.com:example/elsewhere.git"),
                             ("private_repo", True), ("remote_head", "3" * 40)):
            with self.subTest(field=field):
                original = getattr(self, field)
                setattr(self, field, value)
                self.calls.clear()
                with self.assertRaises(ValueError):
                    self.publish()
                self.assertEqual(self.writes(), [])
                setattr(self, field, original)

    def test_auth_failure_is_not_mistaken_for_missing_release(self):
        self.fail_auth = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.publish()
        self.assertEqual(self.writes(), [])

    def test_conflicting_local_or_remote_tag_is_never_moved(self):
        for field in ("local_tag", "remote_tag"):
            with self.subTest(field=field):
                setattr(self, field, "3" * 40)
                self.calls.clear()
                with self.assertRaisesRegex(ValueError, "tag points to different source"):
                    self.publish()
                self.assertEqual(self.writes(), [])
                setattr(self, field, None)

    def test_existing_draft_asset_is_verified_not_overwritten(self):
        self.release_exists = True
        self.assets[self.archive.name] = b"different archive"
        with self.assertRaisesRegex(ValueError, "differs from the prepared release"):
            self.publish()
        self.assertEqual(self.assets[self.archive.name], b"different archive")
        self.assertTrue(self.draft)
        self.assertIsNone(self.committed_cask)
        self.assertFalse(any(args[:3] == ("gh", "release", "upload") for args in self.calls))

    def test_download_corruption_never_publishes_or_commits_cask(self):
        self.corrupt_download = True
        with self.assertRaisesRegex(ValueError, "differs from the prepared release"):
            self.publish()
        self.assertTrue(self.draft)
        self.assertIsNone(self.committed_cask)

    def test_published_release_missing_asset_is_not_modified(self):
        self.release_exists = True
        self.draft = False
        with self.assertRaisesRegex(ValueError, "published release is missing"):
            self.publish()
        self.assertFalse(any(args[:3] == ("gh", "release", "upload") for args in self.calls))
        self.assertIsNone(self.committed_cask)

    def test_unrelated_edits_during_upload_are_never_committed(self):
        self.dirty_during_download = True
        with self.assertRaisesRegex(ValueError, "clean checkout"):
            self.publish()
        self.assertTrue(self.draft)
        self.assertIsNone(self.committed_cask)
        self.assertFalse(any(args[0] == "git" and args[3] in ("add", "commit") for args in self.calls))


if __name__ == "__main__":
    unittest.main()
