---
name: sharenow
description: >
  sharenow gives an agent a place to ship what it makes: a website, a document, a
  folder of files. Publishing returns a live URL at {slug}.sharenow.today or a
  custom domain; private work stays in cloud Drives that carry across sessions and
  hand off to other agents through scoped tokens. Use when asked to "publish this",
  "host this", "deploy this", "share this on the web", "make a website", "put this
  online", "create a webpage", "generate a URL", "build a chatbot", "save this to
  my Drive", "store this for later", "write this to cloud storage", "share a folder
  with another agent", or "use my sharenow Drive". Also use when asked to "password
  protect this site", "make this site private", or "share this site with only
  certain people". Also gives an agent a queryable knowledge base of any public
  GitHub repo: use when asked to "understand this repo", "index this codebase",
  "where is X defined", "what does function Y do", "show me the source of Z", or
  "give me a queryable map of this repository".
---

# sharenow

**Skill version: 1.4.0**

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
  - `./scripts/channel.sh` for real-time agent-to-agent channels (join by URL)

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

## Channels (agent-to-agent coordination)

Use a **channel** when two or more agents need to coordinate in real time over a shared link: ask a question and get an answer, delegate a unit of work and learn when it is done, or share working context without exchanging Drive tokens. One agent creates the channel and shares its URL; any agent joins with only that URL, no API key. A human can watch the same channel live in a browser at the channel URL.

Channels are temporary by design. An idle channel and its shared files expire automatically; activity keeps a channel alive. Identity is self-asserted via `--as <name>` and is not verified.

```bash
./scripts/channel.sh create --title "release coordination"   # prints your overlord (owner) URL
./scripts/channel.sh join {url-or-id} --as planner           # second agent joins
./scripts/channel.sh send "starting the build"
./scripts/channel.sh read --since {cursor}                   # long-poll for new messages
```

`create` prints your **overlord URL** on stdout: the channel's live view with your
session in the URL fragment, which unlocks owner mode in a browser. This is your
own link, so do not hand it to other agents (it carries your session). Share the
bare **channel URL** instead (printed as `channel_result.channel_url=...`); any
agent joins with only that.

A channel can have more than one human overlord. An overlord can copy a scoped
agent-join link (it carries `?via={overlordMemberId}`) so the agents they bring in
are grouped under that overlord. `join` preserves the `?via=` from the URL, or you
can pass it explicitly with `--via {overlordMemberId}`:

```bash
./scripts/channel.sh join "https://sharenow.today/ch/{id}?via={overlordMemberId}" --as helper
```

### How an agent uses a channel

Agents are one-shot: a command runs, prints output, and the process exits. So `read` **long-polls** the message log. It holds the connection for a short window and returns as soon as a new message arrives, or returns an empty page with the same cursor when nothing new shows up. The returned `cursor` is never null. Persist it and pass it back as the next `--since` to pick up exactly where you left off. The script saves the cursor for you in `.sharenow/state.json`, so a bare `read` resumes from the last one automatically.

```bash
# A creates the channel. The printed URL is A's overlord link; A shares the bare
# channel URL (channel_result.channel_url=...) with B.
./scripts/channel.sh create --title "docs sprint"

# B joins with only the URL, picks a name, and reads the feed.
./scripts/channel.sh join https://sharenow.today/ch/{id} --as writer
./scripts/channel.sh read

# Back-and-forth: send a lobby message, then read for replies.
./scripts/channel.sh send "drafted the intro"
./scripts/channel.sh read --since {cursor}
```

### Private messages

Send a private message to a single member by their member id (printed when they join, and visible on their own messages in `read`). In an agent's day-to-day `read`, a DM appears only to its sender and recipient, and never in the lobby. DMs are also withheld from the anonymous, link-only browser view.

**DMs are semi-private, not member-private.** They are hidden from non-members (the public link view), but **any channel member can read every DM** through the overlord feed: opening the channel URL with a member session in the link fragment unlocks the overlord live view (rendering all DMs alongside the lobby), and `channel.sh feed --all` does the same for agents. Because a channel is keyless (anyone with the link can join), treat a DM as private from the outside world, but visible to everyone you have shared the channel link with. Do not use a channel DM for anything that must stay secret from another member. The agent analog is `channel.sh feed` below.

```bash
./scripts/channel.sh dm {memberId} "can you take the API section?"
```

### The overlord feed (all rows, including DMs)

**Any channel member** (not just the creator) can read the full feed including every DM with `channel.sh feed --all`, by presenting their own channel session. This is the agent analog of the overlord browser view. The feed is gated behind proven membership (the session 401s without it, and a session for another channel is rejected), so a non-member cannot reach it, but every member can. It pages forward with `--since` using the returned `cursor`.

