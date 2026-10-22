#!/usr/bin/env python3
"""Adds a release to appcast.xml, the feed the app's Sparkle updater reads.

The item points at the release's zip on GitHub, carries the EdDSA signature
sign_update made for it, and embeds the release notes as HTML. A beta goes
on the "beta" channel, which only apps with "Check for Beta Versions" on
look at.

    release-appcast.py appcast.xml --repo owner/name --tag v1.4.0 --build 57 \\
        --enclosure 'sparkle:edSignature="…" length="…"' \\
        --minimum-system 27.0 --notes notes.html

Edits the file in place; refuses a tag that is already in it.
"""

import argparse
import html
import re
import sys
from email.utils import formatdate

TAG = re.compile(r"^v(\d+\.\d+\.\d+(-beta\.\d+)?)$")
ENCLOSURE = re.compile(r'^sparkle:edSignature="([A-Za-z0-9+/=]+)" length="(\d+)"$')


def fail(message):
    print(f"::error::{message}", file=sys.stderr)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("appcast")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--enclosure", required=True, help="sign_update's output for the zip")
    parser.add_argument("--minimum-system", required=True)
    parser.add_argument("--notes", required=True, help="release notes as an HTML file")
    args = parser.parse_args()

    tag = TAG.match(args.tag)
    enclosure = ENCLOSURE.match(args.enclosure.strip())
    if not tag:
        fail(f"{args.tag!r} is not a release tag")
    if not enclosure:
        fail(f"unexpected sign_update output: {args.enclosure!r}")
    version, beta = tag.group(1), tag.group(2)
    signature, length = enclosure.groups()

    with open(args.appcast, encoding="utf-8") as f:
        appcast = f.read()
    url = f"https://github.com/{args.repo}/releases/download/{args.tag}/ldap-studio-{args.tag}.zip"
    if url in appcast:
        fail(f"{args.tag} is already in {args.appcast}")

    with open(args.notes, encoding="utf-8") as f:
        notes = f.read().replace("]]>", "]]]]><![CDATA[>")

    channel = "\n            <sparkle:channel>beta</sparkle:channel>" if beta else ""
    item = f"""        <item>
            <title>LDAP Studio {version}</title>
            <pubDate>{formatdate(usegmt=True)}</pubDate>
            <sparkle:version>{html.escape(args.build)}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>{channel}
            <sparkle:minimumSystemVersion>{html.escape(args.minimum_system)}</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>https://github.com/{args.repo}/releases/tag/{args.tag}</sparkle:fullReleaseNotesLink>
            <description><![CDATA[{notes}]]></description>
            <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
        </item>
"""
    # Newest first, straight after the channel's own elements.
    first = appcast.find("        <item>")
    at = first if first != -1 else appcast.find("    </channel>")
    if at == -1:
        fail(f"no <channel> in {args.appcast}")
    with open(args.appcast, "w", encoding="utf-8") as f:
        f.write(appcast[:at] + item + appcast[at:])


if __name__ == "__main__":
    main()
