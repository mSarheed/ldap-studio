#!/usr/bin/env python3
"""Works out which release a Release workflow run makes, or refuses it.

A release is a tag: vX.Y.Z is stable, vX.Y.Z-beta.N is a beta (a GitHub
pre-release). A tag push names it directly; a manual run gives X.Y.Z and a
channel, and a beta gets the next free N for that version.

    release-version.py --tag v1.4.0-beta.1
    release-version.py --version 1.4.0 --channel beta

Prints key=value lines (for $GITHUB_OUTPUT): tag, version, channel,
prerelease, notes_start (the tag GitHub's generated notes start after; empty
for the first release). Run from the repo, with tags fetched.
"""

import argparse
import re
import subprocess
import sys

TAG = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-beta\.([1-9]\d*))?$")
BASE = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")


def key(tag):
    """Semver order: 1.4.0-beta.1 < 1.4.0-beta.2 < 1.4.0 < 1.4.1-beta.1."""
    m = TAG.match(tag)
    major, minor, patch, beta = m.groups()
    # A stable release sorts after every beta of the same version.
    return (int(major), int(minor), int(patch), int(beta) if beta else float("inf"))


def tags():
    out = subprocess.run(["git", "tag", "--list", "v*"], capture_output=True, text=True, check=True)
    return sorted((t for t in out.stdout.split() if TAG.match(t)), key=key)


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def resolve(existing, tag=None, version=None, channel=None):
    if tag is None:
        if not BASE.match(version or ""):
            fail(f"Version must look like 1.4.0, not {version!r}")
        if channel == "stable":
            tag = f"v{version}"
        elif channel == "beta":
            betas = [key(t)[3] for t in existing if t.startswith(f"v{version}-beta.")]
            tag = f"v{version}-beta.{max(betas, default=0) + 1}"
        else:
            fail(f"Channel must be beta or stable, not {channel!r}")
    elif not TAG.match(tag):
        fail(f"{tag} is not a release tag: use vX.Y.Z or vX.Y.Z-beta.N")

    if tag in existing and version is not None:
        fail(f"{tag} already exists")
    others = [t for t in existing if t != tag]
    stables = [t for t in others if key(t)[3] == float("inf")]
    latest_stable = stables[-1] if stables else None
    # Nothing may go out below what stable users already have: they would never
    # see it, and a beta user would be offered a "downgrade".
    if latest_stable and key(tag)[:3] <= key(latest_stable)[:3]:
        fail(f"{tag} is not newer than the latest stable release, {latest_stable}")

    beta = key(tag)[3] != float("inf")
    if beta:
        # Notes since the release just before this one, beta or stable.
        earlier = [t for t in others if key(t) < key(tag)]
        notes_start = earlier[-1] if earlier else ""
    else:
        # A stable release's notes cover everything since the last stable,
        # betas included: most of its readers never ran them.
        notes_start = latest_stable or ""

    return {
        "tag": tag,
        "version": tag[1:],
        "channel": "beta" if beta else "stable",
        "prerelease": str(beta).lower(),
        "notes_start": notes_start,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag")
    parser.add_argument("--version")
    parser.add_argument("--channel")
    args = parser.parse_args()
    if bool(args.tag) == bool(args.version):
        parser.error("give either --tag, or --version and --channel")
    result = resolve(tags(), tag=args.tag, version=args.version, channel=args.channel)
    for name, value in result.items():
        print(f"{name}={value}")


if __name__ == "__main__":
    main()
