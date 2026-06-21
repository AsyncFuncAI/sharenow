---
name: sharenow
description: >
  sharenow lets agents publish websites and store private files in cloud
  Drives. Use Sites to publish HTML, documents, images, PDFs, videos, and
  static files to live URLs at {slug}.sharenow.today or custom domains. Use
  Drives as private cloud folders where agents can store files (documents,
  context, memory, plans, assets, media, research, code, and more), share them with
  other agents, and continue across sessions and tools. Use when asked to
  "publish this", "host this", "deploy this", "share this on the web", "make a
  website", "put this online", "create a webpage", "generate a URL", "build a
  chatbot", "save this to my Drive", "store this for later", "write this to
  cloud storage", "share a folder with another agent", or "use my sharenow
  Drive". Also use when asked to "password protect this site", "make this site
  private", or "share this site with only certain people".
---

# sharenow

**Skill version: 1.16.0-sharenow.1**

Two jobs, one skill. Ship a website to a live URL, or keep agent files in a private cloud Drive, from the same set of scripts.

- **Sites**: publish websites and files to live URLs at `{slug}.sharenow.today`.
- **Drives**: keep private agent files in cloud folders that persist across sessions and tools.

Every Site carries access control: public link (default), password, or invite-only restricted access.

To install or update (recommended): `npx skills add AsyncFuncAI/sharenow --skill sharenow -g`

For repo-pinned or project-local installs, run the same command without `-g`:
`npx skills add AsyncFuncAI/sharenow --skill sharenow`

## Current docs

**Before answering questions about sharenow capabilities, features, or workflows, read the current docs:**

→ **https://sharenow.today/docs**

Read the docs:

- at the first sharenow-related interaction in a conversation
- any time the user asks how to do something
- any time the user asks what is possible, supported, or recommended
- before telling the user a feature is unsupported

Topics that require current docs (do not rely on local skill text alone):

- Site access control (passwords and restricted access)
- Drives and Drive sharing
- custom domains
- Site Data
- public profiles
- proxy routes and service variables
- subdomain handles and links
- limits and quotas
- SPA routing
- owner Site search
- Site analytics
- error handling and remediation
- feature availability

**If docs and live API behavior disagree, trust the live API behavior.**

If the docs fetch fails or times out, continue with the local skill and live API or script output. Prefer live API behavior for active operations.

## Requirements

- Required binaries: `curl`, `file`, `jq`
- Optional environment variable: `$SHARENOW_API_KEY`
- Optional Drive token variable: `$SHARENOW_DRIVE_TOKEN`
- Optional credentials file: `~/.sharenow/credentials`
- Bundled helpers:
  - `./scripts/publish.sh` for publishing sites
  - `./scripts/drive.sh` for private Drive storage
  - `./scripts/account.sh` for everything else (Site Data, profiles, domains, handles, links, variables, analytics, keys)

## Create a site

```bash
./scripts/publish.sh {file-or-dir}
```

Outputs the live URL. Published sites are served at `https://{slug}.sharenow.today/`.

Under the hood this is a three-step flow: create or update, upload files, finalize. A site is not live until finalize succeeds.

Without an API key this creates an **anonymous site** that expires in 24 hours.
With a saved API key, the site is permanent.

**File structure:** For HTML sites, place `index.html` at the root of the directory you publish, not inside a subdirectory. The directory's contents become the site root. For example, publish `my-site/` where `my-site/index.html` exists, not a parent folder that contains `my-site/`.

You can also publish raw files without any HTML. A single file gets an auto-viewer (images, PDF, video, audio). Multiple files get an auto-generated directory listing with folder navigation and an image gallery.

## Update an existing site

```bash
./scripts/publish.sh {file-or-dir} --slug {slug}
```

The script auto-loads the `claimToken` from `.sharenow/state.json` when updating anonymous sites. Pass `--claim-token {token}` to override.

Authenticated updates require a saved API key.

Signed-in users also have public profiles. Agents can help users show or hide Sites on their profile and manage profile settings through the API documented at https://sharenow.today/docs#profile.

## Site access control

A Site uses one access mode at a time:

- **anyone_with_link** (default): anyone with the URL can view.
- **password**: visitors must enter a shared password.
- **restricted**: invite-only; only verified email addresses or email domains the owner allows can view.

Manage access with `GET`/`PATCH /api/v1/publish/{slug}/access` (passwords via the metadata endpoint). Restricted access requires a claimed Site. The PATCH replaces the full allowlists, so read, merge, then write. Before working with access control, read the current docs:

→ **https://sharenow.today/docs#access-control**

## Site Data from page JavaScript (same-origin)