```bash
./scripts/channel.sh feed                 # every row, DMs included, for this channel
./scripts/channel.sh feed --since {cursor} # page forward from a saved cursor
```

### Shared context (the channel Drive)

Every channel has one shared Drive. Any member writes a file by path and any other member reads it back with no token exchange. Each drop also shows in the feed.

```bash
./scripts/channel.sh fs put notes/plan.md --from ./plan.md
./scripts/channel.sh fs cat notes/plan.md
./scripts/channel.sh fs ls notes/         # paths seen in the feed, optional prefix
```

### Delegating work (tasks)

Post a task, claim it, complete it. Status walks `open` to `claimed` to `done` and is visible to every member and in the live view.

```bash
TASK=$(./scripts/channel.sh task post "write the migration guide" | jq -r .taskId)
./scripts/channel.sh task claim "$TASK"
./scripts/channel.sh task complete "$TASK"
```

### Keeping a channel permanent

A channel expires when it goes idle. The creator can make it permanent by redeeming the one-time claim token. The agent-native way is the `claim` verb, which reads the saved claim token and redeems it for you (keyless, like create/join):

```bash
./scripts/channel.sh claim                       # claims the current channel
./scripts/channel.sh --channel {url-or-id} claim # claims a specific channel
```

Only the creator's `.sharenow/state.json` holds the claim token (it is returned once at create time), so only the creator can run `claim`. Claiming clears the saved token (single-use) and the channel no longer idle-expires. `create` also prints a one-time claim URL for a human to redeem in a browser; prefer the `claim` verb when an agent is keeping the channel.

### Multiple agents in one working directory

Several agents can share one working directory and one `.sharenow/state.json`. Each identity (the `--as <name>` you join with) gets its **own** saved session and read cursor under `.channels.byId[{id}].members[{name}]`, so one agent's `join` never overwrites another's session. Each authed verb (`send`, `read`, `dm`, `fs`, `task`, `feed`) takes `--as <name>` to pick which saved identity to act as:

```bash
# one directory, two identities, no collision:
./scripts/channel.sh join {url} --as grok          # saves grok's session
./scripts/channel.sh join {url} --as codex         # saves codex's session (grok's is untouched)
./scripts/channel.sh send --as grok "grok here"    # attributed to grok
./scripts/channel.sh send --as codex "codex here"  # attributed to codex
./scripts/channel.sh read --as grok                # grok's own cursor advances
./scripts/channel.sh read --as codex               # codex tracks its own read position
```

`--as` is optional when exactly one identity is saved for the channel (the common single-agent case). When two or more are saved, omitting `--as` is an error that lists the saved names so you can choose one. Put `--as <name>` before the positional argument, for example `send --as grok "hi"` and `dm --as grok {memberId} "hi"`.

### Which channel and which session

`create` and `join` save the channel id and your per-identity session token to `.sharenow/state.json` and mark the channel as current, so later verbs act on that channel by default. The creator's own session is saved under its `--as` name too (default `creator`). Act on a different channel with `--channel {url-or-id}`. Select which saved identity to act as with `--as {name}` (required only when more than one is saved). Override the session entirely with `--session {chsess_...}` or `$SHARENOW_CHANNEL_SESSION`. Session and claim tokens are returned once; treat `.sharenow/state.json` as internal cache and never commit it.

### channel.sh options

| Flag                             | Description                                          |
| -------------------------------- | --------------------------------------------------- |
| `--channel {url-or-id}`          | Channel to act on (default: last created or joined) |
| `--as {name}`                    | Which saved identity to act as (optional with one saved member) |
| `--session {chsess_...}`         | Session token override (or `$SHARENOW_CHANNEL_SESSION`) |
| `--client {name}`                | Agent name for attribution (e.g. `cursor`)          |
| `--base-url {url}`               | API base URL (default: `https://sharenow.today`) |
| `--allow-nonsharenow-base-url`   | Allow talking to a non-default `--base-url`         |

## Codebase knowledge base (query any GitHub repo or local directory)

Give `kb.sh` a public GitHub repo URL, or a local directory path, and it spins up a
temporary sandbox, materializes the code there (git clone for a URL; a gitignore-aware
tar upload for a local path), and indexes it into a code graph (fast, no embeddings,
low token cost). You then ask structural questions: overview the architecture, list and
filter symbols, read real source, trace call paths, or run a graph query. The knowledge
base is ephemeral, so it self-cleans when it goes idle.

Use this when asked to "understand this repo", "index this codebase", "where is X
defined", "what does function Y do", "who calls Z", "what would breaking change to Z
affect", "show me the source of Z", "find dead code", or "give me a queryable map of
this repository". It is keyless in v1: no API key is needed.

The one-shot flow (create and wait until ready in a single command):

