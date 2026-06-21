# sharenow: Agent Operating Guide

This repository packages the sharenow skill for every agent runtime. If you are an
agent using the skill, this is your operating guide. The agent-facing manifest is
`sharenow/SKILL.md`; this file is the contract around it.

## The three scripts

- `sharenow/scripts/publish.sh`: publish and update Sites. Outputs the live URL and
  a `publish_result.*` stderr contract (`auth_mode`, `persistence`, `claim_url`, ...).
  Read those lines to decide what to tell the user.
- `sharenow/scripts/drive.sh`: private Drive storage and scoped-token sharing.
- `sharenow/scripts/account.sh`: Site Data, profiles, custom domains, subdomain
  handles, links, service variables, analytics, and API key management.

## Source of truth

When the local skill text and the live server disagree, trust the live server for
active operations.

- OpenAPI spec: `https://sharenow.today/openapi.json`
- Agent context: `https://sharenow.today/llms.txt`, `https://sharenow.today/llms-full.txt`
- Skill version: `https://sharenow.today/api/skill/version`

The default base is `https://sharenow.today`. Point a script elsewhere with
`--base-url`; sending an API key to a non-default base requires the explicit
`--allow-nonsharenow-base-url` flag.

## Key resolution

The scripts resolve an account API key in this order (first match wins):

1. `--api-key <key>` (CI or scripting only)
2. `$SHARENOW_API_KEY`
3. `~/.sharenow/credentials`

In interactive sessions, prefer the credentials file. After you receive a key,
save it yourself; do not ask the user to run the command manually.

## Security

- Never commit credentials or local state (`~/.sharenow/credentials`,
  `.sharenow/state.json`). The repo `.gitignore` already excludes them.
- API keys from `account.sh keys create` are returned once. Store them, do not log them.
- Drive contents are private. Describe them as private files, never as public URLs.
- Service-variable values are write-only; the API never returns them.
- Custom-domain and handle DNS/TLS provisioning is a deploy-time concern. The server
  stores and exposes the mappings and their verification status.

## Verifying an install

```bash
curl -s https://sharenow.today/api/skill/version
curl -s https://sharenow.today/skill.md | head -20
curl -s https://sharenow.today/.well-known/skills/index.json
```

## Repository conventions

- The skill lives once in `sharenow/`. Every other layout is generated from it by
  `scripts/build-layouts.sh`. Never hand-edit a generated copy under `skills/` or
  `hermes/`; edit `sharenow/` and rebuild.
- `scripts/verify-package.sh` is the gate: it proves the layouts are in sync, the
  scripts lint clean, the manifests are valid JSON, and no brand violations exist.
- House rules for everything shipped here: no em-dash, and no references to any
  other hosting product. The product is sharenow.
