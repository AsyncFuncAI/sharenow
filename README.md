<p align="center">
  <img src="assets/cube-banner.jpg" alt="sharenow" width="100%">
</p>

<h1 align="center">sharenow</h1>

<p align="center">
  <em>Hosting for the things your agent makes.</em>
</p>

<p align="center">
  A site, a document, a folder of work. One command, and it is live in seconds at <code>sharenow.today</code>.
</p>

---

There is a moment, right after an agent finishes something, where the work has
nowhere to go. sharenow is the place it goes. Tell the agent to publish, and a
file, a folder, an app, or a report becomes a URL someone can open. Tell it to
keep something private, and that work persists in a Drive across sessions and
tools, shared only with whom you choose.

No console is required for the first publish. sharenow is a skill: a small set
of scripts an agent reads once and then drives on its own. A first-party browser
page appears only when the user chooses to connect an account.

**A full agent workspace, one install.**

- **Sites.** Publish HTML, apps, documents, images, PDFs, and video to a live URL
  at `{slug}.sharenow.today`, or a domain of your own. Three steps underneath,
  one command on the surface.
- **Drives.** Hold private agent files in cloud folders that outlast a single
  conversation: context, memory, plans, research, assets. Hand them to another
  agent with a scoped token, never a public link.
- **Channels.** Give several agents one claimed collaboration room with messages,
  scoped invites, and shared tasks.
- **Fullstack.** Start from a reviewed loop app or bring one explicit project
  folder. Remotely validate its exact bytes before approval, then deploy HTTP
  routes, managed data, private files, queues, schedules, and write-only secrets.
- **Codegraph.** Map an explicit public GitHub repository and query its code
  relationships without uploading the current working directory.

The skill carries seven reviewed helpers. `publish.sh`, `drive.sh`, and
`account.sh` cover Sites, storage, account tools, and capability discovery.
`channel.sh`, `fullstack.sh`, and `kb.sh` cover the All Access missions with
dry-runs or content-bound approval gates. `version.sh` checks and updates the
single canonical installation from the pinned GitHub source.

## Install

### Why security scanners may warn

Publishing skills can look powerful to automated scanners because their job is
to read local files and upload them. This package contains seven shell helpers,
all shown below. They send only the explicit files or metadata each action
requires to the fixed first-party origin `https://sharenow.today`; they do not
execute downloaded content, inspect unrelated folders, or read SSH, cloud, or
shell-history files.
For Site publishing, that means only the exact files you approve.
Account connection happens on a first-party browser page, so an email code or
API key never needs to be pasted into an agent chat.

The publish helper automatically excludes Git metadata, sharenow private state,
and `node_modules`. It fails closed when a target contains `.env` or a common
private-key file type. Codegraph accepts only a public GitHub URL. Fullstack
scans one explicit folder, remotely validates staged bytes without provisioning,
then requires a separate approval and mode-600 secret file.
Channel credentials remain in mode-600 local state and are not printed.

You can verify every installed byte against the signed-in-independent manifest
at [sharenow.today/.well-known/sharenow-skill.json](https://sharenow.today/.well-known/sharenow-skill.json).
One skill, the same seven scripts, wherever your local agent runs. Re-run the
same command later to update it in place.

**Universal (recommended).** Use the command for the agent you are running:

```bash
# Claude Code
npx skills add AsyncFuncAI/sharenow --skill sharenow -g --agent claude-code -y

# Codex
npx skills add AsyncFuncAI/sharenow --skill sharenow -g --agent codex -y

# Cursor
npx skills add AsyncFuncAI/sharenow --skill sharenow -g --agent cursor -y
```

For another runtime, replace the value after `--agent` with its skills agent id.
Targeting the current agent avoids warnings from unrelated runtimes. Drop `-g`
for a project-local, repo-pinned install.

The installer supports Codex, Claude Code, Cursor, OpenCode, and other common
local-agent skill folders. If your agent does not support local shell tools,
such as a browser-only chat, ask it to use sharenow's public HTTP API instead.
It can publish as long as it can call `curl` to an external service.

After setup, try one of these directly in your agent:

- `Publish this website to sharenow.`
- `Turn this result into a simple page and publish it to sharenow.`
- `Summarize this session as a shareable page and publish it to sharenow.`

Manual agent-specific layouts are kept in this repository for maintainers and
troubleshooting, but they are not a second install path for normal users.

## What is in the package

```
sharenow/
├── SKILL.md            the agent-facing skill manifest
├── AGENTS.md           the operating guide for the agent
├── assets/logo.svg
├── templates/loop-crm reviewed lead-intake agent loop starter
└── scripts/
    ├── publish.sh      publish and update Sites (create, upload, finalize)
    ├── drive.sh        private Drive storage and scoped-token sharing
    ├── account.sh      browser connection, capabilities, analytics, and account tools
    ├── channel.sh      claimed collaboration with private local sessions
    ├── fullstack.sh    exact-folder validation, approval, and app deployment
    ├── kb.sh           public-GitHub Codegraph sessions and queries
    ├── version.sh      pinned-source drift checks and verified updates
    └── lib/http.sh     shared response handling
```

Every other install path in this repo (`skills/`, `hermes/`, the plugin
manifests) is generated from `sharenow/`. That directory is the single source of
truth.

Historical advanced-script prototypes remain under `extras/advanced-scripts/`
for regression coverage. The installed helpers are the smaller reviewed
implementations under the canonical `sharenow/` directory.

## Layout

| Path | Surface |
| --- | --- |
| `sharenow/` | Canonical skill (edit here) |
| `skills/sharenow/` | `npx skills add` layout |
| `hermes/productivity/sharenow/` | Hermes layout |
| `.codex-plugin/plugin.json` | Codex manifest |
| `.cursor-plugin/plugin.json` | Cursor manifest |

## For maintainers

The skill lives once, in `sharenow/`. Edit there, regenerate the per-agent
layouts, and verify before pushing:

```bash
scripts/build-layouts.sh        # regenerate skills/ + hermes/; sync the logo into
                                #   the manifest dirs (the plugin JSON is hand-authored)
scripts/verify-package.sh       # gate: paths, layout sync, lint, exec bits,
                                #       brand, manifest JSON, install-cmd consistency
```

`build-layouts.sh --check` fails the moment a generated layout drifts from the
canonical source, so the copies cannot quietly fall out of step.

## License

MIT. See [LICENSE](./LICENSE).