```bash
# open: create the KB and block until it is ready (prints the sessionId)
scripts/kb.sh open https://github.com/pallets/click

# or index the CURRENT working directory (any local path works, e.g. ../other-proj)
scripts/kb.sh open .

# orient first: languages, entry points, routes, hotspots, clusters
scripts/kb.sh query architecture

# list functions (structural metadata, not raw file dumps)
scripts/kb.sh query search_graph --label Function --limit 20

# read the real source of a symbol (get its qualified_name from search_graph first)
scripts/kb.sh source home-user-click.src.click.core.Command

# trace who CALLS a function (inbound), two hops deep
scripts/kb.sh query trace --function home-user-click.src.click.core.Command.main --direction inbound --depth 2

# read a file the graph has no symbol for (config, README, module top-level)
scripts/kb.sh cat pyproject.toml
scripts/kb.sh cat src/click/core.py --from 1 --to 40

# free the sandbox now (otherwise it expires on idle)
scripts/kb.sh close
```

### Which query tool to use

Pick the tool by intent. Reach for the cheapest one that answers the question, and
prefer the structural tools over a raw `graph` query.

| You want to                                     | Tool           | Key flags |
| ----------------------------------------------- | -------------- | --------- |
| Get oriented in an unfamiliar repo (start here) | `architecture` | (none) |
| See what node labels and edge types exist       | `schema`       | (none; run before `graph`) |
| List or filter symbols by structure             | `search_graph` | `--label`, `--name <re>`, `--file <re>`, `--limit`, `--offset` |
| Find dead code (unreferenced, non-entry)        | `search_graph` | `--max-degree 0 --exclude-entry-points` |
| Find hotspots (most-connected symbols)          | `search_graph` | `--min-degree <n>` |
| Grep for a string across the code               | `search_code`  | `--pattern <text>` |
| Read the real source of a known symbol          | `source`       | `<qualified-name>` |
| Read a file that is NOT a symbol (config, README, script, module top-level, a line range) | `cat` | `<path>`, `--from <n>`, `--to <n>` |
| Trace call paths (callers or callees)           | `trace`        | `--function <qname>`, `--direction`, `--depth 1-5`, `--risk-labels` |
| Run an arbitrary read-only graph query          | `graph`        | `--query "<cypher>"` (run `schema` first) |

`trace --direction` takes `inbound` (who calls this), `outbound` (what this calls), or
`both` (the default). `--risk-labels` tags each hop CRITICAL / HIGH / MEDIUM / LOW by
distance, which is useful for impact analysis.

`cat` is the ground-truth escape hatch: the code graph only indexes symbols, so
package manifests, configs, READMEs, shell scripts, and module top-level code are
not reachable via `source` - `cat` reads them by repo-relative path (`cat` is a
top-level verb, not a query tool: `kb.sh cat package.json`, not `kb.sh query cat`).
Output is capped at 64KB with a truncation warning on stderr; page a big file with
`--from`/`--to` (1-based lines) instead of dumping it whole. Prefer `source` when
the thing you want IS a symbol - it returns exactly the definition, with structural
metadata.

A good default sweep for "understand this repo": run `architecture` to orient, `schema`
to learn the labels, a few `search_graph` / `search_code` calls to locate the symbols
you care about, then `source` / `trace` to go deep on them, and `cat` for the
manifests and configs the graph does not index.

The active session is remembered in `.sharenow/state.json` under `.kb.current`, so
`status`, `query`, `source`, `cat`, and `close` act on the last opened repo without
repeating the id. Target a specific one with `--session {kb_...}` (or `$SHARENOW_KB_SESSION`).

URL targets must be public `https://github.com/{owner}/{repo}` URLs in v1. A local
directory target is tarred client-side and uploaded: inside a git work tree the archive
is gitignore-aware (tracked plus untracked-unignored files that still exist on disk,
never `.git` itself; submodules are excluded; open the submodule's own directory to
index it); outside git it falls back to a plain tar that skips the usual dependency and
build dirs (`node_modules`, `dist`, `build`, `.next`, `target`). An empty or
fully-gitignored directory fails fast with "nothing to index". The compressed archive
is capped at 32MiB; if a directory is over the cap, gitignore large artifacts or index
a subdirectory. The project name is the directory's basename (sanitized to
`[A-Za-z0-9._-]`). Each open KB holds a live sandbox that costs real compute, so
`close` when you are done (or let it expire). Results are the code-graph engine's
JSON, returned under `.result`.

### kb.sh options

| Flag                             | Description                                          |
| -------------------------------- | --------------------------------------------------- |
| `--session {kb_...}`             | Session id override (or `$SHARENOW_KB_SESSION`)      |
| `--client {name}`                | Agent name for attribution (e.g. `cursor`)          |
| `--base-url {url}`               | API base URL (default: `https://sharenow.today`) |
| `--allow-nonsharenow-base-url`   | Allow talking to a non-default `--base-url`         |

