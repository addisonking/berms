#!/usr/bin/env python3
"""Exercise build stamping against temporary repositories and real worktrees."""

import datetime
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


GENERATOR = pathlib.Path(__file__).with_name("write-build-identity.py")


class BuildIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="berms-build-identity-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.output = self.root / "Berms.app" / "BuildIdentity.plist"
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Build Identity Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", str(self.root / "no-hooks"))
        (self.repo / "source.txt").write_text("initial\n")
        self.git("add", ".")
        self.git("commit", "-m", "initial")

    def git(self, *args, source=None):
        return subprocess.check_output(
            ["git", "-C", str(source or self.repo), *args],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()

    def stamp(self, source=None):
        subprocess.run(
            [sys.executable, str(GENERATOR), str(source or self.repo), str(self.output)],
            check=True, stdout=subprocess.DEVNULL,
        )
        return plistlib.loads(self.output.read_bytes())

    def test_clean_and_rebuilt_checkout(self):
        first = self.stamp()
        self.assertEqual(first["commit"], self.git("rev-parse", "HEAD"))
        self.assertFalse(first["hasLocalChanges"])
        self.assertIsInstance(first["builtAt"], datetime.datetime)
        self.assertEqual(first["worktreeName"], "repo")
        self.assertFalse(first["isLinkedWorktree"])
        second = self.stamp()
        self.assertEqual(second["commit"], first["commit"])
        self.assertGreaterEqual(second["builtAt"], first["builtAt"])

    def test_staged_unstaged_and_untracked_changes(self):
        commit = self.git("rev-parse", "HEAD")
        (self.repo / "source.txt").write_text("changed\n")
        self.assertTrue(self.stamp()["hasLocalChanges"])
        self.git("add", ".")
        self.assertTrue(self.stamp()["hasLocalChanges"])
        self.git("commit", "-m", "change")
        updated = self.stamp()
        self.assertFalse(updated["hasLocalChanges"])
        self.assertNotEqual(updated["commit"], commit)
        (self.repo / "new.txt").write_text("untracked\n")
        self.assertTrue(self.stamp()["hasLocalChanges"])

    def test_worktree_uses_its_head_and_changes_not_main(self):
        worktree = self.root / "feature worktree"
        self.git("worktree", "add", "-b", "feature", str(worktree))
        (worktree / "source.txt").write_text("feature\n")
        self.git("commit", "-am", "feature", source=worktree)
        identity = self.stamp(worktree)
        self.assertEqual(identity["worktreeName"], "feature worktree")
        self.assertTrue(identity["isLinkedWorktree"])
        self.assertEqual(identity["commit"], self.git("rev-parse", "HEAD", source=worktree))
        self.assertNotEqual(identity["commit"], self.git("rev-parse", "main"))
        self.assertFalse(identity["hasLocalChanges"])
        (self.repo / "source.txt").write_text("main local edit\n")
        self.assertFalse(self.stamp(worktree)["hasLocalChanges"])
        (worktree / "untracked.txt").write_text("local\n")
        self.assertTrue(self.stamp(worktree)["hasLocalChanges"])

    def test_detached_worktree_and_subdirectory_identify_worktree_root(self):
        worktree = self.root / "detached worktree"
        self.git("worktree", "add", "--detach", str(worktree))
        nested = worktree / "nested"
        nested.mkdir()
        identity = self.stamp(nested)
        self.assertEqual(identity["worktreeName"], "detached worktree")
        self.assertTrue(identity["isLinkedWorktree"])
        self.assertEqual(identity["commit"], self.git("rev-parse", "HEAD", source=worktree))

        moved = self.root / "renamed worktree"
        self.git("worktree", "move", str(worktree), str(moved))
        self.assertEqual(self.stamp(moved)["worktreeName"], "renamed worktree")

    def test_shallow_detached_checkout(self):
        clone = self.root / "shallow"
        subprocess.run(
            ["git", "clone", "--depth=1", self.repo.as_uri(), str(clone)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.git("checkout", "--detach", source=clone)
        identity = self.stamp(clone)
        self.assertEqual(identity["commit"], self.git("rev-parse", "HEAD"))
        self.assertEqual(identity["worktreeName"], "shallow")
        self.assertFalse(identity["isLinkedWorktree"])

    def test_squash_merge_stamps_new_main_commit(self):
        self.git("checkout", "-b", "feature")
        (self.repo / "source.txt").write_text("feature\n")
        self.git("commit", "-am", "feature")
        feature = self.stamp()["commit"]
        self.git("checkout", "main")
        self.git("merge", "--squash", "feature")
        self.git("commit", "-m", "squash feature")
        merged = self.stamp()
        self.assertNotEqual(merged["commit"], feature)
        self.assertEqual(merged["commit"], self.git("rev-parse", "main"))
        self.assertFalse(merged["hasLocalChanges"])

    def test_missing_git_fails_instead_of_claiming_a_commit(self):
        archive = self.root / "source archive"
        archive.mkdir()
        result = subprocess.run(
            [sys.executable, str(GENERATOR), str(archive), str(self.output)],
            capture_output=True, text=True,
            env={**os.environ, "GIT_CEILING_DIRECTORIES": str(self.root)},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires a Git checkout", result.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
