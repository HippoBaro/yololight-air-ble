"""Exercise real Git in disposable synthetic repositories, never the app checkout."""

import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import release


@unittest.skipUnless(shutil.which("git"), "Git required for isolated Git regression tests")
class GitSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                           GIT_AUTHOR_NAME="Release Test", GIT_COMMITTER_NAME="Release Test",
                           GIT_AUTHOR_EMAIL="release@example.invalid", GIT_COMMITTER_EMAIL="release@example.invalid")
        env = patch.dict(os.environ, environment, clear=True)
        env.start()
        self.addCleanup(env.stop)
        release.git(self.root, "-c", "init.templateDir=", "init", "-b", "main")
        (self.root / ".gitignore").write_text("dist/\n")
        (self.root / "source.txt").write_text("synthetic source\n")
        release.git(self.root, "add", "--", ".gitignore", "source.txt")
        release.git(self.root, "commit", "-m", "Synthetic source fixture")
        self.source = release.git(self.root, "rev-parse", "HEAD")
        self.cask = self.root / release.CASK_PATH
        self.text = 'cask "synthetic-fixture" do\nend\n'

    def generate_cask(self):
        self.cask.parent.mkdir()
        self.cask.write_text(self.text)

    def test_only_generated_cask_can_be_committed_and_source_stays_valid(self):
        self.assertEqual(release.check_checkout(self.root), self.source)
        self.generate_cask()
        self.assertEqual(release.check_checkout(self.root, self.source, self.text), self.source)
        release.git(self.root, "add", "--", release.CASK_PATH)
        release.git(self.root, "commit", "--only", "-m", "Synthetic cask fixture", "--", release.CASK_PATH)
        head = release.check_checkout(self.root, self.source, self.text)
        self.assertNotEqual(head, self.source)
        self.assertEqual(release.git(self.root, "diff", "--name-only", self.source, head), release.CASK_PATH)
        self.assertEqual(release.git(self.root, "status", "--porcelain"), "")

    def test_untracked_staged_and_committed_source_changes_are_rejected(self):
        self.generate_cask()
        extra = self.root / "new-source.txt"
        extra.write_text("unrelated changes\n")
        with self.assertRaisesRegex(ValueError, "clean checkout"):
            release.check_checkout(self.root, self.source, self.text)
        release.git(self.root, "add", "--", "new-source.txt")
        with self.assertRaisesRegex(ValueError, "clean checkout"):
            release.check_checkout(self.root, self.source, self.text)
        release.git(self.root, "commit", "-m", "Synthetic unrelated source fixture")
        with self.assertRaisesRegex(ValueError, "source changed"):
            release.check_checkout(self.root, self.source, self.text)


if __name__ == "__main__":
    unittest.main()
