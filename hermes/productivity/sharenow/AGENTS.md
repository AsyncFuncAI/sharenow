# sharenow Skill: Agent Guide

Operating guide for AI agents using the sharenow skill.

## What this skill does

- `scripts/publish.sh`: publish and update Sites. Outputs the live URL and a
  `publish_result.*` stderr contract (auth_mode, persistence, claim_url, ...).
- `scripts/drive.sh`: private Drive storage and scoped token sharing.
- `scripts/account.sh`: Site Data, profiles, domains, handles, links, variables,
  analytics, and API key management.

## Source of truth

When local skill text and the live server disagree, prefer the live server for
active operations.

- OpenAPI spec: `<base>/openapi.json`
- Agent context: `<base>/llms.txt`, `<base>/llms-full.txt`
- Skill version: `<base>/api/skill/version`

The default `<base>` is `https://sharenow.today`.

## Usage notes

- Resolve the API key from `--api-key` > `$SHARENOW_API_KEY` > `~/.sharenow/credentials`.
- Never commit credentials or local state (`~/.sharenow/credentials`, `.sharenow/state.json`).
- Drive contents are private; describe them as private, not as public URLs.
- API keys from `account.sh keys create` are shown once. Store them, do not log them.
- Custom-domain and handle DNS/TLS is deploy-time; the server stores and exposes mappings.
- Service-variable values are write-only. The API never returns them.

## Verification

```bash
curl -s https://sharenow.today/api/skill/version
curl -s https://sharenow.today/skill.md | head -20
curl -s https://sharenow.today/.well-known/skills/index.json
```
