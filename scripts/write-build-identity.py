#!/usr/bin/env python3
"""Embed the actual checkout identity in the built app, including Git worktrees."""

import datetime
import pathlib
import plistlib
import subprocess
import sys


def git(source, *args):
    return subprocess.check_output(
        ["git", "-C", str(source), *args], text=True
    ).strip()


def write_identity(source, output):
    # Never use main/origin/main here: they may describe different source code.
    commit = git(source, "rev-parse", "--verify", "HEAD")
    local_changes = bool(git(source, "status", "--porcelain", "--untracked-files=normal"))
    worktree = pathlib.Path(git(source, "rev-parse", "--show-toplevel"))
    git_dir = pathlib.Path(git(source, "rev-parse", "--absolute-git-dir")).resolve()
    common_dir = pathlib.Path(git(source, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    identity = {
        "commit": commit,
        "hasLocalChanges": local_changes,
        "builtAt": datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
        "worktreeName": worktree.name,
        "isLinkedWorktree": git_dir != common_dir,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(plistlib.dumps(identity))
    print(f"Build identity: {commit[:12]}{' + local changes' if local_changes else ''}")


if __name__ == "__main__":
    try:
        write_identity(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    except subprocess.CalledProcessError:
        sys.exit("error: Build identity requires a Git checkout with a commit. Build from a clone or worktree.")
