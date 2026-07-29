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

**Two capabilities, one install.**

- **Sites.** Publish HTML, apps, documents, images, PDFs, and video to a live URL
  at `{slug}.sharenow.today`, or a domain of your own. Three steps underneath,
  one command on the surface.
- **Drives.** Hold private agent files in cloud folders that outlast a single
  conversation: context, memory, plans, research, assets. Hand them to another
  agent with a scoped token, never a public link.

The skill carries three helpers the agent uses directly. `publish.sh` for Sites,
`drive.sh` for Drives, and `account.sh` for the rest: Site Data, profiles, custom
domains, handles, links, service variables, analytics, browser connection, and
key revocation.

## Install

One skill, the same three scripts, wherever your agent lives. Choose the line
that fits; only the destination changes.

**Universal (recommended).** Anywhere the `skills` CLI runs:

```bash
npx skills add AsyncFuncAI/sharenow --skill sharenow -g
```

Drop the `-g` for a project-local, repo-pinned install.

**Codex.** Clone this repo into your project; Codex reads `.codex-plugin/plugin.json` on its own.

```bash
git clone https://github.com/AsyncFuncAI/sharenow
```

**Cursor.** Clone this repo into your project; Cursor reads `.cursor-plugin/plugin.json` on its own.

```bash
git clone https://github.com/AsyncFuncAI/sharenow
```

**Claude Code.** Copy the canonical skill into your skills directory. The
`sharenow/.` form copies the contents, so a re-run updates in place rather than
nesting:

```bash
mkdir -p ~/.claude/skills/sharenow && cp -R sharenow/. ~/.claude/skills/sharenow/   # global
# or, for one project:
mkdir -p .claude/skills/sharenow && cp -R sharenow/. .claude/skills/sharenow/
```

**OpenCode.** OpenCode discovers `SKILL.md` skills from several roots. Copy the
canonical skill into any of them (the `cp` creates the path on your machine):

```bash
mkdir -p .opencode/skills/sharenow && cp -R sharenow/. .opencode/skills/sharenow/
# OpenCode also reads .claude/skills/ and .agents/skills/
```

**Hermes.** Use the Hermes layout shipped in this repo:
`hermes/productivity/sharenow/`.

**OpenClaw.** OpenClaw loads standard `SKILL.md` skill directories. Copy the
canonical skill into your OpenClaw skills location:

```bash
mkdir -p <openclaw-skills-dir>/sharenow && cp -R sharenow/. <openclaw-skills-dir>/sharenow/
```

## What is in the package

```
sharenow/
├── SKILL.md            the agent-facing skill manifest
├── AGENTS.md           the operating guide for the agent
├── assets/logo.svg
└── scripts/
    ├── publish.sh      publish and update Sites (create, upload, finalize)
    ├── drive.sh        private Drive storage and scoped-token sharing
    └── account.sh      browser connection, Site Data, profiles, domains,
                        handles, links, variables, analytics, and key revocation
```

Every other install path in this repo (`skills/`, `hermes/`, the plugin
manifests) is generated from `sharenow/`. That directory is the single source of
truth.

Advanced channel and local-codebase Knowledge Base helpers are preserved under
`extras/advanced-scripts/` for future security review. They are not part of the
installed skill.

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
