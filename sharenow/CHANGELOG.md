# sharenow skill changelog

One entry per released version, newest first. An agent answering "what
changed?" should read this file, not the commit history. It ships inside the
skill package and is always served at `https://sharenow.today/skill/CHANGELOG.md`;
compare with `scripts/version.sh` to see where your installed copy sits.

## 1.28.3

- Quota errors now show the numbers: a limit_exceeded response prints
  `quota: <metric>: <used> used of <included> this period; resets <time>`
  instead of a bare one-line 409. Paper cut from the worker-runtime field
  test (an agent had to go read the public limits page to learn the cap).

## 1.28.2

- `up` warns when the contract's `slug:` disagrees with the live app instead
  of ignoring it silently (up never renames; the note names the `rename`
  command that does). Paper cut from the unbiased cross-model field test.

## 1.28.1

- `up` host build steps write to stderr so stdout carries only the receipt
  JSON; piping `up` to jq no longer corrupts the parse or kills the build
  with EPIPE. Found dogfooding the dashboard deploy minutes after 1.28.0.

## 1.28.0

- New `up` verb: one-command create-or-update deploy driven entirely by the
  folder's `fullstack.yaml`. First run writes `app_id:` back into the yaml
  (commit it); every later `up` redeploys that app. Bare `worker.js` folders
  get a synthesized contract.
- Optional `build:` block in `fullstack.yaml` declares a container build:
  `dockerfile`, `name`, host `steps` run before docker build, and `env_hold`
  to keep a local dotenv out of the build. With no block, the folder's single
  Dockerfile is used; ambiguity and Next.js in-docker builds are refused with
  a recipe instead of guessed at.
- An app with a known `app_id` reuses its canonical secrets file
  automatically on `up`.
- Repos carrying a `.sharenow/` state directory are now shippable: staging
  skips it (like `.git/`) instead of refusing the project.
- `push` pins the digest only inside the `container:` block, so other
  indented `image:` keys survive.

## 1.27.2

- Shipping with `--secrets-from` pointed at the canonical
  `~/.sharenow/apps/<id>/secrets.json` itself (the normal steady state) no
  longer trips a same-file copy after the update succeeds.

## 1.27.1

- `secrets check` hashes values byte-exactly (a multi-line key's trailing
  newline survives), caught by dogfooding against a live PEM key.

## 1.27.0

- The CLI owns the secrets file: every deploy/update with `--secrets-from`
  installs a mode-600 canonical copy at `~/.sharenow/apps/<id>/secrets.json`.
- `secrets check <app-id>` compares that file against the live app's
  fingerprints and answers match-or-rotate per key. No hashing by hand.
- `secrets set <app-id> NAME --value-from <file>` rotates ONE key on a
  worker-runtime app (agent API parity with the dashboard) and keeps the
  canonical file in sync. Dashboard and API single-key edits now keep
  fingerprints truthful. Container apps rotate via `ship --app`.

## 1.26.0

- Secrets stay write-only but are now VERIFIABLE: the owner `status` response
  carries a per-key fingerprint (`sha256(salt + ":" + value)`, first 12 hex)
  and a last-set time. Recompute locally to check a secrets file against the
  live app, or to see which keys were rotated when. Values never travel.
  Fingerprints appear on the app's next deploy or update.

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
