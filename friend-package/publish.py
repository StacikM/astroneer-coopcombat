"""Build the package and publish it as a new GitHub release. Your friend's updater picks it up automatically.

Usage:  python publish.py "what changed"
Needs the GitHub CLI (gh) logged in as the repo owner.
"""
import os
import subprocess
import sys

REPO = "StacikM/astroneer-coopcombat"
HERE = os.path.dirname(os.path.abspath(__file__))
notes = sys.argv[1] if len(sys.argv) > 1 else "Update"

subprocess.run([sys.executable, os.path.join(HERE, "build_package.py")], check=True)
version = open(os.path.join(HERE, "dist", "version.txt"), encoding="utf-8").read().strip()
subprocess.run(
    [
        "gh", "release", "create", "v" + version,
        os.path.join(HERE, "dist", "CoopCombat-update.zip"),
        os.path.join(HERE, "dist", "version.txt"),
        "--repo", REPO, "--title", version, "--notes", notes, "--latest",
    ],
    check=True,
)
print("published", version)
