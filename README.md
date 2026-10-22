# Ldap Studio

🔍 A native macOS LDAP client for browsing, searching, and editing LDAP directories.

## Screenshots

![Browsing a directory](images/app.png)

![Creating a new connection](images/new_conn.png)

![Directory tree and attribute editor](images/tree.png)

## Why I Made This

I use LDAP at [CBPF](https://cbpf.br), the research center I work at. The only real LDAP client available was LDAP Admin for Windows, which hasn't been updated in a long time and is Windows-only, meaning I needed a Windows virtual machine running just to open it. So I built my own, native to macOS.

> ⚠️ I also wanted to learn Swift and C. I'm still learning both, so this app was built with the help of AI.

## Installation / Updating

1. Download `ldap-studio-vx.x.x.dmg` from the latest release on the [Releases page](https://github.com/mSarheed/ldap-studio/releases).
2. Open it and drag `ldap-studio.app` to your `/Applications` folder.

Releases are signed with a Developer ID and notarized by Apple, so macOS opens them after its usual "downloaded from the internet" confirmation. Each release also has a `.zip` of the same app and a `SHA256SUMS.txt`, and every file can be traced back to the workflow run that built it with `gh attestation verify <file> -R mSarheed/ldap-studio`.

### Updating

LDAP Studio looks for a new version once a day, and whenever you choose **LDAP Studio → Check for Updates…**. When there is one, it shows what's new and installs it for you, then relaunches. Updates come through [Sparkle](https://sparkle-project.org), which only installs a download signed with the project's key.

### Betas

Betas of the next version are published as pre-releases (`vx.x.x-beta.n`). Turn on **LDAP Studio → Check for Beta Versions** to be offered them as well as stable releases; it starts on in a beta build. When the stable release a beta led up to comes out, it's offered to beta users too, so turning betas off again lands you back on stable.

## Features

- Save, edit, and organize multiple LDAP connections
- Import/export connections as JSON (with an optional, obscured password) or from LDAP Admin's `.lcf` format
- Directory tree loaded on demand, so it stays fast on directories of any size (Active Directory included): each branch is read when you expand it, with paged searches that never hit the server's size limit
- Quick search across the whole directory, and real LDAP filter (RFC 4515) advanced search with progress and cancel
- Add, edit, view, and delete attributes, including binary values
- View and set photos (`jpegPhoto`), auto-resized and center-cropped to 300×300
- Set passwords (`userPassword`) with client-side hashing (PBKDF2-SHA512 by default, plus Unix/MD5/SHA-256/SHA-512 Crypt, MD5, SHA1, SMD5, and SSHA for compatibility); the plaintext is never stored or sent as-is
- Move, copy, create, and delete entries anywhere in the tree — whole branches included, counted first, with progress and cancel
- Import and export LDIF files
- Schema browser: object classes and attributes, with full superior-class inheritance resolved
- Autocomplete for attribute names and object classes when adding attributes or creating entries, driven by the server's own schema
- Native macOS menu bar integration for every major action
- A read-only MCP server, off by default, so AI agents (Claude Code, Codex, Cursor, VS Code…) can search and read the directories you choose

## Connecting AI Agents (MCP)

LDAP Studio can let AI agents read your directories through the [Model Context Protocol](https://modelcontextprotocol.io). It's off until you turn it on:

1. Open **LDAP Studio → Settings… (⌘,) → MCP Server** and turn on **Let AI agents read your directories**.
2. Under **Shared Directories**, turn on each connection agents may read. You can also do this in a connection's editor.
3. Under **Connect an Agent**, pick your agent and click **Copy Setup**. For Claude Code that's a command to paste into Terminal; for Codex, Cursor, VS Code and Gemini CLI it's the config to add. Claude Desktop and other apps that can only start local commands go through [`mcp-remote`](https://www.npmjs.com/package/mcp-remote). Any other agent that supports MCP over HTTP works with the server URL (`http://127.0.0.1:47389/mcp`) and the header `Authorization: Bearer <token>`.

LDAP Studio has to be running for agents to connect. Agents get six tools: `list_connections`, `get_server_info`, `search`, `get_entry`, `list_children` and `get_schema`.

**It's read-only.** Every tool is a search or a read, so an agent can't add, change, rename or delete anything, even through a connection whose account could. The MCP code reaches directories only through a wrapper that offers reads, so there's no path from it to the app's write functions.

**What agents never see:**

- Connections you haven't shared.
- Connection passwords. They stay in your Keychain.
- Attributes that hold secrets, such as `userPassword`, `unicodePwd`, LAPS passwords, BitLocker recovery keys, Kerberos keys, Samba hashes and replication credentials in server configuration, plus any attributes you add under **Also hide**. These are left out of results, can't be requested, and can't appear in a search filter, so an agent can't guess a value one filter at a time. This also covers their aliases, OIDs and subtypes, and filters on their supertypes. Attribute names are checked against the server's schema. If LDAP Studio can't read the schema, filters can only test `objectClass`, and entries show only their `objectClass` values.
- Binary values. They're described by size only.

Results are capped in size, so a broad search can't flood an agent's context. Agents' reads show up in the Operation Log marked `[MCP]`.

**Who can connect:** the server listens on 127.0.0.1 only, so it can't be reached from another machine. Every request must carry a 256-bit access token, which is stored in your Keychain and can be regenerated in Settings. It also checks the `Host` and `Origin` headers, which blocks web pages from reaching it through DNS rebinding. Agents can read whatever each shared connection's bind account can read, so for the strongest guarantee, share a connection that binds as an account the directory only lets read.

## Testing Against a Large Directory

`scripts/test-server/run.sh start` runs a local OpenLDAP server (from the Homebrew `openldap` in the Brewfile) with about 150,000 entries, one OU with 76,000 direct children, a 30-level-deep branch, and an Active Directory-like 500-entry size limit. `scripts/test-server/check.sh` then exercises browsing, searching, branch operations and the MCP server against it. See the comments in `run.sh` for the accounts to bind as.

## Requirements

- macOS 27 (Golden Gate) or later
- Apple Silicon (arm64); there's currently no Intel build

## Releasing

Releases are built, signed, notarized and published by [`.github/workflows/release.yml`](.github/workflows/release.yml), from commits on `main`. Start one either way:

- **Push a tag.** `vX.Y.Z` is a stable release; `vX.Y.Z-beta.N` is a beta, published as a pre-release.
  ```bash
  git tag v1.4.0-beta.1 && git push origin v1.4.0-beta.1
  ```
- **Run the workflow** from **Actions → Release → Run workflow** on `main`, with a version such as `1.4.0` and a channel. A beta gets the next free `-beta.N`, and the tag is created when the release is published. **Dry run** does everything except publish, and keeps the DMG and ZIP as a workflow artifact, which is a good first run after setting up the secrets.

A release must be newer than the latest stable one. Its notes are generated from the pull requests merged since the previous release (for a stable release, since the previous stable one, so they cover its betas too); label a PR `skip-changelog` to leave it out. The app's version comes from the tag (`MARKETING_VERSION`), and its build number is the workflow's run number.

`scripts/release-build.sh` does the work: it archives the app, exports it signed with Developer ID and hardened runtime, checks it with `scripts/release-verify.sh` (every binary signed by the team with a secure timestamp, no debugging entitlement, nothing linked from outside the bundle), notarizes and staples the app, then builds, signs, notarizes and staples the DMG. It also runs locally with your own Developer ID identity; see the comments at the top for the notarization settings, or set `SKIP_NOTARIZATION=1` to stop after signing.

The ZIP is also the in-app update. The workflow signs it with the Sparkle key, and once the release is published, adds it to [`appcast.xml`](appcast.xml) on `main` (a beta on the `beta` channel) with `scripts/release-appcast.py`. That file is the feed installed apps check, so a release reaches them only once it's there.

### One-time setup

In **Settings → Environments**, create an environment named `release`. Under **Deployment branches and tags**, allow only the `main` branch and tags matching `v*`. Then add to it:

| Name | Kind | Value |
| --- | --- | --- |
| `APPLE_TEAM_ID` | variable | The 10-character Team ID of the Apple Developer account. |
| `SIGNING_P12_BASE64` | secret | The **Developer ID Application** certificate and its private key, exported from Keychain Access as a `.p12`, then base64-encoded (`base64 -i cert.p12 \| pbcopy`). |
| `SIGNING_P12_PASSWORD` | secret | The password set on that export. |
| `NOTARY_KEY_ID` | secret | The Key ID of an App Store Connect API key (Users and Access → Integrations → Team Keys) with the Developer role. |
| `NOTARY_ISSUER_ID` | secret | The Issuer ID shown on that page. |
| `NOTARY_PRIVATE_KEY` | secret | The contents of that key's `.p8` file. |
| `SPARKLE_PRIVATE_KEY` | secret | The private key updates are signed with, exported with Sparkle's `generate_keys --account ldap-studio -x <file>`. Its public half is `SUPublicEDKey` in `ldap-studio/Info.plist`. Keep a backup of it. |

## License

[MIT](LICENSE)
