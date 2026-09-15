<p align="center">
  <img src="https://sharenow.today/assets/ink-garden-home.webp" alt="sharenow" width="100%">
</p>

<h1 align="center">sharenow</h1>

<p align="center">Your agent made something. This turns it into a link.</p>

## Do this

Paste one line into the agent you are using. About 30 seconds.

```bash
# Claude Code
npx skills add AsyncFuncAI/sharenow --skill sharenow -g --agent claude-code -y

# Codex
npx skills add AsyncFuncAI/sharenow --skill sharenow -g --agent codex -y

# Cursor
npx skills add AsyncFuncAI/sharenow --skill sharenow -g --agent cursor -y
```

Then tell it:

- `Publish this website to sharenow.`
- `Turn this into a page and publish it.`
- `Save this file to my sharenow Drive.`

You get a real `*.sharenow.today` address. No setup. No login for the first try. The link lasts about an hour. Add your email if you want to keep it.

## What it does

1. **Publish** a file, a folder, or a page. Anyone with the link can open it.
2. **Keep** files private in a Drive, across chats.
3. **Share a room** so a few agents can work together.
4. **Put a small app online**, not just a page.

Account connection opens in your browser. Do not paste an email code or API key into chat.

Drop `-g` to install in this project only. Other agents: same command, change `--agent`. Browser-only chat: ask it to use `https://sharenow.today/openapi.json`.

Cursor Marketplace / Grok Bot (after the listing is live): `/add-plugin sharenow`

## Is this safe?

### Why security scanners may warn

This package contains seven shell helpers. Their job is to read the files you name and upload them. That looks loud to a scanner. They send only the exact files you approve to `https://sharenow.today`. They skip `.env` and private keys. They do not run anything they download.

Check the bytes: [sharenow.today/.well-known/sharenow-skill.json](https://sharenow.today/.well-known/sharenow-skill.json)

## For people who maintain this repo

Edit `sharenow/` only. Then:

```bash
scripts/build-layouts.sh        # copy into skills/, hermes/, plugins/
scripts/verify-package.sh       # must exit 0 before you push
```

| Path | What it is |
| --- | --- |
| `sharenow/` | The real skill. Edit here. |
| `skills/sharenow/` | `npx skills add` copy |
| `plugins/sharenow/` | Cursor / Grok Bot plugin |
| `hermes/productivity/sharenow/` | Hermes copy |

MIT. [LICENSE](./LICENSE)
