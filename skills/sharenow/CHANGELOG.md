# sharenow skill changelog

One entry per released version, newest first. An agent answering "what
changed?" should read this file, not the commit history. It ships inside the
skill package and is always served at `https://sharenow.today/skill/CHANGELOG.md`;
compare with `scripts/version.sh` to see where your installed copy sits.

## 1.32.3

- `fullstack.sh up` advances the folder's stamp after a recorded deploy, so a
  pulled app folder can keep shipping without a re-pull, as a Site folder does.

## 1.32.2

- Editors can ship app code without the owner's secrets. An update keeps the
  existing value of every declared env name it does not re-send; a secrets
  file on update may cover a subset. `pull --app` writes `app_id` into a
  contract that predates the history, so `up` updates instead of creating.

## 1.32.1

- `publish.sh` advances the folder's stamp after a successful publish, so a
  pulled folder can keep publishing without a re-pull.
- `account.sh undo` says what it queued and how to watch it land; `status`
  reports the newest git push and says when a push is still deploying or was
  refused, instead of "In sync" while `main` is ahead of the live site.
- The git remote refuses a force push or a delete of `main`; deploy history is
  linear for git users too.
- `pull`, `status`, and `undo` accept `--help`; the stale refusal names the
  `diff` to run and never suggests `./work-latest-latest`; the "skipping local
  sharenow state" line now says what it means.
- The `status` human line says whether a refused or in-flight push is yours
  or a teammate's, and no longer repeats the clone URL (it is `.cloneUrl` in
  the JSON).

## 1.32.0

- Shared source. `account.sh pull <slug> <dir>` (or `--app <app-id>`) fetches a
  Site or app's live version into a folder with no git needed, and stamps it at
  `.sharenow/source.json`. An editor goes from accepted invite to a working copy
  in one command.
- Freshness. `publish.sh` and `fullstack.sh up` send the stamp's version, and a
  folder behind the live version is refused before anything is uploaded, with
  exit code 3 and the command to pull the newer version alongside. Folders with
  no stamp deploy exactly as before.
- `pull` refuses with exit 3 rather than overwriting a folder edited since its
  own stamp; `--force` discards those changes deliberately. Exit code 4 means
  the deploy's source is still being recorded, or was never recorded.
- `account.sh status <slug>` prints live version, last commit, whether they
  agree, any pending or failed recording, and the clone URL. `account.sh undo
  <slug> [--to <commit>]` redeploys the previous recorded commit.
- Every Site and app has a private git repo. Clone with the API key as the
  password; a push to `main` deploys. Container apps are recorded only and still
  need a local `up`.

## 1.31.0

- Collaborators. A Site or Fullstack app owner can invite other sharenow
  accounts as editors by email: `account.sh invite <slug> <email>`,
  `account.sh members <slug>`, `account.sh uninvite <slug> <email>`, each with
  `--app <app-id>` for a Fullstack target (or `fullstack.sh members|invite|
  uninvite`). The invited agent runs `account.sh invites` and
  `account.sh accept <inviteId>` on its own connection.
- An editor republishes a shared Site with `publish.sh --slug` and deploys a
  shared app with `fullstack.sh up`, using its own key. Deleting, renaming,
  access settings, domains, handles, and membership stay owner-only, and all
  storage and usage keep billing to the owner. Limits: 10 editors and 20
  pending invitations per resource, invitations expire after 7 days.
- `account.sh sites` and `fullstack.sh list` include shared resources and
  report `role` as `owner` or `editor`.

## 1.30.0

- Handles and custom domains can target owned Fullstack apps. The account helper
  requires an explicit `--slug` on create, can rebind an existing domain, and
  reports whether the selected target is a Site or app. Bindings follow app
  renames and detach on app deletion.
- Site publishing now includes `.sharenow/data.json` and
  `.sharenow/proxy.json` while continuing to exclude private local state. SPA
  fallback no longer turns API-shaped misses into successful HTML responses.
- Fullstack validation accepts SQL comments and detects missing relative module
  imports before provisioning. The skill now states the current D1 recovery
  limit and the production-email provider boundary explicitly.

## 1.29.0

- `runtime: container` contracts may declare an `edge:` block: per-path edge
  caching (`edge.cache`: path, ttl) and response header rules
  (`edge.headers`: path, set). sharenow applies it on the branded host so an
  app gets edge-cached HTML and immutable asset headers from its
  fullstack.yaml alone - no zone Cache Rules of its own, no dashboard clicks.
  Any request carrying a cookie or an authorization header bypasses the cache
  and is never shared; a response with set-cookie is never stored. Responses
  on declared paths carry `x-sharenow-edge: cache|bypass|uncacheable`.

## 1.28.8

- publish.sh no longer hard-requires the `file(1)` binary. It was only a
  fallback content-type sniffer for unknown extensions and already degraded
  to application/octet-stream; minimal containers without it could not
  publish at all, dying with a cryptic "requires file". The curl guard now
  carries install hints like the jq one.

## 1.28.7

- Anonymous publish messaging now leads with the human outcome: keep the
  Site live permanently by opening the claim URL and adding an email (free
  account, 3 permanent Sites, no card needed). The account.sh login path is
  the agent alternative, not the headline.
- Completion guidance: relay the private claim URL to the user with the
  free-account framing, and treat it as that user's secret (never place it
  on a public page or in shared output).
- Server side: publish create and finalize responses now carry `persistence`
  plus, for anonymous Sites, a self-describing `note` with the same claim
  guidance, so agents calling the raw API relay first-party copy.

## 1.28.6

- `app_id:` and `build:` are now RESERVED contract keys server-side: their
  names can never be claimed by a future contract feature, and wrong shapes
  (non-string app_id, non-mapping build) are rejected with clear errors.
- Documented the no-Docker lane through `up`: `push --assemble` pins the
  digest, then `up` ships a pinned contract with no Dockerfile as-is.
- Documented the staleness heuristic: a documented option missing from
  `--help`, or an undocumented failure, means re-run the installer first.

## 1.28.5

- Documented: the branded address can serve the previous version (or a
  placeholder on first create) for up to ~35s while the deployment reaches
  every edge location. Verify deploys with a short retry loop, not a single
  request. (Edge propagation, not a failed deploy - a field agent burned
  turns rediscovering this.)

## 1.28.4

- The slug-mismatch note now also fires on CREATE (a create assigns a
  generated address; a contract asking for `slug: my-name` was silently
  handed something else). Create receipts carry no slug field, so the note
  reads the address from the receipt url. From the worker field test.

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