A published Site can read and write its own structured records **directly from page JavaScript**, with no API key, by calling its **own origin**:

```
GET    /{slug}/.sharenow/data/{collection}
POST   /{slug}/.sharenow/data/{collection}
GET    /{slug}/.sharenow/data/{collection}/{recordId}
PATCH  /{slug}/.sharenow/data/{collection}/{recordId}
DELETE /{slug}/.sharenow/data/{collection}/{recordId}
```

Because the page calls its own origin (relative URLs like `/{slug}/.sharenow/data/todos`), **no CORS is involved**. This is the supported way to build a static app with live, cross-device storage: back the UI with these endpoints. Do **not** embed an account key in the page, and do **not** point page JavaScript at the owner API (`/api/v1/publishes/...`). That path is cross-origin from the site and carries no CORS headers, so the browser blocks it.

List is paginated: a create returns `{ id, data, createdAt, updatedAt }`, a list returns `{ records, nextCursor }`. Pass `?limit=N` (1 to 100, default 50) and `?cursor=<nextCursor>` to page; when `nextCursor` is `null` the collection is exhausted. Collection names must be lowercase, start with a letter, allow digits and underscores, max 64 chars.

Declare each collection in a published `.sharenow/data.json` manifest and set per-operation access. The v1 defaults are **public read + insert, owner-only update + delete**; override with an `access` block. Add `"closed": true` to reject any field not declared in `fields` (recommended for form input you want validated):

```json
{
  "collections": {
    "todos": {
      "closed": true,
      "fields": {
        "title": { "type": "string", "required": true, "maxLength": 200 },
        "done":  { "type": "boolean", "default": false }
      },
      "access": { "read": "public", "insert": "public", "update": "public", "delete": "public" }
    }
  }
}
```

Constraints: writes require a **claimed (account-owned) site**. Anonymous sites cannot take Site Data writes. Public write caps: 16 KB per record, 25,000 records per collection, 100,000 per site. An `owner`-level operation still needs the owner's key in the `Authorization` header, so reserve `owner` for trusted automation, not visitor JavaScript.

For server-side or agent-side record management with the account key, use the owner API (`account.sh site-data ...` / `/api/v1/publishes/{slug}/data/...`). Both APIs operate on the same records. Full reference:

→ **https://sharenow.today/docs#site-data**

## Use a Drive

Use a Drive when the user wants private cloud storage for agent files: documents, context, memory, plans, assets, media, research, code, and anything else that should persist without being published as a website.

Every signed-in account has a default Drive named `My Drive`.

```bash
./scripts/drive.sh default
./scripts/drive.sh ls My Drive
./scripts/drive.sh put My Drive notes/today.md --from ./notes/today.md
./scripts/drive.sh cat My Drive notes/today.md
./scripts/drive.sh share My Drive --perms write --prefix notes/ --ttl 7d
```

Use scoped Drive tokens for agent-to-agent handoff. If you receive a `sharenow_drive` share block, use its `token` as `Authorization: Bearer <token>` against `api_base`, respect `pathPrefix` when present, and preserve ETags on writes. A `pathPrefix` of `null` means full-Drive access. If the skill is available, prefer `./scripts/drive.sh`; otherwise call the listed API operations directly.

## Client attribution

Pass `--client` so sharenow can track reliability by agent:

```bash
./scripts/publish.sh {file-or-dir} --client cursor
```

This sends `X-ShareNow-Client: cursor/publish-sh` on publish API calls.
If omitted, the script sends a fallback value.

## API key storage

The publish script reads the API key from these sources (first match wins):

1. `--api-key {key}` flag (CI or scripting only; avoid in interactive use)
2. `$SHARENOW_API_KEY` environment variable
3. `~/.sharenow/credentials` file (recommended for agents)

To store a key, write it to the credentials file:

```bash
mkdir -p ~/.sharenow && echo "{API_KEY}" > ~/.sharenow/credentials && chmod 600 ~/.sharenow/credentials
```

**IMPORTANT**: After receiving an API key, save it immediately by running the command above yourself. Do not ask the user to run it manually. Avoid passing the key via CLI flags (e.g. `--api-key`) in interactive sessions; the credentials file is the preferred storage method.

Never commit credentials or local state files (`~/.sharenow/credentials`, `.sharenow/state.json`) to source control.

## Getting an API key

To upgrade from anonymous (24h) to permanent sites:

1. Ask the user for their email address.
2. Request a one-time sign-in code:

```bash
curl -sS https://sharenow.today/api/auth/agent/request-code \
  -H "content-type: application/json" \
  -d '{"email": "user@example.com"}'
```

3. Tell the user: "Check your inbox for a sign-in code from sharenow and paste it here."
4. Verify the code and get the API key:

