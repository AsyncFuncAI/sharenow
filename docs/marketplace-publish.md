# Publish sharenow to Cursor Marketplace and Grok Bot

Copy from here rather than composing at the form. The listing must match
`plugins/sharenow/.cursor-plugin/plugin.json` and the skill itself.

Grok Bot plugins are the Cursor Marketplace listing. There is no second
package and no separate Grok Bot upload. After Cursor lists the plugin,
xAI issues a share page at `https://x.ai/bot/plugin/<id>` (Treg's is
[55647425](https://x.ai/bot/plugin/55647425)).

## What Treg did (the pattern we copied)

Treg lives at [superdesigndev/treg](https://github.com/superdesigndev/treg).
Cursor's plugin root is never the git root:

```
.cursor-plugin/marketplace.json     source: ./plugins/treg
plugins/treg/.cursor-plugin/plugin.json
plugins/treg/skills/treg/SKILL.md
plugins/treg/assets/logo.svg
```

sharenow uses the same layout at `plugins/sharenow/`. The canonical skill
stays in `sharenow/`; `scripts/build-layouts.sh` copies it into the plugin.

## Before the form

1. `scripts/verify-package.sh` exits 0.
2. Plugin `version` matches `**Skill version:**` in `sharenow/SKILL.md`.
3. Public repo: `https://github.com/AsyncFuncAI/sharenow`
4. Test locally: copy `plugins/sharenow` to `~/.cursor/plugins/local/sharenow`,
   reload Cursor, run `Publish this website to sharenow.`
5. Sign in at [cursor.com/marketplace/publish](https://cursor.com/marketplace/publish)
   with the Cursor account that should own the listing. The form currently
   submits as that individual; put the company name in `plugin.json` `author`
   and note "company listing for ASYNCFUNC LLC" in the application.

## Form copy

| Field | Value |
| --- | --- |
| Repository | `https://github.com/AsyncFuncAI/sharenow` |
| Plugin name | `sharenow` |
| Display name | `sharenow` |
| Short description | Publish a live URL from a file or folder in seconds |
| Long description | *(use `description` from `plugins/sharenow/.cursor-plugin/plugin.json`, verbatim)* |
| Logo | `plugins/sharenow/assets/logo.svg` |
| Homepage | `https://sharenow.today` |
| Support | `https://sharenow.today/support` and `support@sharenow.today` |
| Privacy | `https://sharenow.today/privacy` |
| Terms | `https://sharenow.today/terms` |
| Publisher | ASYNCFUNC LLC |

## Example prompts for the listing

1. Publish this website to sharenow.
2. Turn this result into a simple page and publish it to sharenow.
3. Summarize this session as a shareable page and publish it to sharenow.
4. Save this file to my sharenow Drive.
5. Create a Channel so two agents can work on this together.

## What to tell the reviewer

> sharenow is a skills-only plugin: seven reviewed bash helpers talk to the
> first-party origin `https://sharenow.today`. There is no MCP server and no
> third-party credential to paste. Anonymous publish works immediately; the
> Site is public for one hour. Connecting an account happens on a first-party
> browser page, so an email code or API key never enters chat.
>
> Helpers upload only the exact user-approved file or folder. They refuse
> `.env` and common private-key file types, and they never execute downloaded
> content. The skill is MIT and open source at
> https://github.com/AsyncFuncAI/sharenow
>
> This is a company listing for ASYNCFUNC LLC. Contact: support@sharenow.today

Reviews are manual. Expect days to a couple of weeks. Questions:
marketplace-publishing@cursor.com

## After Cursor lists it

1. Confirm `https://cursor.com/marketplace/.../sharenow` (publisher path is
   assigned by Cursor).
2. In Grok Bot: **Settings → Plugins**, search **sharenow**, Add.
3. The Grok Bot share URL is `https://x.ai/bot/plugin/<id>` once Cursor/xAI
   mint it. Use that URL in posts; the Treg equivalent is the page that
   inspired this packaging.
4. Optional, separate surface: Grok Build catalog. Fork
   [xai-org/plugin-marketplace](https://github.com/xai-org/plugin-marketplace),
   add a remote entry in `.grok-plugin/marketplace.json` pointing at this
   repo and a pinned commit SHA, regenerate the plugin index, open a PR.
   This is not required for Grok Bot.

## Updates

Bump `version` in:

- `plugins/sharenow/.cursor-plugin/plugin.json`
- `.cursor-plugin/plugin.json`
- `.cursor-plugin/marketplace.json` `metadata.version`
- `.codex-plugin/plugin.json`
- `.grok-plugin/plugin.json`

Keep it equal to the skill version. Cursor re-reviews each update; ask them
to re-index after the GitHub commit is on `main`.
