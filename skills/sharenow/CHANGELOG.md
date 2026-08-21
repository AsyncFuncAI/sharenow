# sharenow skill changelog

One entry per released version, newest first. An agent answering "what
changed?" should read this file, not the commit history. It ships inside the
skill package and is always served at `https://sharenow.today/skill/CHANGELOG.md`;
compare with `scripts/version.sh` to see where your installed copy sits.

## 1.25.1

- This file. The changelog now ships in the package and is served with it.

## 1.25.0

- Container `ship`/update receipts carry `bootLog`: the container's own recent
  stdout, so a config error printed at boot is visible at deploy time.
- The platform refuses to start a container whose environment payload is
  corrupted, with an error naming the repair, instead of booting the app with
  no environment.
- Documented: env values may be MULTI-LINE. Pass raw SSH/PEM keys directly;
  the base64-plus-entrypoint pattern is only for apps that need a real file,
  and the image must contain the decode step.

## 1.24.0

- `logs` on a `runtime: container` app now also returns `container.lines`:
  the app's persisted stdout/stderr from the last 15 minutes, boot output and
  crash messages included. Container debugging no longer needs local Docker.

## 1.23.0

- `ship` waits like a container actually starts (up to ~90s for image pull +
  boot) and a transient 5xx no longer counts as "address ready".
- The platform explains the two inscrutable container start failures (auth
  redirect wedging the health check; cold-start capacity) in the response.
- Framework-app playbook: build on your machine and COPY the output into the
  image; keep images small; ship-rename-rebuild order for baked public URLs.

## 1.22.1

- A container ship stages only `fullstack.yaml`, so shipping straight from a
  real app repository works.
- SKILL.md documents the container health-check contract: answer the
  synthetic Hosts (`containerstarthealthcheck`, `ping`) with a plain 200
  before any auth redirect.

## 1.22.0

- `runtime: container`: run compiled binaries, raw TCP/SSH egress, and
  long-lived processes behind the same contract and verbs. Digest-pinned
  images, scale-to-zero, per-version instance rolls.
- `push` builds the image: local Docker lane, or `push --assemble` with no
  Docker anywhere (prebuilt artifacts composed onto a base image).

## 1.21.0

- Multi-file static frontends: `code.assets` serves a folder of files next to
  the Worker, `spa: true` adds the deep-link fallback. Up to 300 files.

## 1.20.x

- D1 schema migrations (`migrations/NNNN_name.sql`, applied in order with a
  ledger in the app's own database).
- `sql` (read-only SELECT, no route needed), `logs` (bounded live capture),
  and one-command `ship` chaining prepare + approve + deploy or update.
- Branded-host parity: `<slug>.sharenow.today` behaves exactly like the
  workers.dev origin. Staged-project caps raised to 500 files / 50 MiB.

## 1.19.0

- `rename` verbs for Sites and Fullstack apps: move to a chosen address, the
  old address redirects.

## 1.18.0

- Parallel uploads: publishing large folders got materially faster.

## 1.17.x

- Channel helper: create and claim agent coordination rooms; `watch` verb for
  background reply-waiting.

## 1.16.0

- Secure trial recovery flow.

## 1.15.0

- Fullstack loop kit: the `loop-crm` starter (intake route, SQL loop state,
  private reports, model task with retries, scheduled reconciliation).

## 1.14.0 and earlier

- Fullstack disposable apps v1, private Drive, Codegraph knowledge sessions
  with the graph UI (`kb.sh ui`), account connect, anonymous publish with
  claim tokens. Ancient history: read SKILL.md, it reflects all of it.
