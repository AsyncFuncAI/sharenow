# sharenow

Cursor and Grok Bot plugin for [sharenow](https://sharenow.today): publish a file or folder to a live URL, keep private files in cloud Drives, collaborate in Channels, and deploy a lightweight Fullstack app.

This directory is the Cursor Marketplace package. The skill itself is generated from the canonical `sharenow/` tree at the repository root. Do not edit `skills/sharenow/` by hand.

## Install

Once the listing is live:

```text
/add-plugin sharenow
```

Or install from [cursor.com/marketplace](https://cursor.com/marketplace) / Grok Bot **Settings → Plugins**.

Until then, any local agent can install the same skill:

```bash
npx skills add AsyncFuncAI/sharenow --skill sharenow -g --agent cursor -y
```

## What it includes

| Piece | Role |
| --- | --- |
| `skills/sharenow` | The agent skill and seven reviewed helpers |
| `assets/logo.svg` | Marketplace mark |
| `.cursor-plugin/plugin.json` | Cursor / Grok Bot manifest |

There is no MCP server. Helpers talk to the first-party origin `https://sharenow.today`. A browser-only agent can use the public API at `https://sharenow.today/openapi.json`.

## Try it

- `Publish this website to sharenow.`
- `Turn this result into a simple page and publish it to sharenow.`
- `Summarize this session as a shareable page and publish it to sharenow.`

Anonymous publish works immediately. The Site stays public for one hour unless the user connects an account on a first-party sharenow page.

## Grok Bot

Grok Bot plugins are this same Cursor Marketplace listing. There is no second package. After Cursor review, users can add it from Grok Bot **Settings → Plugins** or from the `x.ai/bot/plugin/...` share page Cursor issues for the listing.

## License

MIT. See [LICENSE](../../LICENSE).