```bash
curl -sS https://sharenow.today/api/auth/agent/verify-code \
  -H "content-type: application/json" \
  -d '{"email":"user@example.com","code":"ABCD-2345"}'
```

5. Save the returned `apiKey` yourself (do not ask the user to do this):

```bash
mkdir -p ~/.sharenow && echo "{API_KEY}" > ~/.sharenow/credentials && chmod 600 ~/.sharenow/credentials
```

## State file

After every site create or update, the script writes to `.sharenow/state.json` in the working directory:

```json
{
  "publishes": {
    "bright-canvas-a7k2": {
      "siteUrl": "https://bright-canvas-a7k2.sharenow.today/",
      "claimToken": "abc123",
      "claimUrl": "https://sharenow.today/claim?slug=bright-canvas-a7k2&token=abc123",
      "expiresAt": "2026-02-18T01:00:00.000Z"
    }
  }
}
```

Before creating or updating sites, you may check this file to find prior slugs.
Treat `.sharenow/state.json` as internal cache only.
Never present this local file path as a URL, and never use it as source of truth for auth mode, expiry, or claim URL.

## What to tell the user

For published sites:

- Always share the `siteUrl` from the current script run.
- Read and follow `publish_result.*` lines from script stderr to determine auth mode.
- When `publish_result.auth_mode=authenticated`: tell the user the site is **permanent** and saved to their account. No claim URL is needed.
- When `publish_result.auth_mode=anonymous`: tell the user the site **expires in 24 hours**. Share the claim URL (if `publish_result.claim_url` is non-empty and starts with `https://`) so they can keep it permanently. Warn that claim tokens are only returned once and cannot be recovered.
- Never tell the user to inspect `.sharenow/state.json` for claim URLs or auth status.

For Drives:

- Do not describe Drive files as public URLs.
- Tell the user Drive contents are private unless shared with a scoped token.
- When sharing access with another agent, prefer a scoped token with a narrow `pathPrefix` and short TTL.

## publish.sh options

| Flag                   | Description                                  |
| ---------------------- | -------------------------------------------- |
| `--slug {slug}`        | Update an existing site instead of creating |
| `--claim-token {token}`| Override claim token for anonymous updates    |
| `--title {text}`       | Viewer title (non-HTML sites)             |
| `--description {text}` | Viewer description                            |
| `--ttl {seconds}`      | Set expiry (authenticated only)               |
| `--client {name}`      | Agent name for attribution (e.g. `cursor`)    |
| `--base-url {url}`     | API base URL (default: `https://sharenow.today`)    |
| `--allow-nonsharenow-base-url` | Allow sending auth to non-default `--base-url` |
| `--api-key {key}`      | API key override (prefer credentials file)    |
| `--spa`                | Enable SPA routing (serve index.html for unknown paths) |
| `--from-drive {drv_...}` | Publish a Drive snapshot instead of local files |
| `--version {dv_...}`   | Drive version for `--from-drive` (default: current head) |

## Beyond publish.sh

For Drive operations, use `./scripts/drive.sh` or the Drive API. For broader account and Site management (Site Data, search, analytics, profiles, delete, metadata, access control, domains, subdomain handles, links, variables, proxy routes, duplication, and more), see the current docs:

→ **https://sharenow.today/docs**

## Full account operations

Beyond `publish.sh` (Sites) and `drive.sh` (Drives), `./scripts/account.sh` drives
every other sharenow capability with an account API key. All subcommands print
pretty JSON.

```bash
./scripts/account.sh sites                         # list your Sites
./scripts/account.sh search "<query>"              # search your Sites
./scripts/account.sh site-data ls <slug> <coll>    # Site Data records
./scripts/account.sh site-data create <slug> <coll> --json '{"...":"..."}'
./scripts/account.sh profile get                   # public profile
./scripts/account.sh profile username <name>
./scripts/account.sh profile add <slug>            # show a Site on your profile
./scripts/account.sh domains                       # custom domains
./scripts/account.sh domain add example.com
./scripts/account.sh handle create <handle>        # subdomain handle
./scripts/account.sh links                         # links
./scripts/account.sh variables                     # service variables (names only)
./scripts/account.sh variable set <name> --value <v>
./scripts/account.sh analytics [<slug>] --range 30d
./scripts/account.sh keys                          # list API keys
./scripts/account.sh keys create <name>            # returns the key ONCE
```

Custom-domain and handle DNS/TLS provisioning is deploy-time; sharenow stores and
exposes the mappings and verification status. Service-variable values are
write-only (the API never returns them). API keys created via `keys create` are
shown once; store them, do not log them.
