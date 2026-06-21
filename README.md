<p align="center">
  <img src="sharenow/assets/logo.svg" alt="sharenow" width="240" height="64">
</p>

<h1 align="center">sharenow</h1>

<p align="center">
  <strong>Ship sites. Hold files. One command.</strong><br>
  Publish a website or hand off a private file in one command, and it is live in seconds at <code>sharenow.today</code>.
</p>

---

sharenow is a skill, not a dashboard. It turns "put this online" into a single
script call your agent already knows how to make. Two capabilities, one install:

- **Sites.** Publish HTML, apps, documents, images, PDFs, and video to a live URL
  at `{slug}.sharenow.today` (or your own domain). A three-step flow under the
  hood, one command on the surface.
- **Drives.** Keep private agent files in cloud folders that outlive a single
  session: context, memory, plans, research, assets. Share them with another
  agent through a scoped token, not a public link.

The skill ships three helpers your agent drives directly: `publish.sh` for Sites,
`drive.sh` for Drives, and `account.sh` for everything else (Site Data, profiles,
custom domains, handles, links, service variables, analytics, and key management).

## Install

Pick the line that matches your agent. Every path installs the same skill and the
same three scripts; only the destination differs.

**Universal (recommended).** Works anywhere the `skills` CLI runs:

```bash
npx skills add AsyncFuncAI/sharenow --skill sharenow -g
```

Drop the `-g` for a project-local, repo-pinned install.

**Codex.** Clone this repo into your project; Codex picks up `.codex-plugin/plugin.json` automatically.

```bash
git clone https://github.com/AsyncFuncAI/sharenow
```

**Cursor.** Clone this repo into your project; Cursor picks up `.cursor-plugin/plugin.json` automatically.

```bash
git clone https://github.com/AsyncFuncAI/sharenow
```

**Claude Code.** Copy the canonical skill into your skills directory. The
`sharenow/.` form copies the contents, so a re-run updates in place instead of
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

**From a running sharenow instance.** Any sharenow server serves the skill over
HTTP:

```bash
curl -fsSL https://sharenow.today/install.sh | bash
```

## What is in the package

```
sharenow/
├── SKILL.md            # the agent-facing skill manifest
├── AGENTS.md           # operating guide for the agent
├── assets/logo.svg
└── scripts/
    ├── publish.sh      # publish + update Sites (create -> upload -> finalize)
    ├── drive.sh        # private Drive storage + scoped token sharing
    └── account.sh      # Site Data, profiles, domains, handles, links,
                        # variables, analytics, and API key management
```

Every other install path in this repo (`skills/`, `hermes/`, the plugin
manifests) is generated from `sharenow/`. That directory is the single source of
truth.

## Layout

| Path | Surface |
| --- | --- |
| `sharenow/` | Canonical skill (edit here) |
| `skills/sharenow/` | `npx skills add` layout |
| `hermes/productivity/sharenow/` | Hermes layout |
| `.codex-plugin/plugin.json` | Codex manifest |
| `.cursor-plugin/plugin.json` | Cursor manifest |

## For maintainers

The skill lives once in `sharenow/`. Edit there, then regenerate the per-agent
layouts and verify before pushing:

```bash
scripts/build-layouts.sh        # regenerate skills/ + hermes/; sync the logo into
                                #   the manifest dirs (the plugin JSON is hand-authored)
scripts/verify-package.sh       # gate: paths, layout sync, lint, exec bits,
                                #       brand, manifest JSON, install-cmd consistency
```

`build-layouts.sh --check` fails if any generated layout has drifted from the
canonical source, so the copies can never silently fall out of sync.

## License

MIT. See [LICENSE](./LICENSE).
