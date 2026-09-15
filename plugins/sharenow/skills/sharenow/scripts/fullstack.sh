#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://sharenow.today"
CREDENTIALS_FILE="$HOME/.sharenow/credentials"
STATE_DIR="${SHARENOW_STATE_DIR:-$HOME/.sharenow}/fullstack"
PLANS_DIR="$STATE_DIR/plans"
API_KEY="${SHARENOW_API_KEY:-}"

usage() {
  local code="${1:-1}"
  cat <<'USAGE'
Usage: fullstack.sh [--client <agent-name>] <command> [args]

Commands:
  list
  init loop-crm <empty-folder>
  prepare <project-folder> [--dry-run]
  plan --contract <yaml-file> --drive <drive-id> --manifest <json-file>
  validate <plan-id>
  approve <plan-id> [--for-app <app-id>]
  deploy <plan-id> [--secrets-from <mode-600-json-file>] [--dry-run]
  update <app-id> <plan-id> [--secrets-from <mode-600-json-file>] [--dry-run]
  ship <project-folder> [--app <app-id>] [--secrets-from <mode-600-json-file>]
  up [<project-folder>] [--secrets-from <mode-600-json-file>]
  push <folder> [--dockerfile <file>] [--name <image-name>]
  push --assemble --name <n> --base <ref> --entrypoint </path> --artifact <local>:<dest>[:<mode>]... [--env K=V]...
  status <app-id>
  pull <app-id> <dir> [--force]
  sql <app-id> <select-statement> [--binding <name>]
  logs <app-id> [--seconds <5-60>]
  secrets check <app-id> [--file <secrets.json>]
  secrets set <app-id> <NAME> --value-from <mode-600-file>
  rename <app-id> <new-slug>
  delete <app-id> --confirm <app-id> [--dry-run]
  members <app-id>
  invite <app-id> <email>
  uninvite <app-id> <email|inv_...|account-id>

--client <agent-name> may appear anywhere and tags every request for
attribution, the same flag publish.sh and account.sh take.

Prepare scans one explicit project folder. Its dry-run is local. The live path
stages accepted files in one private Drive and validates the exact remote bytes
without provisioning. Deploy requires a separate approve command and repeats
remote validation; a deploy from a prepared project folder writes app_id: back
into that folder's fullstack.yaml so the next up updates the same app, and it
honors the contract's slug: when that address is free (a taken address gets a
generated one plus a note; an invalid one is refused before anything is
staged). Ship chains prepare + approve + deploy (or update with
--app) in one command - run it only when your user has already approved
shipping this exact project. Secret values are accepted only from a mode-600
JSON file, never from command-line values, and are never printed. A --dry-run
deploy or update needs no secrets file.

pull <app-id> <dir> fetches the app's live source into <dir> with a version
stamp (the same as account.sh pull --app). The read-only clone URL is
`account.sh status --app <app-id> | jq -r .cloneUrl`.

sql runs one read-only SELECT against the app's D1 (no app route needed).
logs captures LIVE Worker events for a bounded window: start it (in the
background), then exercise the app, then read the result. For a
`runtime: container` app the response ALSO carries `container.lines` - the
app's persisted stdout/stderr from the last 15 minutes (boot output and
crash messages included), no exercising required.

push builds the image a `runtime: container` contract pins. The default lane
uses local Docker; --assemble needs no Docker anywhere (prebuilt artifacts are
assembled server-side onto a base image). Both print the digest reference and
write it into the folder's fullstack.yaml when one declares runtime: container.

up is the one-verb create-or-update deploy: everything it needs lives in the
folder's fullstack.yaml. `app_id:` (top-level) targets an existing app and is
written back automatically on first create - commit it. A `runtime: container`
contract may declare an optional `build:` block (all keys optional):
  build:
    dockerfile: Dockerfile.api   # default: the folder's single Dockerfile
    name: my-api                 # image name; default: folder name
    steps:                       # host commands run before docker build
      - npm run build
    env_hold: .env.local         # file moved aside while steps run
members lists the app owner plus its editors. The owner may invite another
sharenow account by email as an editor: an editor can deploy updates (up,
update, ship), read sql and logs, and manage env, but cannot delete, rename,
claim, or change who has access. Billing stays with the owner.

up runs steps, builds + pushes the image, pins the digest, and ships. With no
build block it builds the folder's single Dockerfile (two or more must be
disambiguated with build.dockerfile). A bare folder holding only worker.js
gets a synthesized worker contract. Secrets: a known app_id reuses the
canonical file installed by earlier deploys automatically; pass --secrets-from
for the first deploy of an app that declares env. Like ship, run up only when
your user has already approved shipping this exact project.
USAGE
  exit "$code"
}

die() { echo "error: $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLED_JQ="${SKILL_DIR}/bin/jq"
if [[ -x "$BUNDLED_JQ" ]]; then JQ_BIN="$BUNDLED_JQ"
elif command -v jq >/dev/null 2>&1; then JQ_BIN="$(command -v jq)"
else die "requires jq. Install it with 'brew install jq' (macOS) or 'sudo apt-get install jq' (Debian/Ubuntu), then retry"; fi
command -v curl >/dev/null 2>&1 || die "requires curl"
command -v shasum >/dev/null 2>&1 || die "requires shasum"
command -v file >/dev/null 2>&1 || die "requires file"
. "$SCRIPT_DIR/lib/http.sh"
# The source stamp and the stale refusal (git source of truth, R11/R12).
. "$SCRIPT_DIR/lib/source.sh"

valid_account_key() { [[ "$1" == snk_????????????????????* && "$1" != *[!A-Za-z0-9_-]* ]]; }
load_account_key() {
  if [[ -z "$API_KEY" && -f "$CREDENTIALS_FILE" ]]; then API_KEY=$(tr -d '[:space:]' < "$CREDENTIALS_FILE"); fi
  [[ -n "$API_KEY" ]] || die "not connected. Run ./scripts/account.sh login --client <agent-name>, then retry"
  valid_account_key "$API_KEY" || die "invalid account credential format"
}

# Attribution header for every account request (the same x-sharenow-client
# publish.sh and account.sh send). Set once the global --client flag is parsed;
# a child invocation ("$0" ship ...) inherits it through the environment.
CLIENT_HEADER_VALUE="sharenow-fullstack-sh"

api_account() {
  local method="$1" url="$2" body="${3:-}" idempotency="${4:-}" tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    if [[ -n "$idempotency" ]]; then
      code=$(printf '%s' "$body" | curl --config <(printf 'header = "authorization: Bearer %s"\n' "$API_KEY") -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "content-type: application/json" -H "x-sharenow-client: $CLIENT_HEADER_VALUE" -H "idempotency-key: $idempotency" --data-binary @-)
    else
      code=$(printf '%s' "$body" | curl --config <(printf 'header = "authorization: Bearer %s"\n' "$API_KEY") -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "content-type: application/json" -H "x-sharenow-client: $CLIENT_HEADER_VALUE" --data-binary @-)
    fi
  else
    code=$(printf 'header = "authorization: Bearer %s"\n' "$API_KEY" | curl --config - -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "x-sharenow-client: $CLIENT_HEADER_VALUE")
  fi
  http_handle_response "$code" "$tmp"
}

# The freshness-aware app update (R11, R12, KTD2).
#
# `api_account` dies on any non-2xx, which would flatten the stale refusal into
# a generic exit 1. This wrapper keeps the response so the ONE failure that has
# its own exit code can keep it: 3 means "someone else deployed", distinct from
# auth, validation, and network failures.
#
# The claim itself is the stamp's version, which for an app is the deploy
# sequence number `up` last pulled. No stamp means no claim, and an app deployed
# from a folder that never pulled behaves exactly as it always did.
api_update_app() {
  local url="$1" body="$2" expected="$3" root="$4" label="$5" tmp code mine live pair
  if [[ -n "$expected" ]]; then
    body=$(printf '%s' "$body" | "$JQ_BIN" -c --arg v "$expected" '.expectedVersion = $v')
  fi
  tmp=$(mktemp)
  code=$(printf '%s' "$body" | curl --config <(printf 'header = "authorization: Bearer %s"\n' "$API_KEY") \
    -sS -o "$tmp" -w "%{http_code}" -X PUT "$url" -H "content-type: application/json" -H "x-sharenow-client: $CLIENT_HEADER_VALUE" --data-binary @-)
  if source_response_is_stale "$tmp"; then
    pair="$(source_stale_versions "$tmp")"
    mine="${pair%%$'\t'*}"; live="${pair#*$'\t'}"
    [[ -n "$mine" ]] || mine="$expected"
    rm -f "$tmp"
    source_stale_message "$label" "$root" "$mine" "$live"
    exit 3
  fi
  http_handle_response "$code" "$tmp"
}

absolute_file() {
  local input="$1" dir base
  [[ -f "$input" ]] || die "file not found: $input"
  dir=$(cd "$(dirname "$input")" && pwd)
  base=$(basename "$input")
  printf '%s/%s\n' "$dir" "$base"
}

absolute_dir() {
  local input="$1"
  [[ -d "$input" ]] || die "folder not found: $input"
  (cd "$input" && pwd)
}

file_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
text_sha() { shasum -a 256 | awk '{print $1}'; }
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
valid_plan_id() { [[ "$1" == fsp_* && "$1" != *[!A-Za-z0-9_-]* ]] || die "invalid Fullstack plan id"; }
valid_app_id() { [[ "$1" == fsa_* && "$1" != *[!A-Za-z0-9_-]* ]] || die "invalid Fullstack app id"; }

valid_branded_url() {
  local value="$1" host label
  case "$value" in
    https://*.sharenow.today|https://*.sharenow.today/) ;;
    *) return 1 ;;
  esac
  host="${value#https://}"; host="${host%/}"
  [[ "$host" != */* && "$host" != *@* && "$host" != *:* ]] || return 1
  label="${host%.sharenow.today}"
  [[ -n "$label" && "$label" != "$host" && "$label" != *.* ]] || return 1
  [[ "$label" != *[!a-z0-9-]* && "$label" != -* && "$label" != *- ]] || return 1
}

wait_for_branded_url() {
  # A container app's first request pulls the image and boots the instance,
  # so give it a real window (~90s) and keep waiting through the transient
  # 5xx the platform serves while starting. Worker apps keep the short wait.
  local url="$1" runtime="${2:-worker}" attempt=0 code delay max_attempts=6
  [[ "$runtime" == container ]] && max_attempts=20
  valid_branded_url "$url" || die "invalid Fullstack live URL"
  while [[ "$attempt" -lt "$max_attempts" ]]; do
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 10 "$url" || true)
    case "$code" in
      [123][0-9][0-9]|40[0-35-9]|4[1-9][0-9]) return 0 ;;  # any real answer except 404 (propagation)
    esac
    attempt=$((attempt + 1))
    [[ "$attempt" -lt "$max_attempts" ]] || break
    if [[ "$runtime" == container ]]; then delay=5
    elif [[ "$attempt" -le 2 ]]; then delay=1
    elif [[ "$attempt" -le 4 ]]; then delay=2
    else delay=3; fi
    sleep "$delay"
  done
  return 1
}

receipt_path() {
  valid_plan_id "$1"
  printf '%s/%s.json\n' "$PLANS_DIR" "$1"
}

write_receipt() {
  local path="$1" json="$2" dir tmp
  dir=$(dirname "$path"); mkdir -p "$dir"; umask 077
  tmp=$(mktemp "$dir/.receipt.XXXXXX") || die "could not create Fullstack receipt"
  if printf '%s' "$json" | "$JQ_BIN" -e . > "$tmp"; then
    chmod 600 "$tmp"; mv "$tmp" "$path"
  else
    rm -f "$tmp"; die "could not write Fullstack receipt"
  fi
}

read_receipt() {
  local path
  path=$(receipt_path "$1")
  [[ -f "$path" ]] || die "Fullstack plan not found: $1"
  "$JQ_BIN" -e . "$path" || die "invalid Fullstack receipt"
}

normalize_manifest() {
  "$JQ_BIN" -ce '
    if type != "array" then error("manifest must be an array") else . end
    | if all(.[]; type == "object"
        and (.path | type == "string" and length > 0 and startswith("/") | not)
        and (.path | contains("..") | not)
        and (.sha256 | type == "string" and test("^[a-fA-F0-9]{64}$"))
        and (.size | type == "number" and . >= 0 and floor == .))
      then . else error("invalid manifest entry") end
    | sort_by(.path)
    | if ([.[].path] | unique | length) == length then . else error("duplicate manifest path") end
  ' "$1" 2>/dev/null || die "manifest must contain unique {path, sha256, size} entries"
}

declared_env() {
  awk '
    /^env:[[:space:]]*$/ { in_env=1; next }
    in_env && /^[^[:space:]]/ { in_env=0 }
    in_env && /^[[:space:]]*-[[:space:]]*[A-Z_][A-Z0-9_]*[[:space:]]*$/ {
      value=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
    }
  ' "$1" | "$JQ_BIN" -Rsc 'split("\n") | map(select(length > 0)) | unique | sort'
}

declared_triggers() {
  awk '
    /^triggers:[[:space:]]*$/ { in_triggers=1; next }
    in_triggers && /^[^[:space:]]/ { in_triggers=0 }
    in_triggers && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      if (name != "") print name "\t" type "\t" cron
      line=$0; sub(/^.*name:[[:space:]]*/, "", line); gsub(/"/, "", line)
      name=line; type=""; cron=""; next
    }
    in_triggers && /^[[:space:]]*type:[[:space:]]*/ {
      line=$0; sub(/^.*type:[[:space:]]*/, "", line); gsub(/"/, "", line); type=line; next
    }
    in_triggers && /^[[:space:]]*cron:[[:space:]]*/ {
      line=$0; sub(/^.*cron:[[:space:]]*/, "", line); gsub(/^"|"$/, "", line); cron=line; next
    }
    END { if (name != "") print name "\t" type "\t" cron }
  ' "$1" | "$JQ_BIN" -Rsc '
    split("\n") | map(select(length > 0) | split("\t") | {name:.[0],type:.[1],cron:.[2]})
  '
}

is_sensitive_path() {
  local path="$1" base lower
  base="${path##*/}"
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|id_rsa|id_ed25519|credentials|credentials.json|service-account*.json|.npmrc|.netrc|.pypirc)
      return 0 ;;
  esac
  case "$path" in
    .sharenow/*|*/.sharenow/*|.aws/*|*/.aws/*|.ssh/*|*/.ssh/*) return 0 ;;
  esac
  return 1
}

project_manifest() {
  local root="$1" manifest='[]' count=0 total=0 file_path rel size sha
  # A `runtime: container` contract ships ONLY fullstack.yaml - the platform
  # runs a pushed image, so nothing else in the folder is staged. Skip the
  # whole-tree scan so shipping straight from a real app repo (symlinks,
  # thousands of files) works.
  if grep -qE '^runtime:[[:space:]]*"?container"?[[:space:]]*$' "$root/fullstack.yaml" 2>/dev/null; then
    size=$(wc -c < "$root/fullstack.yaml" | tr -d '[:space:]')
    sha=$(file_sha "$root/fullstack.yaml")
    "$JQ_BIN" -n --arg sha "$sha" --argjson size "$size" '[{path:"fullstack.yaml",sha256:$sha,size:$size}]'
    return 0
  fi
  if find "$root" -type l -print -quit | grep -q .; then
    die "project contains a symbolic link; copy the intended file into the folder instead"
  fi
  while IFS= read -r -d '' file_path; do
    rel="${file_path#"$root"/}"
    # .sharenow/ is OUR state dir (publish.sh already excludes it); skipping it
    # here keeps repos with sharenow state shippable instead of refused.
    case "$rel" in .git/*|node_modules/*|.sharenow/*|*/.sharenow/*|.DS_Store|*/.DS_Store) continue ;; esac
    [[ "$rel" != *$'\n'* && "$rel" != /* && "$rel" != *../* && "$rel" != ../* ]] || die "unsafe project path: $rel"
    is_sensitive_path "$rel" && die "sensitive file refused: $rel"
    size=$(wc -c < "$file_path" | tr -d '[:space:]')
    [[ "$size" -le 20971520 ]] || die "project file exceeds 20 MiB: $rel"
    count=$((count + 1)); total=$((total + size))
    [[ "$count" -le 500 ]] || die "project exceeds 500 files"
    [[ "$total" -le 52428800 ]] || die "project exceeds 50 MiB"
    sha=$(file_sha "$file_path")
    manifest=$(printf '%s' "$manifest" | "$JQ_BIN" -c --arg path "$rel" --arg sha "$sha" --argjson size "$size" '. + [{path:$path,sha256:$sha,size:$size}]')
  done < <(find "$root" -type f -print0 | sort -z)
  [[ "$count" -gt 0 ]] || die "project folder contains no accepted files"
  printf '%s' "$manifest" | "$JQ_BIN" -c 'sort_by(.path)'
}

stage_project_file() {
  local drive_id="$1" root="$2" entry="$3" rel size sha content_type metadata started upload_url upload_id code
  rel=$(printf '%s' "$entry" | "$JQ_BIN" -r '.path')
  size=$(printf '%s' "$entry" | "$JQ_BIN" -r '.size')
  sha=$(printf '%s' "$entry" | "$JQ_BIN" -r '.sha256')
  content_type=$(file --brief --mime-type "$root/$rel" 2>/dev/null || printf '%s' application/octet-stream)
  metadata=$("$JQ_BIN" -n --arg path "$rel" --argjson size "$size" --arg type "$content_type" --arg sha "$sha" \
    '{path:$path,size:$size,contentType:$type,sha256:$sha,ifNoneMatch:"*"}')
  started=$(api_account POST "$BASE_URL/api/v1/drives/$drive_id/files/uploads" "$metadata")
  upload_url=$(printf '%s' "$started" | "$JQ_BIN" -r '.uploadUrl // empty')
  upload_id=$(printf '%s' "$started" | "$JQ_BIN" -r '.uploadId // empty')
  [[ "$upload_url" == https://* && -n "$upload_id" ]] || die "invalid Drive upload response"
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$upload_url" -H "content-type: $content_type" --data-binary "@$root/$rel")
  [[ "$code" -ge 200 && "$code" -lt 300 ]] || die "Drive upload failed for $rel (HTTP $code)"
  api_account POST "$BASE_URL/api/v1/drives/$drive_id/files/finalize" "$("$JQ_BIN" -n --arg uploadId "$upload_id" '{uploadId:$uploadId}')" >/dev/null
}

# Upload a small bounded batch, then join every child even when one fails.
# No late writer can race deployment or staging cleanup.
stage_project_batch() {
  local drive_id="$1" root="$2" manifest="$3" entry pid failed=0
  local pids=()
  while IFS= read -r entry; do
    (stage_project_file "$drive_id" "$root" "$entry") &
    pids+=("$!")
    if [[ "${#pids[@]}" -eq 8 ]]; then
      for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
      [[ "$failed" -eq 0 ]] || die "project staging failed; no deployment was requested"
      pids=()
    fi
  done < <(printf '%s' "$manifest" | "$JQ_BIN" -c '.[]')
  if [[ "${#pids[@]}" -gt 0 ]]; then
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  fi
  [[ "$failed" -eq 0 ]] || die "project staging failed; no deployment was requested"
}

# ── Source snapshot (git source of truth, KTD6) ──────────────────────────────
#
# After a deploy succeeds, sharenow hands back a one-time `source` grant
# {deploySeq, sourceToken}. These helpers turn the deployed-from folder into a
# content-addressed snapshot bound to THAT deploy, so the app's repo holds the
# real source instead of just the contract.
#
# The hard rule: none of this may ever fail `up`. The app is already live by the
# time any of it runs, so every failure path prints one `source: ...` line and
# returns 0. That is why `api_source` exists at all - `api_account` calls `die`.

# Non-fatal JSON API call. Prints the body on 2xx and returns 0; on anything
# else prints nothing and returns 1, leaving the caller to decide (which for the
# snapshot is always "print a note and carry on").
api_source() {
  local method="$1" url="$2" body="${3:-}" tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(printf '%s' "$body" | curl --config <(printf 'header = "authorization: Bearer %s"\n' "$API_KEY") -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "content-type: application/json" -H "x-sharenow-client: $CLIENT_HEADER_VALUE" --data-binary @- 2>/dev/null) || code=000
  else
    code=$(printf 'header = "authorization: Bearer %s"\n' "$API_KEY" | curl --config - -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "x-sharenow-client: $CLIENT_HEADER_VALUE" 2>/dev/null) || code=000
  fi
  if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
    cat "$tmp"; rm -f "$tmp"; return 0
  fi
  # Surface the server's own reason (source_not_open, snapshot_too_large, ...)
  # on stderr through the caller, not here: this returns it as the body so the
  # caller can put it in the one `source:` line the agent reads.
  "$JQ_BIN" -r '.code // empty' "$tmp" 2>/dev/null >&2 || true
  rm -f "$tmp"
  return 1
}

# The SNAPSHOT walk. Wider than `project_manifest` in two ways, on purpose:
# container apps are included (their source is worth committing even though only
# fullstack.yaml is staged for the deploy), and declared build output is skipped
# because it is regenerated from the source we do commit. Same secret refusal.
snapshot_manifest() {
  local root="$1" manifest='[]' count=0 total=0 file_path rel size sha
  while IFS= read -r -d '' file_path; do
    rel="${file_path#"$root"/}"
    case "$rel" in
      .git/*|*/.git/*|node_modules/*|*/node_modules/*|.sharenow/*|*/.sharenow/*) continue ;;
      dist/*|*/dist/*|.next/*|*/.next/*|build/*|*/build/*|out/*|*/out/*|target/*|*/target/*) continue ;;
      .DS_Store|*/.DS_Store) continue ;;
    esac
    [[ "$rel" != *$'\n'* && "$rel" != /* && "$rel" != *../* && "$rel" != ../* ]] || continue
    # A credential in the folder means we record NOTHING: a commit that quietly
    # omitted it would differ from what was deployed, which is the drift this
    # feature exists to prevent. The server refuses such a manifest too.
    if is_sensitive_path "$rel"; then
      printf 'SECRET\t%s\n' "$rel"
      return 0
    fi
    size=$(wc -c < "$file_path" | tr -d '[:space:]')
    [[ "$size" -le 20971520 ]] || { printf 'TOO_LARGE\n'; return 0; }
    count=$((count + 1)); total=$((total + size))
    if [[ "$count" -gt 2000 || "$total" -gt 209715200 ]]; then
      printf 'TOO_LARGE\n'
      return 0
    fi
    sha=$(file_sha "$file_path")
    manifest=$(printf '%s' "$manifest" | "$JQ_BIN" -c --arg path "$rel" --arg sha "$sha" --argjson size "$size" '. + [{path:$path,sha256:$sha,size:$size}]')
  done < <(find "$root" -type f -print0 2>/dev/null | sort -z)
  [[ "$count" -gt 0 ]] || { printf 'EMPTY\n'; return 0; }
  printf 'OK\t%s\n' "$(printf '%s' "$manifest" | "$JQ_BIN" -c 'sort_by(.path)')"
}

# The yaml-only fallback a folder past the cap sends instead (KTD6).
snapshot_yaml_only() {
  local root="$1" size sha
  [[ -f "$root/fullstack.yaml" ]] || return 1
  size=$(wc -c < "$root/fullstack.yaml" | tr -d '[:space:]')
  sha=$(file_sha "$root/fullstack.yaml")
  "$JQ_BIN" -n --arg sha "$sha" --argjson size "$size" '[{path:"fullstack.yaml",sha256:$sha,size:$size}]'
}

# Send the folder as this deploy's source. Prints exactly one `source: ...`
# line and ALWAYS returns 0 - `up` has already shipped a live app and must not
# report failure because bookkeeping did not land.
send_source_snapshot() {
  local app_id="$1" root="$2" deploy_seq="$3" token="$4"
  local walked kind manifest reason body plan snapshot_id uploads count i entry url path code fin record_id

  walked=$(snapshot_manifest "$root") || { echo "source: not recorded (could not read the folder)"; return 0; }
  kind="${walked%%$'\t'*}"
  case "$kind" in
    SECRET)
      echo "source: not recorded (a credential file is in the folder: ${walked#*$'\t'})"
      return 0 ;;
    EMPTY)
      echo "source: not recorded (no recordable files)"
      return 0 ;;
    TOO_LARGE)
      manifest=$(snapshot_yaml_only "$root") || { echo "source: not recorded (folder over the snapshot cap)"; return 0; }
      reason="too_large" ;;
    OK)
      manifest="${walked#*$'\t'}"
      reason="" ;;
    *)
      echo "source: not recorded (unexpected snapshot state)"
      return 0 ;;
  esac

  if [[ -n "$reason" ]]; then
    body=$("$JQ_BIN" -cn --arg seq "$deploy_seq" --arg token "$token" --argjson manifest "$manifest" --arg reason "$reason" \
      '{deploySeq:$seq,sourceToken:$token,manifest:$manifest,reason:$reason}')
  else
    body=$("$JQ_BIN" -cn --arg seq "$deploy_seq" --arg token "$token" --argjson manifest "$manifest" \
      '{deploySeq:$seq,sourceToken:$token,manifest:$manifest}')
  fi
  plan=$(api_source POST "$BASE_URL/api/v1/fullstack/$app_id/source" "$body" 2>/dev/null) || {
    echo "source: not recorded (the server did not open a snapshot for this deploy)"
    return 0
  }
  snapshot_id=$(printf '%s' "$plan" | "$JQ_BIN" -r '.snapshotId // empty')
  [[ -n "$snapshot_id" ]] || { echo "source: not recorded (no snapshot id)"; return 0; }

  count=$(printf '%s' "$plan" | "$JQ_BIN" '.uploads | length')
  i=0
  while [[ "$i" -lt "$count" ]]; do
    entry=$(printf '%s' "$plan" | "$JQ_BIN" -c --argjson i "$i" '.uploads[$i]')
    url=$(printf '%s' "$entry" | "$JQ_BIN" -r '.url')
    path=$(printf '%s' "$entry" | "$JQ_BIN" -r '.path')
    code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$url" -H "content-type: application/octet-stream" --data-binary "@$root/$path" 2>/dev/null) || code=000
    if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
      echo "source: not recorded (upload failed for $path)"
      return 0
    fi
    i=$((i + 1))
  done

  fin=$(api_source POST "$BASE_URL/api/v1/fullstack/$app_id/source/$snapshot_id/finalize" '{}' 2>/dev/null) || {
    echo "source: not recorded (the snapshot did not finalize)"
    return 0
  }
  record_id=$(printf '%s' "$fin" | "$JQ_BIN" -r '.recordId // empty')
  if [[ -n "$reason" ]]; then
    echo "source: pending (${record_id:-recorded}) - folder over the snapshot cap, contract only"
  else
    echo "source: pending (${record_id:-recorded})"
  fi
  # The folder now IS the live deploy. Advance its stamp so the next up from
  # this same folder is not refused as stale by the very deploy it just made
  # (publish.sh does the same for a Site). Only a folder that already carried
  # a stamp for this app gets one; a plain folder keeps making no claim.
  if [[ "$(source_stamp_slug "$root")" == "$app_id" ]]; then
    source_write_stamp "$root" fullstack "$app_id" "$deploy_seq" || true
  fi
  return 0
}

remote_validate() {
  local receipt="$1" env_json="${2:-}" contract_path yaml body result
  [[ -n "$env_json" ]] || env_json='{}'
  contract_path=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
  yaml=$(cat "$contract_path")
  body=$("$JQ_BIN" -n --arg yaml "$yaml" \
    --arg driveId "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')" \
    --argjson manifest "$(printf '%s' "$receipt" | "$JQ_BIN" -c '.manifest')" \
    --argjson env "$env_json" '{yaml:$yaml,driveId:$driveId,manifest:$manifest,env:$env}')
  result=$(api_account POST "$BASE_URL/api/v1/fullstack/validate" "$body")
  unset body yaml
  [[ "$(printf '%s' "$result" | "$JQ_BIN" -r '.valid // false')" == true ]] || die "remote Fullstack validation did not return a valid receipt"
  printf '%s' "$result"
}

verify_receipt_content() {
  local receipt="$1" contract manifest contract_sha manifest_sha normalized source_type project_root
  contract=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
  source_type=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')
  if [[ "$source_type" == project ]]; then
    project_root=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.projectRoot')
    [[ -f "$contract" && -d "$project_root" ]] || die "planned project no longer exists; create a new plan"
    normalized=$(project_manifest "$project_root")
  else
    manifest=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.manifestPath')
    [[ -f "$contract" && -f "$manifest" ]] || die "planned contract or manifest no longer exists; create a new plan"
    normalized=$(normalize_manifest "$manifest")
  fi
  contract_sha=$(file_sha "$contract")
  manifest_sha=$(printf '%s' "$normalized" | text_sha)
  [[ "$contract_sha" == "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractSha256')" ]] || die "contract changed after approval; create and approve a new plan"
  [[ "$manifest_sha" == "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.manifestSha256')" ]] || die "manifest changed after approval; create and approve a new plan"
}

# The CLI owns the canonical per-app secrets file so nobody babysits a stray
# path: every successful deploy/update that carried --secrets-from installs a
# mode-600 copy here, and `secrets check` reads it by default.
canonical_secrets_path() {
  printf '%s/.sharenow/apps/%s/secrets.json' "$HOME" "$1"
}

install_canonical_secrets() {
  local app_id="$1" source_file="$2" dir
  [[ -n "$source_file" && -f "$source_file" ]] || return 0
  dir="$HOME/.sharenow/apps/$app_id"
  mkdir -p "$dir" && chmod 700 "$HOME/.sharenow" "$HOME/.sharenow/apps" "$dir" 2>/dev/null
  # Shipping FROM the canonical file itself is the normal steady state; cp
  # refuses a same-file copy, so skip it (and never fail the deploy receipt).
  [[ "$source_file" -ef "$dir/secrets.json" ]] && return 0
  cp "$source_file" "$dir/secrets.json" && chmod 600 "$dir/secrets.json"
}

env_fingerprint_local() {
  # sha256(salt + ":" + value), first 12 hex - must match the server recipe.
  printf '%s:%s' "$1" "$2" | shasum -a 256 | cut -c1-12
}

# Flat readers for the two fullstack.yaml shapes `up` consumes. Top-level
# scalars and 2-space-indented keys inside the build: block only - the full
# contract is parsed server-side; these never have to understand all of YAML.
yaml_top_get() { # yaml_top_get <file> <key>  (no-match is empty, never an error)
  { grep -E "^$2:" "$1" 2>/dev/null || true; } | head -1 | sed -E "s/^$2:[[:space:]]*//" | tr -d '" '
}
yaml_build_get() { # yaml_build_get <file> <key>
  sed -n '/^build:/,/^[^ ]/p' "$1" 2>/dev/null | { grep -E "^[[:space:]]{2}$2:" || true; } | head -1 \
    | sed -E "s/^[[:space:]]+$2:[[:space:]]*//" | tr -d '"'
}
yaml_build_steps() { # yaml_build_steps <file> -> one host step per line
  sed -n '/^build:/,/^[^ ]/p' "$1" 2>/dev/null | sed -n -E 's/^[[:space:]]+-[[:space:]]+//p'
}

# The staging Drive a plan uploads into is a private Drive on the account, and
# the account has a Drive limit. Every failure after it is created (a refused
# remote validation, a rejected create, a failed provision, a secrets mismatch)
# used to leave it behind, so a run of failed prepares ate the whole limit.
# Verbs that hold a staging Drive name it here; the EXIT trap removes it on a
# non-zero exit, and the success paths clear it (prepare keeps the Drive for
# deploy; deploy and update delete it themselves once the app is live).
STAGING_DRIVE_CLEANUP=""
remove_staging_drive() {
  local drive_id="$1"
  [[ "$drive_id" == drv_* && "$drive_id" != *[!A-Za-z0-9_-]* ]] || return 0
  # Subshell: api_account dies on a non-2xx, and a failed cleanup must never
  # turn into the reason the caller exits.
  ( api_account DELETE "$BASE_URL/api/v1/drives/$drive_id" >/dev/null 2>&1 ) || return 1
}
staging_drive_exit_trap() {
  local rc=$?
  if [[ "$rc" -ne 0 && -n "${STAGING_DRIVE_CLEANUP:-}" && -n "${API_KEY:-}" ]]; then
    if remove_staging_drive "$STAGING_DRIVE_CLEANUP"; then
      echo "staging drive removed ($STAGING_DRIVE_CLEANUP); run prepare again once the cause is fixed" >&2
    else
      echo "staging drive $STAGING_DRIVE_CLEANUP could not be removed; delete it with drive.sh when convenient" >&2
    fi
  fi
  exit "$rc"
}
trap staging_drive_exit_trap EXIT

make_idempotency_key() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 24
  elif command -v node >/dev/null 2>&1; then node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("hex"))'
  else die "deploy requires openssl or node for a high-entropy idempotency key"; fi
}

# Global flags may appear anywhere in argv (`fullstack.sh list --client x`
# and `fullstack.sh --client x list` both work). They are stripped here, before
# dispatch, so no verb has to know about them. The value is exported so the
# child invocations ship/up make ("$0" prepare ...) carry the same attribution.
CLIENT="${SHARENOW_FULLSTACK_CLIENT:-}"
global_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --client) [[ $# -ge 2 ]] || die "--client requires a value"; CLIENT="$2"; shift 2 ;;
    --client=*) CLIENT="${1#--client=}"; shift ;;
    *) global_args+=("$1"); shift ;;
  esac
done
set -- ${global_args[@]+"${global_args[@]}"}
if [[ -n "$CLIENT" ]]; then
  normalized_client=$(printf '%s' "$CLIENT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')
  normalized_client="${normalized_client#-}"
  normalized_client="${normalized_client%-}"
  [[ -z "$normalized_client" ]] || CLIENT_HEADER_VALUE="${normalized_client}/fullstack-sh"
  export SHARENOW_FULLSTACK_CLIENT="$CLIENT"
fi

CMD="${1:-}"
case "$CMD" in --help|-h) usage 0 ;; "") usage ;; esac
shift

case "$CMD" in
  init)
    [[ $# -eq 2 ]] || die "usage: fullstack.sh init loop-crm <empty-folder>"
    [[ "$1" == loop-crm ]] || die "unknown Fullstack starter: $1"
    destination="$2"
    if [[ -e "$destination" ]]; then
      [[ -d "$destination" && -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "destination must be empty"
    else
      mkdir -p "$destination"
    fi
    template_dir="$SKILL_DIR/templates/loop-crm"
    [[ -d "$template_dir" ]] || die "loop-crm starter is missing from this skill installation"
    cp -Rp "$template_dir/." "$destination/"
    destination=$(absolute_dir "$destination")
    # The starter's slug becomes the app's address when it is free, so seed it
    # from the folder name rather than shipping the template's fixed label to
    # everyone who inits it.
    init_slug=$(basename "$destination" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | cut -c1-63 | sed 's/^-*//;s/-*$//')
    if [[ -n "$init_slug" && -f "$destination/fullstack.yaml" ]] && grep -qE '^slug:' "$destination/fullstack.yaml"; then
      sed -i.bak -E "s/^slug:.*/slug: $init_slug/" "$destination/fullstack.yaml" && rm -f "$destination/fullstack.yaml.bak"
    else
      init_slug=$(yaml_top_get "$destination/fullstack.yaml" slug)
    fi
    "$JQ_BIN" -n --arg destination "$destination" --arg slug "$init_slug" '{template:"loop-crm",destination:$destination,slug:$slug,next:("Review " + $destination + ", then run fullstack.sh prepare " + $destination + " --dry-run.")}'
    ;;
  prepare)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh prepare <project-folder> [--dry-run]"
    project="$1"; shift; dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in --dry-run) dry=1; shift ;; *) die "unexpected prepare argument: $1" ;; esac
    done
    project=$(absolute_dir "$project")
    contract="$project/fullstack.yaml"
    [[ -f "$contract" ]] || die "project must contain fullstack.yaml at its root"
    manifest=$(project_manifest "$project")
    file_count=$(printf '%s' "$manifest" | "$JQ_BIN" 'length')
    byte_count=$(printf '%s' "$manifest" | "$JQ_BIN" '[.[].size] | add // 0')
    env_names=$(declared_env "$contract")
    triggers=$(declared_triggers "$contract")
    if [[ "$dry" -eq 1 ]]; then
      "$JQ_BIN" -n --arg project "$project" --argjson files "$file_count" --argjson bytes "$byte_count" \
        --argjson requiredSecrets "$env_names" --argjson triggers "$triggers" \
        '{dryRun:true,networkRequests:0,project:$project,contract:"fullstack.yaml",files:$files,bytes:$bytes,requiredSecrets:$requiredSecrets,triggers:$triggers,next:"Run prepare again without --dry-run to stage and remotely validate these exact files."}'
      exit 0
    fi
    load_account_key
    contract_sha=$(file_sha "$contract")
    manifest_sha=$(printf '%s' "$manifest" | text_sha)
    bundle_hash=$(printf '%s\n%s\n' "$contract_sha" "$manifest_sha" | text_sha)
    drive_response=$(api_account POST "$BASE_URL/api/v1/drives" "$("$JQ_BIN" -n --arg name "Fullstack staging ${bundle_hash:0:8}" '{name:$name,isDefault:false}')")
    drive_id=$(printf '%s' "$drive_response" | "$JQ_BIN" -r '.drive.id // .id // empty')
    [[ "$drive_id" == drv_* && "$drive_id" != *[!A-Za-z0-9_-]* ]] || die "invalid Drive create response"
    STAGING_DRIVE_CLEANUP="$drive_id"
    stage_project_batch "$drive_id" "$project" "$manifest"
    plan_hash=$(printf '%s\n%s\n%s\n' "$drive_id" "$contract_sha" "$manifest_sha" | text_sha)
    plan_id="fsp_${plan_hash:0:24}"
    receipt=$("$JQ_BIN" -n --arg planId "$plan_id" --arg driveId "$drive_id" \
      --arg projectRoot "$project" --arg contractPath "$contract" \
      --arg contractSha256 "$contract_sha" --arg manifestSha256 "$manifest_sha" \
      --argjson manifest "$manifest" --argjson declaredEnv "$env_names" \
      '{planId:$planId,sourceType:"project",projectRoot:$projectRoot,driveId:$driveId,contractPath:$contractPath,contractSha256:$contractSha256,manifestSha256:$manifestSha256,manifest:$manifest,declaredEnv:$declaredEnv,approved:false,approvedAt:null}')
    validation=$(remote_validate "$receipt")
    receipt=$("$JQ_BIN" -n --argjson receipt "$receipt" --argjson validation "$validation" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '$receipt + {remoteValidation:$validation,validatedAt:$at}')
    write_receipt "$(receipt_path "$plan_id")" "$receipt"
    STAGING_DRIVE_CLEANUP=""
    "$JQ_BIN" -n --arg planId "$plan_id" --arg driveId "$drive_id" --argjson validation "$validation" \
      '$validation + {planId:$planId,state:"validated",driveId:$driveId,approved:false,next:("Review this exact validated plan, then run fullstack.sh approve " + $planId + ".")}'
    ;;
  list)
    [[ $# -eq 0 ]] || die "usage: fullstack.sh list"
    load_account_key; api_account GET "$BASE_URL/api/v1/fullstack" | "$JQ_BIN" .
    ;;
  plan)
    contract=""; drive=""; manifest=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --contract) [[ $# -ge 2 ]] || die "--contract requires a file"; contract="$2"; shift 2 ;;
        --drive) [[ $# -ge 2 ]] || die "--drive requires an id"; drive="$2"; shift 2 ;;
        --manifest) [[ $# -ge 2 ]] || die "--manifest requires a file"; manifest="$2"; shift 2 ;;
        *) die "unexpected plan argument: $1" ;;
      esac
    done
    [[ -n "$contract" && -n "$drive" && -n "$manifest" ]] || die "plan requires --contract, --drive, and --manifest"
    [[ "$drive" == drv_* && "$drive" != *[!A-Za-z0-9_-]* ]] || die "invalid Drive id"
    contract=$(absolute_file "$contract"); manifest=$(absolute_file "$manifest")
    [[ "$(wc -c < "$contract" | tr -d '[:space:]')" -le 65536 ]] || die "contract exceeds 64 KiB"
    normalized=$(normalize_manifest "$manifest")
    contract_sha=$(file_sha "$contract"); manifest_sha=$(printf '%s' "$normalized" | text_sha)
    plan_hash=$(printf '%s\n%s\n%s\n' "$drive" "$contract_sha" "$manifest_sha" | text_sha)
    plan_id="fsp_${plan_hash:0:24}"
    env_names=$(declared_env "$contract")
    receipt=$($JQ_BIN -n --arg planId "$plan_id" --arg driveId "$drive" \
      --arg contractPath "$contract" --arg manifestPath "$manifest" \
      --arg contractSha256 "$contract_sha" --arg manifestSha256 "$manifest_sha" \
      --argjson manifest "$normalized" --argjson declaredEnv "$env_names" \
      '{planId:$planId,sourceType:"legacy",driveId:$driveId,contractPath:$contractPath,manifestPath:$manifestPath,contractSha256:$contractSha256,manifestSha256:$manifestSha256,manifest:$manifest,declaredEnv:$declaredEnv,approved:false,approvedAt:null}')
    write_receipt "$(receipt_path "$plan_id")" "$receipt"
    "$JQ_BIN" -n --arg planId "$plan_id" --arg driveId "$drive" --argjson files "$(printf '%s' "$normalized" | $JQ_BIN 'length')" --argjson declaredEnv "$env_names" \
      '{planId:$planId,state:"planned",driveId:$driveId,fileCount:$files,requiredSecrets:$declaredEnv,next:"Review the plan, then run fullstack.sh approve <plan-id>."}'
    ;;
  validate)
    [[ $# -eq 1 ]] || die "usage: fullstack.sh validate <plan-id>"
    plan_id="$1"; receipt=$(read_receipt "$plan_id"); verify_receipt_content "$receipt"
    load_account_key
    [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')" != project ]] || STAGING_DRIVE_CLEANUP=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId // empty')
    validation=$(remote_validate "$receipt")
    receipt=$("$JQ_BIN" -n --argjson receipt "$receipt" --argjson validation "$validation" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '$receipt + {remoteValidation:$validation,validatedAt:$at}')
    write_receipt "$(receipt_path "$plan_id")" "$receipt"
    STAGING_DRIVE_CLEANUP=""
    "$JQ_BIN" -n --arg planId "$plan_id" --argjson validation "$validation" '$validation + {planId:$planId,state:"validated",provisioned:false}'
    ;;
  approve)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh approve <plan-id> [--for-app <app-id>]"
    plan_id="$1"; shift; target_app=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --for-app) [[ $# -ge 2 ]] || die "--for-app requires an app id"; target_app="$2"; shift 2 ;;
        *) die "unexpected approve argument: $1" ;;
      esac
    done
    [[ -z "$target_app" ]] || valid_app_id "$target_app"
    receipt=$(read_receipt "$plan_id"); verify_receipt_content "$receipt"
    approved=$($JQ_BIN -n --argjson receipt "$receipt" --arg approvedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg targetAppId "$target_app" \
      '$receipt + {approved:true,approvedAt:$approvedAt,targetAppId:(if $targetAppId == "" then null else $targetAppId end)}')
    write_receipt "$(receipt_path "$plan_id")" "$approved"
    "$JQ_BIN" -n --arg planId "$plan_id" --arg targetAppId "$target_app" \
      '{planId:$planId,approved:true,targetAppId:(if $targetAppId == "" then null else $targetAppId end),next:(if $targetAppId == "" then ("Deploy this exact plan with fullstack.sh deploy " + $planId + ".") else ("Update " + $targetAppId + " with fullstack.sh update " + $targetAppId + " " + $planId + ".") end)}'
    ;;
  deploy)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh deploy <plan-id> [--secrets-from <mode-600-json-file>] [--dry-run]"
    plan_id="$1"; shift; secrets_file=""; dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --secrets-from) [[ $# -ge 2 ]] || die "--secrets-from requires a file"; secrets_file="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) die "unexpected deploy argument: $1" ;;
      esac
    done
    receipt=$(read_receipt "$plan_id")
    [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.approved')" == true ]] || die "Fullstack plan is not approved; review it and run fullstack.sh approve $plan_id"
    target_app=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.targetAppId // empty')
    [[ -z "$target_app" ]] || die "plan is approved for updating $target_app; use fullstack.sh update $target_app $plan_id"
    verify_receipt_content "$receipt"
    if [[ "$dry" -eq 0 && "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')" == project ]]; then
      STAGING_DRIVE_CLEANUP=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId // empty')
    fi
    env_json='{}'
    if [[ -n "$secrets_file" ]]; then
      secrets_file=$(absolute_file "$secrets_file")
      [[ "$(file_mode "$secrets_file")" == 600 ]] || die "secret file must have mode 600"
      env_json=$($JQ_BIN -ce 'if type == "object" and all(to_entries[]; (.key|test("^[A-Z_][A-Z0-9_]*$")) and (.value|type=="string")) then . else error("invalid secret map") end' "$secrets_file" 2>/dev/null) || die "secret file must be a JSON object of string values"
      declared=$(printf '%s' "$receipt" | "$JQ_BIN" -c '.declaredEnv')
      provided=$(printf '%s' "$env_json" | "$JQ_BIN" -c 'keys | sort')
      [[ "$provided" == "$declared" ]] || die "secret file keys must exactly match the contract env list"
    elif [[ "$dry" -eq 0 ]]; then
      # A dry run provisions nothing and contacts nothing, so it has no use for
      # the secrets file; only the real deploy needs the declared env values.
      [[ "$(printf '%s' "$receipt" | "$JQ_BIN" '.declaredEnv | length')" -eq 0 ]] || die "this contract requires --secrets-from with a mode-600 JSON file"
    fi
    if [[ "$dry" -eq 1 ]]; then
      "$JQ_BIN" -n --arg planId "$plan_id" '{dryRun:true,planId:$planId,approved:true,localContentVerified:true,remoteValidated:false,networkRequests:0,next:"Run deploy again without --dry-run to repeat remote validation and provision this exact plan."}'
      exit 0
    fi
    load_account_key
    validation=$(remote_validate "$receipt" "$env_json")
    contract_path=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
    yaml=$(cat "$contract_path")
    body=$($JQ_BIN -n --arg yaml "$yaml" --arg driveId "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')" --argjson manifest "$(printf '%s' "$receipt" | "$JQ_BIN" -c '.manifest')" --argjson env "$env_json" '{yaml:$yaml,driveId:$driveId,manifest:$manifest,env:$env}')
    idem=$(make_idempotency_key)
    created=$(api_account POST "$BASE_URL/api/v1/fullstack" "$body" "$idem")
    unset body env_json yaml validation
    app_id=$(printf '%s' "$created" | "$JQ_BIN" -r '.appId // empty')
    claim_token=$(printf '%s' "$created" | "$JQ_BIN" -r '.claimToken // empty')
    valid_app_id "$app_id"; [[ "$claim_token" == clm_* ]] || die "invalid Fullstack create response"
    # The address the server assigned, and whether it is the one the contract
    # asked for. An older server answers without slugState; the receipt then
    # carries only what it did say.
    deploy_slug=$(printf '%s' "$created" | "$JQ_BIN" -r '.slug // empty')
    deploy_requested_slug=$(printf '%s' "$created" | "$JQ_BIN" -r '.requestedSlug // empty')
    deploy_slug_state=$(printf '%s' "$created" | "$JQ_BIN" -r '.slugState // empty')
    state="provisioning"; waited=0; status='{}'
    while [[ "$state" == provisioning && "$waited" -lt 180 ]]; do
      sleep 2; waited=$((waited + 2)); status=$(api_account GET "$BASE_URL/api/v1/fullstack/$app_id/status"); state=$(printf '%s' "$status" | "$JQ_BIN" -r '.state // empty')
    done
    [[ "$state" == live || "$state" == failed ]] || die "Fullstack app did not reach a final state (state: ${state:-unknown})"
    if [[ "$state" == failed ]]; then
      failure_code=$(printf '%s' "$status" | "$JQ_BIN" -r '.failureCode // "provision_unknown"')
      cleanup_body=$("$JQ_BIN" -n --arg token "$claim_token" '{token:$token}')
      api_account DELETE "$BASE_URL/api/v1/fullstack/$app_id" "$cleanup_body" >/dev/null || true
      unset claim_token created cleanup_body
      die "Fullstack provisioning failed at $failure_code. Cleanup of the disposable app was requested; fix the cause and run prepare again"
    fi
    url=$(printf '%s' "$status" | "$JQ_BIN" -r '.url // empty')
    [[ -n "$url" ]] && valid_branded_url "$url" || die "invalid Fullstack live URL"
    api_account POST "$BASE_URL/api/v1/fullstack/$app_id/claim" "$($JQ_BIN -n --arg token "$claim_token" '{token:$token}')" >/dev/null
    unset claim_token created
    # A deploy from a prepared project folder is that folder's first create:
    # write the identity back exactly as `up` does, so the next `up` there
    # updates this app instead of reading the folder as a brand-new one.
    if [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')" == project && -f "$contract_path" ]] \
      && ! grep -qE '^app_id:' "$contract_path"; then
      printf 'app_id: %s\n' "$app_id" | cat - "$contract_path" > "$contract_path.tmp" && mv "$contract_path.tmp" "$contract_path"
      echo "==> wrote app_id: $app_id into fullstack.yaml; the next up here updates this app" >&2
    fi
    if [[ "$deploy_slug_state" == taken && -n "$deploy_requested_slug" ]]; then
      echo "==> note: contract asked for slug: $deploy_requested_slug but that address is taken; the app lives at ${deploy_slug:-a generated address}; run 'rename $app_id <other>' or update the contract's slug to match" >&2
    fi
    # The per-deploy source grant for a SPAWN lives on the status route, not on
    # the create response: a spawn returns while the app is still provisioning.
    # Read it only NOW, after the claim - the grant is a write credential for the
    # app's source, so the server hands it to an account with a role on the app,
    # which this caller does not have until the claim lands.
    source_grant=$(api_account GET "$BASE_URL/api/v1/fullstack/$app_id/status" 2>/dev/null | "$JQ_BIN" -c '.source // empty' 2>/dev/null || true)
    install_canonical_secrets "$app_id" "$secrets_file"
    staging_drive="not_applicable"
    if [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')" == project ]]; then
      drive_id=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')
      if remove_staging_drive "$drive_id"; then
        staging_drive="removed"
      else
        staging_drive="retained"
      fi
      STAGING_DRIVE_CLEANUP=""
    fi
    address_state="unavailable"
    deploy_runtime="worker"
    contract_file=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath // empty')
    if [[ -n "$contract_file" && -f "$contract_file" ]] && grep -qE '^runtime:[[:space:]]*"?container"?[[:space:]]*$' "$contract_file"; then
      deploy_runtime="container"
    fi
    if wait_for_branded_url "$url" "$deploy_runtime"; then address_state="ready"; else address_state="propagating"; fi
    boot_log="[]"
    if [[ "$deploy_runtime" == container ]]; then
      # Surface the container's own boot output in the receipt so a misconfig
      # (missing env, crashed entrypoint) is visible at deploy time instead of
      # at the first deep user action. Best-effort: a logs failure never
      # fails the deploy.
      boot_log=$(api_account POST "$BASE_URL/api/v1/fullstack/$app_id/logs" '{"seconds":5}' 2>/dev/null \
        | "$JQ_BIN" -c '[.container.lines // [] | .[-12:][] | .level + " " + .message]' 2>/dev/null) || boot_log="[]"
      [[ -n "$boot_log" ]] || boot_log="[]"
    fi
    [[ -n "${source_grant:-}" ]] || source_grant="null"
    "$JQ_BIN" -n --arg appId "$app_id" --arg state "$state" --arg url "$url" --arg addressState "$address_state" --arg stagingDrive "$staging_drive" \
      --arg runtime "$deploy_runtime" --argjson bootLog "$boot_log" --argjson source "$source_grant" \
      --arg slug "$deploy_slug" --arg requestedSlug "$deploy_requested_slug" --arg slugState "$deploy_slug_state" \
      '{appId:$appId,state:$state,persistence:"permanent",addressState:$addressState,stagingDrive:$stagingDrive}
      + (if $slug == "" then {} else {slug:$slug} end)
      + (if $slugState == "" then {} else {requestedSlug:(if $requestedSlug == "" then null else $requestedSlug end),slugState:$slugState} end)
      + (if $source == null then {} else {source:$source} end)
      + (if $runtime == "container" then {bootLog:$bootLog} else {} end)
      + (if $addressState == "ready" then {url:$url}
         elif $addressState == "propagating" then {next:("The app is permanent. Its address is still finishing. Run fullstack.sh status " + $appId + " in a few seconds.")}
         else {} end)'
    ;;
  update)
    [[ $# -ge 2 ]] || die "usage: fullstack.sh update <app-id> <plan-id> [--secrets-from <mode-600-json-file>] [--dry-run]"
    app_id="$1"; plan_id="$2"; shift 2; secrets_file=""; dry=0
    valid_app_id "$app_id"; valid_plan_id "$plan_id"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --secrets-from) [[ $# -ge 2 ]] || die "--secrets-from requires a file"; secrets_file="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) die "unexpected update argument: $1" ;;
      esac
    done
    receipt=$(read_receipt "$plan_id")
    [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.approved')" == true ]] || die "Fullstack plan is not approved; review it and run fullstack.sh approve $plan_id"
    target_app=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.targetAppId // empty')
    [[ -n "$target_app" ]] || die "plan approval is not bound to an app; run fullstack.sh approve $plan_id --for-app $app_id"
    [[ "$target_app" == "$app_id" ]] || die "plan is approved for a different Fullstack app: $target_app"
    if [[ "$dry" -eq 0 && "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')" == project ]]; then
      STAGING_DRIVE_CLEANUP=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId // empty')
    fi
    verify_receipt_content "$receipt"
    env_json='{}'
    if [[ -n "$secrets_file" ]]; then
      secrets_file=$(absolute_file "$secrets_file")
      [[ "$(file_mode "$secrets_file")" == 600 ]] || die "secret file must have mode 600"
      env_json=$($JQ_BIN -ce 'if type == "object" and all(to_entries[]; (.key|test("^[A-Z_][A-Z0-9_]*$")) and (.value|type=="string")) then . else error("invalid secret map") end' "$secrets_file" 2>/dev/null) || die "secret file must be a JSON object of string values"
      declared=$(printf '%s' "$receipt" | "$JQ_BIN" -c '.declaredEnv')
      extra=$(printf '%s' "$env_json" | "$JQ_BIN" -c --argjson d "$declared" '[keys[] | select(. as $k | $d | index($k) | not)]')
      [[ "$extra" == "[]" ]] || die "secret file has keys the contract does not declare: $extra"
      kept=$(printf '%s' "$declared" | "$JQ_BIN" -r --argjson p "$(printf '%s' "$env_json" | "$JQ_BIN" -c 'keys')" '[.[] | select(. as $k | $p | index($k) | not)] | join(", ")')
      [[ -z "$kept" ]] || echo "==> secrets: keeping the app's existing values for $kept" >&2
    else
      # An update needs no secrets file: every declared name keeps the value the
      # app already has. That is what lets an editor ship code without holding
      # the owner's secrets. A name with no existing value is refused server-side.
      kept=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.declaredEnv | join(", ")')
      [[ -z "$kept" ]] || echo "==> secrets: none given; keeping the app's existing values for $kept" >&2
    fi
    if [[ "$dry" -eq 1 ]]; then
      "$JQ_BIN" -n --arg appId "$app_id" --arg planId "$plan_id" '{dryRun:true,action:"update",appId:$appId,planId:$planId,approved:true,localContentVerified:true,remoteValidated:false,networkRequests:0,next:"Run update again without --dry-run to revalidate and update this existing app in place."}'
      exit 0
    fi
    load_account_key
    validation=$(remote_validate "$receipt" "$env_json")
    contract_path=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
    yaml=$(cat "$contract_path")
    body=$($JQ_BIN -n --arg yaml "$yaml" --arg driveId "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')" --argjson manifest "$(printf '%s' "$receipt" | "$JQ_BIN" -c '.manifest')" --argjson env "$env_json" '{yaml:$yaml,driveId:$driveId,manifest:$manifest,env:$env}')
    # The freshness claim comes from the stamp in the folder this plan was
    # prepared from, and only when that stamp names THIS app: a folder pulled
    # for one app must not silently vouch for another.
    update_root=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.projectRoot // empty')
    update_expected=""
    if [[ -n "$update_root" && -d "$update_root" ]]; then
      if [[ "$(source_stamp_slug "$update_root")" == "$app_id" ]]; then
        update_expected="$(source_stamp_version "$update_root")"
      fi
    fi
    updated=$(api_update_app "$BASE_URL/api/v1/fullstack/$app_id" "$body" "$update_expected" "${update_root:-$PWD}" "$app_id")
    unset body env_json yaml validation
    [[ "$(printf '%s' "$updated" | "$JQ_BIN" -r '.appId // empty')" == "$app_id" ]] || die "Fullstack update response changed the app id"
    [[ "$(printf '%s' "$updated" | "$JQ_BIN" -r '.updated // false')" == true ]] || die "Fullstack update did not confirm success"
    install_canonical_secrets "$app_id" "$secrets_file"
    staging_drive="not_applicable"
    if [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')" == project ]]; then
      drive_id=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')
      if remove_staging_drive "$drive_id"; then
        staging_drive="removed"
      else
        staging_drive="retained"
      fi
      STAGING_DRIVE_CLEANUP=""
    fi
    boot_log="[]"
    if grep -qE '^runtime:[[:space:]]*"?container"?[[:space:]]*$' "$contract_path" 2>/dev/null; then
      # A container update replaces the instance; show its fresh boot output
      # in the receipt (best-effort - a logs failure never fails the update).
      boot_log=$(api_account POST "$BASE_URL/api/v1/fullstack/$app_id/logs" '{"seconds":5}' 2>/dev/null \
        | "$JQ_BIN" -c '[.container.lines // [] | .[-12:][] | .level + " " + .message]' 2>/dev/null) || boot_log="[]"
      [[ -n "$boot_log" ]] || boot_log="[]"
      printf '%s' "$updated" | "$JQ_BIN" --arg stagingDrive "$staging_drive" --argjson bootLog "$boot_log" '. + {stagingDrive:$stagingDrive,bootLog:$bootLog}'
    else
      printf '%s' "$updated" | "$JQ_BIN" --arg stagingDrive "$staging_drive" '. + {stagingDrive:$stagingDrive}'
    fi
    ;;
  push)
    # Build + push a container image for `runtime: container` contracts.
    # Lane 1 (default): local Docker builds the Dockerfile and pushes with
    # short-lived registry credentials. Lane 2 (--assemble): no Docker needed -
    # prebuilt artifacts are staged and assembled server-side.
    assemble=0; folder=""; dockerfile="Dockerfile"; img_name=""; base=""; entrypoint=""; envs='[]'; artifacts='[]'
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --assemble) assemble=1; shift ;;
        --dockerfile) [[ $# -ge 2 ]] || die "--dockerfile requires a file"; dockerfile="$2"; shift 2 ;;
        --name) [[ $# -ge 2 ]] || die "--name requires a name"; img_name="$2"; shift 2 ;;
        --base) [[ $# -ge 2 ]] || die "--base requires an image ref"; base="$2"; shift 2 ;;
        --entrypoint) [[ $# -ge 2 ]] || die "--entrypoint requires a path"; entrypoint="$2"; shift 2 ;;
        --env) [[ $# -ge 2 ]] || die "--env requires KEY=VALUE"; envs=$(printf '%s' "$envs" | "$JQ_BIN" -c --arg e "$2" '. + [$e]'); shift 2 ;;
        --artifact) [[ $# -ge 2 ]] || die "--artifact requires local:dest[:mode]"; artifacts=$(printf '%s' "$artifacts" | "$JQ_BIN" -c --arg a "$2" '. + [$a]'); shift 2 ;;
        -*) die "unexpected push argument: $1" ;;
        *) folder="$1"; shift ;;
      esac
    done
    load_account_key
    [[ -n "$img_name" ]] || { [[ -n "$folder" ]] && img_name=$(basename "$folder" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/^-*//;s/-*$//' | cut -c1-40); }
    [[ "$img_name" == [a-z0-9]* && "$img_name" != *[!a-z0-9-]* ]] || die "image name must be lowercase [a-z0-9-]; pass --name"
    if [[ "$assemble" -eq 0 ]]; then
      [[ -n "$folder" ]] || die "usage: fullstack.sh push <folder> [--dockerfile F] [--name n]  (or push --assemble ...)"
      folder=$(absolute_dir "$folder")
      command -v docker >/dev/null 2>&1 || die "push needs local Docker (or use push --assemble for the no-Docker lane)"
      docker info >/dev/null 2>&1 || die "the Docker daemon is not running (or use push --assemble)"
      creds=$(api_account POST "$BASE_URL/api/v1/fullstack/registry-auth" '{}')
      reg_host=$(printf '%s' "$creds" | "$JQ_BIN" -r '.registryHost'); reg_user=$(printf '%s' "$creds" | "$JQ_BIN" -r '.username')
      repo_prefix=$(printf '%s' "$creds" | "$JQ_BIN" -r '.repositoryPrefix')
      repo="${repo_prefix}${img_name}"
      printf '%s' "$creds" | "$JQ_BIN" -r '.password' | docker login "$reg_host" --username "$reg_user" --password-stdin >/dev/null 2>&1 || die "registry login failed"
      docker build --platform linux/amd64 -f "$folder/$dockerfile" -t "$repo:sharenow" "$folder" >&2 || die "docker build failed"
      docker push "$repo:sharenow" >&2 || die "docker push failed"
      # Select the RepoDigest for THIS repo (RepoDigests[0] may be a base
      # image's index digest, not the CF-registry manifest we just pushed).
      image_ref=$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "$repo:sharenow" 2>/dev/null | grep -E "^${repo}@sha256:[0-9a-f]{64}$" | head -1)
      [[ -n "$image_ref" ]] || die "could not read the pushed image digest for $repo"
    else
      [[ -n "$base" && -n "$entrypoint" ]] || die "push --assemble requires --base and --entrypoint"
      [[ "$(printf '%s' "$artifacts" | "$JQ_BIN" 'length')" -gt 0 ]] || die "push --assemble requires at least one --artifact local:dest[:mode]"
      drive_response=$(api_account POST "$BASE_URL/api/v1/drives" "$("$JQ_BIN" -n --arg name "Image staging $img_name" '{name:$name,isDefault:false}')")
      drive_id=$(printf '%s' "$drive_response" | "$JQ_BIN" -r '.drive.id // .id // empty')
      [[ "$drive_id" == drv_* ]] || die "invalid Drive create response"
      manifest='[]'; specs='[]'
      while IFS= read -r spec; do
        local_path="${spec%%:*}"; rest="${spec#*:}"; dest="${rest%%:*}"; mode="0755"
        [[ "$rest" == *:* ]] && mode="${rest##*:}"
        local_path=$(absolute_file "$local_path")
        size=$(wc -c < "$local_path" | tr -d '[:space:]'); sha=$(file_sha "$local_path")
        rel="artifact-$(printf '%s' "$dest" | tr -c 'a-zA-Z0-9._-' '-')"
        entry=$("$JQ_BIN" -n --arg path "$rel" --arg sha "$sha" --argjson size "$size" '{path:$path,sha256:$sha,size:$size}')
        manifest=$(printf '%s' "$manifest" | "$JQ_BIN" -c --argjson e "$entry" '. + [$e]')
        specs=$(printf '%s' "$specs" | "$JQ_BIN" -c --arg path "$rel" --arg dest "$dest" --argjson mode "$((8#$mode))" '. + [{path:$path,dest:$dest,mode:$mode}]')
        # Reuse the shared start/PUT/finalize helper (stage_project_file reads
        # <root>/<rel>): copy the artifact under its manifest name into a temp root.
        tmpdir=$(mktemp -d); cp "$local_path" "$tmpdir/$rel"
        stage_project_file "$drive_id" "$tmpdir" "$entry"
        rm -rf "$tmpdir"
      done < <(printf '%s' "$artifacts" | "$JQ_BIN" -r '.[]')
      body=$("$JQ_BIN" -n --arg name "$img_name" --arg base "$base" --arg entrypoint "$entrypoint" \
        --argjson env "$envs" --arg driveId "$drive_id" --argjson manifest "$manifest" --argjson artifacts "$specs" \
        '{name:$name,base:$base,entrypoint:$entrypoint,env:$env,driveId:$driveId,manifest:$manifest,artifacts:$artifacts}')
      assembled=$(api_account POST "$BASE_URL/api/v1/fullstack/images" "$body")
      image_ref=$(printf '%s' "$assembled" | "$JQ_BIN" -r '.image // empty')
      [[ -n "$image_ref" ]] || die "assembly did not return an image reference"
      api_account DELETE "$BASE_URL/api/v1/drives/$drive_id" >/dev/null 2>&1 || true
    fi
    if [[ -n "$folder" && -f "$folder/fullstack.yaml" ]] && grep -q "runtime: container" "$folder/fullstack.yaml"; then
      # Scope the pin to the container: block so only container.image moves -
      # an unscoped match would rewrite any other indented image: key too.
      sed -i.bak -E "/^container:/,/^[^ ]/ s|^([[:space:]]*image:).*|\\1 $image_ref|" "$folder/fullstack.yaml" && rm -f "$folder/fullstack.yaml.bak"
      updated_yaml="true"
    else
      updated_yaml="false"
    fi
    if [[ "$updated_yaml" == true ]]; then
      next_step="fullstack.yaml now pins this exact reference; ship the folder."
    else
      next_step="Pin this exact reference as container.image in fullstack.yaml, then ship the folder."
    fi
    "$JQ_BIN" -n --arg image "$image_ref" --arg updatedYaml "$updated_yaml" --arg next "$next_step" \
      '{image:$image,updatedYaml:($updatedYaml=="true"),next:$next}'
    ;;
  up)
    # One-verb create-or-update: fullstack.yaml is the whole deploy contract.
    # Inference rule: act on what is present; refuse loudly when the folder
    # shape is ambiguous or known-dangerous. No modes, no flags to learn.
    up_folder="."; up_secrets=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --secrets-from) [[ $# -ge 2 ]] || die "--secrets-from requires a file"; up_secrets="$2"; shift 2 ;;
        -*) die "unexpected up argument: $1" ;;
        *) up_folder="$1"; shift ;;
      esac
    done
    up_folder=$(absolute_dir "$up_folder")
    up_yaml="$up_folder/fullstack.yaml"

    # 1. First contact: a bare worker folder gets its contract synthesized.
    if [[ ! -f "$up_yaml" ]]; then
      [[ -f "$up_folder/worker.js" ]] || die "no fullstack.yaml here and no worker.js to infer one from; write the contract first"
      {
        echo "code:"
        echo "  worker: worker.js"
        [[ -f "$up_folder/schema.sql" ]] && echo "  schema: schema.sql"
      } > "$up_yaml"
      echo "==> synthesized $up_yaml from the folder shape; env/bindings additions go there" >&2
    fi

    # 2. Identity: app_id in the yaml wins; absent means create-and-write-back.
    up_app_id=$(yaml_top_get "$up_yaml" app_id)
    [[ -z "$up_app_id" ]] || valid_app_id "$up_app_id"
    # Say what a missing app_id MEANS before anything is built or staged: a
    # folder that declares env but names no app would be created as a NEW app,
    # and the "requires --secrets-from" refusal deploy would print hides that.
    # The natural recovery from that message (supplying the secrets) would
    # mint a duplicate app; naming the real cause prevents it.
    if [[ -z "$up_app_id" && -z "$up_secrets" ]] && [[ "$(declared_env "$up_yaml" | "$JQ_BIN" 'length')" -gt 0 ]]; then
      die "no app_id in fullstack.yaml: this folder would create a NEW app, and its declared env needs --secrets-from <mode-600 json>. To update an existing app add  app_id: <id>  (find it with fullstack.sh list)"
    fi

    # 3. Container build: run declared host steps, then docker build + push.
    if grep -qE '^runtime:[[:space:]]*"?container"?[[:space:]]*$' "$up_yaml"; then
      up_df=$(yaml_build_get "$up_yaml" dockerfile)
      if [[ -z "$up_df" ]]; then
        up_found=$(cd "$up_folder" && ls Dockerfile Dockerfile.* 2>/dev/null | grep -v dockerignore || true)
        up_count=$(printf '%s\n' "$up_found" | grep -c . || true)
        if [[ "$up_count" -eq 1 ]]; then up_df="$up_found"
        elif [[ "$up_count" -gt 1 ]]; then
          die "this folder has $up_count Dockerfiles; declare which one in fullstack.yaml under build: as  dockerfile: <file>"
        fi
      fi
      up_steps=$(yaml_build_steps "$up_yaml")
      if [[ -n "$up_df" ]]; then
        # A Next.js bundle built inside docker is known to corrupt silently;
        # only a declared host build (steps:) is safe to ship.
        if [[ -z "$up_steps" && -f "$up_folder/package.json" ]] && grep -q '"next"' "$up_folder/package.json"; then
          die "Next.js app: in-docker builds corrupt the bundle. Declare a host build in fullstack.yaml under build: with  steps: [npm run build]  and  env_hold: .env.local  and COPY the prebuilt .next in your Dockerfile"
        fi
        up_hold=$(yaml_build_get "$up_yaml" env_hold)
        up_held=""
        if [[ -n "$up_hold" && -f "$up_folder/$up_hold" ]]; then
          mv "$up_folder/$up_hold" "$up_folder/$up_hold.up-hold" && up_held="yes"
          echo "==> holding $up_hold aside for the build" >&2
        fi
        up_rc=0
        if [[ -n "$up_steps" ]]; then
          while IFS= read -r up_step; do
            [[ -n "$up_step" ]] || continue
            echo "==> host step: $up_step" >&2
            # Steps write to stderr: up's stdout carries ONLY the receipt JSON,
            # and a consumer piping it to jq must never see build output (or
            # kill the build with EPIPE when it stops reading).
            (cd "$up_folder" && bash -c "$up_step") >&2 || { up_rc=$?; break; }
          done <<< "$up_steps"
        fi
        [[ -z "$up_held" ]] || mv "$up_folder/$up_hold.up-hold" "$up_folder/$up_hold"
        [[ "$up_rc" -eq 0 ]] || die "build step failed (exit $up_rc)"
        up_name=$(yaml_build_get "$up_yaml" name)
        up_push_args=(--dockerfile "$up_df")
        [[ -z "$up_name" ]] || up_push_args+=(--name "$up_name")
        "$0" push "$up_folder" "${up_push_args[@]}" >&2 || die "up failed at push"
      fi
      grep -qE '^[[:space:]]+image:.*@sha256:[0-9a-f]{64}' "$up_yaml" \
        || die "container.image is not digest-pinned and no Dockerfile is present to build; add one or pin an image"
    fi

    # 4. Ship (create or update). A known app reuses its canonical secrets
    # file automatically; an explicit --secrets-from always wins.
    up_ship_args=()
    if [[ -n "$up_app_id" ]]; then
      up_ship_args+=(--app "$up_app_id")
      if [[ -z "$up_secrets" && -f "$(canonical_secrets_path "$up_app_id")" ]]; then
        up_secrets=$(canonical_secrets_path "$up_app_id")
        echo "==> secrets: canonical file for $up_app_id" >&2
      fi
    fi
    [[ -z "$up_secrets" ]] || up_ship_args+=(--secrets-from "$up_secrets")
    # `ship` already printed the refusal; exit 3 is a contract an agent branches
    # on, so it must survive the subshell rather than being flattened into the
    # generic exit 1 that `die` produces.
    # Remember the actual folder and its provenance before submission. A
    # concurrent editor must never receive a stamp for bytes we did not send.
    up_original_stamp=$(cat "$(source_stamp_path "$up_folder")" 2>/dev/null || true)
    up_original_version=$(source_stamp_version "$up_folder")
    up_original_slug=$(source_stamp_slug "$up_folder")
    up_ship_rc=0
    up_receipt=$("$0" ship "$up_folder" ${up_ship_args[@]+"${up_ship_args[@]}"}) || up_ship_rc=$?
    if [[ "$up_ship_rc" -ne 0 ]]; then
      [[ "$up_ship_rc" -ne 3 ]] || exit 3
      die "up failed at ship"
    fi

    # Compare with the manifest accepted by prepare, not an earlier walk.
    up_plan_id=$(printf '%s' "$up_receipt" | "$JQ_BIN" -r '.planId // empty')
    up_submitted_manifest=$(read_receipt "$up_plan_id" | "$JQ_BIN" -c '.manifest | sort_by(.path)') || up_submitted_manifest=""
    up_new_id=$(printf '%s' "$up_receipt" | "$JQ_BIN" -r '.appId // empty')
    # deploy (reached through ship) writes app_id: into a prepared folder's
    # yaml itself, so on a first create the folder may already carry the
    # line. Re-read the file rather than trusting the pre-ship value: writing
    # it twice made the next prepare fail on a duplicate YAML key.
    up_written_back=false
    if [[ -z "$up_app_id" && -n "$up_new_id" ]] && grep -qE "^app_id:[[:space:]]*${up_new_id}[[:space:]]*$" "$up_yaml"; then
      up_written_back=true
    fi
    # Compare with what prepare accepted. A yaml that differs ONLY by the
    # app_id line deploy just prepended is still the bytes we shipped.
    up_current_manifest=$(project_manifest "$up_folder" 2>/dev/null) || up_current_manifest=""
    if [[ "$up_written_back" == true && -n "$up_current_manifest" ]]; then
      up_current_manifest=$(printf '%s' "$up_current_manifest" | "$JQ_BIN" -c 'map(select(.path != "fullstack.yaml"))')
      up_submitted_manifest=$(printf '%s' "$up_submitted_manifest" | "$JQ_BIN" -c 'map(select(.path != "fullstack.yaml"))')
    fi
    up_current_stamp=$(cat "$(source_stamp_path "$up_folder")" 2>/dev/null || true)
    up_local_unchanged=false
    if [[ -n "$up_current_manifest" && "$up_current_manifest" == "$up_submitted_manifest" && "$up_current_stamp" == "$up_original_stamp" ]]; then
      up_local_unchanged=true
    fi

    # 5. Write the identity back on first create so the next up updates,
    # unless deploy already did (never a second app_id: line).
    if [[ -z "$up_app_id" && -n "$up_new_id" ]] && ! grep -qE '^app_id:' "$up_yaml"; then
      printf 'app_id: %s\n' "$up_new_id" | cat - "$up_yaml" > "$up_yaml.tmp" && mv "$up_yaml.tmp" "$up_yaml"
      echo "==> wrote app_id: $up_new_id into fullstack.yaml; the next up here updates this app" >&2
    fi
    # A contract slug that disagrees with the live app reads like a rename,
    # but up never renames (and create assigns a generated address) - say so
    # instead of ignoring it silently. Create receipts carry no slug key, so
    # fall back to the address in the url.
    up_yaml_slug=$(yaml_top_get "$up_yaml" slug)
    up_live_slug=$(printf '%s' "$up_receipt" | "$JQ_BIN" -r '.slug // empty')
    if [[ -z "$up_live_slug" ]]; then
      up_live_slug=$(printf '%s' "$up_receipt" | "$JQ_BIN" -r '.url // empty' | sed -nE 's|^https://([^./]+)\..*$|\1|p')
    fi
    up_note_id="${up_app_id:-$up_new_id}"
    # On a create the server already decided (and deploy printed) whether the
    # contract's slug was honored or taken; only an update, or a create against
    # an older server that reports no slugState, still needs the mismatch note.
    up_slug_state=$(printf '%s' "$up_receipt" | "$JQ_BIN" -r '.slugState // empty')
    if [[ -n "$up_note_id" && -n "$up_yaml_slug" && -n "$up_live_slug" && "$up_yaml_slug" != "$up_live_slug" ]] \
      && [[ -n "$up_app_id" || -z "$up_slug_state" ]]; then
      echo "==> note: contract says slug: $up_yaml_slug but the live app is $up_live_slug; up never renames - run 'rename $up_note_id $up_yaml_slug' if the move is intended, or update the contract's slug to match" >&2
    fi
    # 6. Send the deployed-from folder as this deploy's source (KTD6, R2).
    #
    # The app is already live; this is bookkeeping that makes the resource's repo
    # hold real source instead of just a contract. It runs AFTER the app_id
    # write-back so the freshly written `app_id:` line is part of what gets
    # recorded, and it can NEVER fail `up`: every path inside prints one
    # `source: ...` line to stderr and returns 0.
    up_target_id="${up_app_id:-$up_new_id}"
    up_seq=$(printf '%s' "$up_receipt" | "$JQ_BIN" -r '.source.deploySeq // empty')
    up_token=$(printf '%s' "$up_receipt" | "$JQ_BIN" -r '.source.sourceToken // empty')
    up_source_ready=$(printf '%s' "$up_receipt" | "$JQ_BIN" '(.source.ready == true) and (.source.version | type == "string") and (.source.version | tostring | test("^(0|[1-9][0-9]{0,15})$"))')
    if [[ "$up_source_ready" == true && -n "$up_target_id" ]]; then
      # The platform retained the original upload before deploying. Its ready
      # source is available even while background Git history is catching up.
      up_seq=$(printf '%s' "$up_receipt" | "$JQ_BIN" -r '.source.version')
      up_stamp_safe=false
      if [[ "$up_local_unchanged" == true && "$(printf '%s' "$up_receipt" | "$JQ_BIN" -r '.state // empty')" == live ]]; then
        if [[ -z "$up_original_stamp" ]]; then
          up_stamp_safe=true
        elif [[ "$up_original_slug" == "$up_target_id" ]] && "$JQ_BIN" -en --arg old "$up_original_version" --arg new "$up_seq" \
          '($old | test("^(0|[1-9][0-9]{0,15})$")) and (($new | tonumber) > ($old | tonumber))' >/dev/null 2>&1; then
          up_stamp_safe=true
        fi
      fi
      if [[ "$up_stamp_safe" == true ]]; then
        source_write_stamp "$up_folder" fullstack "$up_target_id" "$up_seq" || true
      fi
    elif [[ -z "$up_target_id" ]]; then
      echo "source: not recorded (no app id)" >&2
    elif [[ -z "$up_seq" || -z "$up_token" ]]; then
      # The platform did not retain this deploy's source and sent no snapshot
      # grant either (an older server, or a deploy that could not open a
      # window). Say exactly that, not "no source window", which read as a
      # problem with a folder that was in fact recorded server-side.
      echo "source: not recorded by this deploy (the server sent no snapshot grant)" >&2
    else
      load_account_key
      send_source_snapshot "$up_target_id" "$up_folder" "$up_seq" "$up_token" >&2 || true
    fi
    unset up_token

    if [[ -n "$up_app_id" ]]; then
      printf '%s' "$up_receipt" | "$JQ_BIN" --argjson ready "$up_source_ready" '. + {upAction:"updated"} | if $ready then .source |= {ready,version,revisionId,history} else del(.source) end'
    else
      printf '%s' "$up_receipt" | "$JQ_BIN" --argjson ready "$up_source_ready" '. + {upAction:"created"} | if $ready then .source |= {ready,version,revisionId,history} else del(.source) end'
    fi
    ;;
  ship)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh ship <project-folder> [--app <app-id>] [--secrets-from <mode-600-json-file>]"
    project="$1"; shift; target_app=""; secrets_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --app) [[ $# -ge 2 ]] || die "--app requires an app id"; target_app="$2"; shift 2 ;;
        --secrets-from) [[ $# -ge 2 ]] || die "--secrets-from requires a file"; secrets_file="$2"; shift 2 ;;
        *) die "unexpected ship argument: $1" ;;
      esac
    done
    [[ -z "$target_app" ]] || valid_app_id "$target_app"
    project=$(absolute_dir "$project")
    prepared=$("$0" prepare "$project") || die "ship failed at prepare"
    ship_plan_id=$(printf '%s' "$prepared" | "$JQ_BIN" -r '.planId // empty')
    valid_plan_id "$ship_plan_id"
    if [[ -n "$target_app" ]]; then
      "$0" approve "$ship_plan_id" --for-app "$target_app" >/dev/null || die "ship failed at approve"
    else
      "$0" approve "$ship_plan_id" >/dev/null || die "ship failed at approve"
    fi
    ship_args=()
    [[ -z "$secrets_file" ]] || ship_args=(--secrets-from "$secrets_file")
    if [[ -n "$target_app" ]]; then
      ship_result=$("$0" update "$target_app" "$ship_plan_id" ${ship_args[@]+"${ship_args[@]}"}) || exit $?
    else
      ship_result=$("$0" deploy "$ship_plan_id" ${ship_args[@]+"${ship_args[@]}"}) || exit $?
    fi
    printf '%s' "$ship_result" | "$JQ_BIN" --arg planId "$ship_plan_id" '. + {planId:$planId}'
    ;;
  secrets)
    [[ $# -ge 2 ]] || die "usage: fullstack.sh secrets check <app-id> [--file <secrets.json>] | secrets set <app-id> <NAME> --value-from <mode-600-file>"
    sub="$1"; app_id="$2"; shift 2
    valid_app_id "$app_id"
    load_account_key
    case "$sub" in
      check)
        sfile="$(canonical_secrets_path "$app_id")"
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --file) [[ $# -ge 2 ]] || die "--file requires a path"; sfile="$2"; shift 2 ;;
            *) die "unexpected secrets check argument: $1" ;;
          esac
        done
        [[ -f "$sfile" ]] || die "no local secrets file at $sfile (pass --file, or redeploy once with --secrets-from to install the canonical copy)"
        status_json=$(api_account GET "$BASE_URL/api/v1/fullstack/$app_id/status")
        salt=$(printf '%s' "$status_json" | "$JQ_BIN" -r '.env.fingerprintSalt // empty')
        [[ -n "$salt" ]] || die "the live app has no fingerprints yet: deploy or update it once (server 1.26+) and retry"
        matches="[]"; rotate="[]"; missing_local="[]"; live_names="[]"
        while IFS=$'\t' read -r name fp; do
          [[ -n "$name" ]] || continue
          live_names=$(printf '%s' "$live_names" | "$JQ_BIN" -c --arg n "$name" '. + [$n]')
          if [[ "$("$JQ_BIN" -r --arg n "$name" 'has($n)' "$sfile" 2>/dev/null)" != true ]]; then
            missing_local=$(printf '%s' "$missing_local" | "$JQ_BIN" -c --arg n "$name" '. + [$n]')
            continue
          fi
          # Byte-exact: jq -j emits the value verbatim (a trailing newline in a
          # PEM key survives; $(...) substitution would strip it and lie).
          local_fp=$({ printf '%s:' "$salt"; "$JQ_BIN" -j --arg n "$name" '.[$n]' "$sfile"; } | shasum -a 256 | cut -c1-12)
          if [[ "$local_fp" == "$fp" ]]; then
            matches=$(printf '%s' "$matches" | "$JQ_BIN" -c --arg n "$name" '. + [$n]')
          else
            rotate=$(printf '%s' "$rotate" | "$JQ_BIN" -c --arg n "$name" '. + [$n]')
          fi
        done < <(printf '%s' "$status_json" | "$JQ_BIN" -r '.env.keys[]? | [.name, .fingerprint] | @tsv')
        local_only=$("$JQ_BIN" -c --argjson live "$live_names" 'keys - $live' "$sfile")
        "$JQ_BIN" -n --arg file "$sfile" --argjson match "$matches" --argjson rotate "$rotate" \
          --argjson missingLocal "$missing_local" --argjson localOnly "$local_only" \
          '{file:$file,match:$match,rotateNeeded:$rotate,missingLocal:$missingLocal,localOnly:$localOnly}
           + (if ($rotate|length)==0 and ($missingLocal|length)==0 then {verdict:"local file matches the live app"} else {verdict:"rotate the listed keys or restore the file"} end)'
        ;;
      set)
        [[ $# -ge 1 ]] || die "usage: fullstack.sh secrets set <app-id> <NAME> --value-from <mode-600-file>"
        env_name="$1"; shift; value_file=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --value-from) [[ $# -ge 2 ]] || die "--value-from requires a path"; value_file="$2"; shift 2 ;;
            *) die "unexpected secrets set argument: $1 (values never travel as arguments)" ;;
          esac
        done
        [[ "$env_name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "invalid environment name"
        [[ -n "$value_file" && -f "$value_file" ]] || die "--value-from <mode-600-file> is required (the file's contents become the value; values never travel as arguments)"
        [[ "$(file_mode "$value_file")" == 600 ]] || die "value file must have mode 600"
        new_value=$(cat "$value_file")
        # Strip exactly one trailing newline (editors add one; keys rarely want it).
        new_value="${new_value%$'\n'}"
        [[ -n "$new_value" ]] || die "value file is empty"
        body=$("$JQ_BIN" -n --rawfile v "$value_file" '{value:($v|rtrimstr("\n"))}')
        result=$(api_account PUT "$BASE_URL/api/v1/fullstack/$app_id/env/$env_name" "$body")
        unset body
        canonical="$(canonical_secrets_path "$app_id")"
        if [[ -f "$canonical" ]]; then
          tmp="$canonical.tmp.$$" && "$JQ_BIN" --arg n "$env_name" --arg v "$new_value" '.[$n]=$v' "$canonical" > "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$canonical"
          canonical_state="updated"
        else
          canonical_state="absent (redeploy once with --secrets-from to install it)"
        fi
        unset new_value
        printf '%s' "$result" | "$JQ_BIN" --arg canonical "$canonical_state" '. + {canonicalFile:$canonical}'
        ;;
      *) die "unknown secrets subcommand: $sub (use check or set)" ;;
    esac
    ;;
  status)
    [[ $# -eq 1 ]] || die "usage: fullstack.sh status <app-id>"
    valid_app_id "$1"; load_account_key; api_account GET "$BASE_URL/api/v1/fullstack/$1/status" | "$JQ_BIN" .
    ;;
  pull)
    # The app's live source into a folder, stamped. account.sh owns the export
    # + unpack + stamp logic for Sites and apps alike; this is the app-shaped
    # entry point so the verb is discoverable from the Fullstack helper.
    [[ $# -ge 2 ]] || die "usage: fullstack.sh pull <app-id> <dir> [--force]"
    pull_app="$1"; pull_dir="$2"; shift 2; valid_app_id "$pull_app"
    pull_args=()
    while [[ $# -gt 0 ]]; do
      case "$1" in --force) pull_args+=(--force); shift ;; *) die "unexpected pull argument: $1" ;; esac
    done
    [[ -x "$SCRIPT_DIR/account.sh" ]] || die "account.sh is missing next to fullstack.sh; reinstall the skill"
    exec "$SCRIPT_DIR/account.sh" pull --app "$pull_app" "$pull_dir" ${pull_args[@]+"${pull_args[@]}"}
    ;;
  sql)
    [[ $# -ge 2 ]] || die "usage: fullstack.sh sql <app-id> <select-statement> [--binding <name>]"
    app_id="$1"; sql_text="$2"; shift 2; binding=""
    valid_app_id "$app_id"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --binding) [[ $# -ge 2 ]] || die "--binding requires a name"; binding="$2"; shift 2 ;;
        *) die "unexpected sql argument: $1" ;;
      esac
    done
    load_account_key
    if [[ -n "$binding" ]]; then
      body=$("$JQ_BIN" -cn --arg sql "$sql_text" --arg binding "$binding" '{sql:$sql,binding:$binding}')
    else
      body=$("$JQ_BIN" -cn --arg sql "$sql_text" '{sql:$sql}')
    fi
    api_account POST "$BASE_URL/api/v1/fullstack/$app_id/sql" "$body" | "$JQ_BIN" .
    ;;
  logs)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh logs <app-id> [--seconds <5-60>]"
    app_id="$1"; shift; seconds=""
    valid_app_id "$app_id"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --seconds) [[ $# -ge 2 ]] || die "--seconds requires a number"; seconds="$2"; shift 2 ;;
        *) die "unexpected logs argument: $1" ;;
      esac
    done
    load_account_key
    if [[ -n "$seconds" ]]; then
      [[ "$seconds" != *[!0-9]* && -n "$seconds" ]] || die "--seconds must be a whole number between 5 and 60"
      body=$("$JQ_BIN" -cn --argjson seconds "$seconds" '{seconds:$seconds}')
    else
      body='{}'
    fi
    echo "capturing live Worker events (exercise the app now)..." >&2
    # A capture already running for this app answers 409 with retry_after
    # (the seconds left on its window); wait it out once and retry rather
    # than handing the agent a lock to reason about. Any other failure goes
    # through the shared handler unchanged.
    logs_url="$BASE_URL/api/v1/fullstack/$app_id/logs"
    logs_attempt=0
    while :; do
      logs_attempt=$((logs_attempt + 1))
      logs_tmp=$(mktemp)
      logs_code=$(printf '%s' "$body" | curl --config <(printf 'header = "authorization: Bearer %s"\n' "$API_KEY") -sS -o "$logs_tmp" -w "%{http_code}" -X POST "$logs_url" -H "content-type: application/json" -H "x-sharenow-client: $CLIENT_HEADER_VALUE" --data-binary @-) || logs_code=000
      if [[ "$logs_code" == 409 && "$logs_attempt" -eq 1 ]]; then
        logs_retry=$("$JQ_BIN" -r '.retry_after // empty' "$logs_tmp" 2>/dev/null || true)
        if [[ -n "$logs_retry" && "$logs_retry" != *[!0-9]* ]]; then
          [[ "$logs_retry" -ge 1 ]] || logs_retry=1
          [[ "$logs_retry" -le 60 ]] || logs_retry=60
          rm -f "$logs_tmp"
          echo "a capture is already running; retrying in ${logs_retry}s" >&2
          sleep "$logs_retry"
          continue
        fi
      fi
      http_handle_response "$logs_code" "$logs_tmp" | "$JQ_BIN" .
      break
    done
    ;;
  rename)
    [[ $# -eq 2 ]] || die "usage: fullstack.sh rename <app-id> <new-slug>"
    valid_app_id "$1"; load_account_key
    api_account POST "$BASE_URL/api/v1/fullstack/$1/rename" "$("$JQ_BIN" -cn --arg s "$2" '{slug:$s}')" | "$JQ_BIN" .
    ;;
  delete)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh delete <app-id> --confirm <app-id> [--dry-run]"
    app_id="$1"; shift; confirm=""; dry=0; valid_app_id "$app_id"
    while [[ $# -gt 0 ]]; do case "$1" in --confirm) confirm="$2"; shift 2 ;; --dry-run) dry=1; shift ;; *) die "unexpected delete argument: $1" ;; esac; done
    [[ "$confirm" == "$app_id" ]] || die "delete requires --confirm $app_id"
    if [[ "$dry" -eq 1 ]]; then
      # Say what goes. The owner status carries the managed resource ledger;
      # a receipt that names the database, bucket, and queue is the last
      # chance to notice the wrong app id before an irreversible teardown.
      load_account_key
      del_status=$(api_account GET "$BASE_URL/api/v1/fullstack/$app_id/status" 2>/dev/null) || del_status='{}'
      "$JQ_BIN" -n --arg appId "$app_id" --argjson status "$del_status" '
        {dryRun:true,action:"delete",appId:$appId}
        + (if ($status.url // "") == "" then {} else {url:$status.url} end)
        + {resources:[($status.resources // [])[] | {type:.resourceType,name:.bindingName,id:.externalId}]}
        + {warning:"Permanent. The Worker and every managed resource listed are destroyed with it: all D1 rows, R2 objects, KV entries, and queued messages. There is no snapshot and no undo; export or pull anything you need first."}'
      exit 0
    fi
    load_account_key; api_account DELETE "$BASE_URL/api/v1/fullstack/$app_id" | "$JQ_BIN" .
    ;;
  members)
    [[ $# -eq 1 ]] || die "usage: fullstack.sh members <app-id>"
    valid_app_id "$1"; load_account_key
    api_account GET "$BASE_URL/api/v1/fullstack/$1/members" | "$JQ_BIN" .
    ;;
  invite)
    [[ $# -eq 2 ]] || die "usage: fullstack.sh invite <app-id> <email>"
    valid_app_id "$1"
    [[ "$2" == *@*.* && "$2" != *" "* ]] || die "invite requires a valid email address"
    load_account_key
    api_account POST "$BASE_URL/api/v1/fullstack/$1/members/invite" "$("$JQ_BIN" -cn --arg e "$2" '{email:$e}')" | "$JQ_BIN" .
    ;;
  uninvite)
    [[ $# -eq 2 ]] || die "usage: fullstack.sh uninvite <app-id> <email|inv_...|account-id>"
    app_id="$1"; who="$2"; valid_app_id "$app_id"; load_account_key
    collab_base="$BASE_URL/api/v1/fullstack/$app_id"
    # The DELETE routes answer 204 with no body; report the outcome explicitly.
    collab_removed() { printf '{"removed":true,"kind":"%s","id":"%s"}\n' "$1" "$2"; }
    case "$who" in
      inv_*) api_account DELETE "$collab_base/invites/$who" >/dev/null && collab_removed invite "$who" ;;
      *@*)
        # An accepted member wins over a still-pending invitation for the same address.
        resolved=$(api_account GET "$collab_base/members" | "$JQ_BIN" -r --arg e "$who" '
          ((.members // [] | map(select((.email // "" | ascii_downcase) == ($e | ascii_downcase))) | .[0].accountId // empty | "member\t" + .),
           (.invites // [] | map(select((.email // "" | ascii_downcase) == ($e | ascii_downcase))) | .[0].id // empty | "invite\t" + .))
          | select(. != null)' | head -1)
        [[ -n "$resolved" ]] || die "no member or pending invitation for $who on $app_id"
        kind="${resolved%%$'\t'*}"; id="${resolved#*$'\t'}"
        if [[ "$kind" == "member" ]]; then
          api_account DELETE "$collab_base/members/$id" >/dev/null && collab_removed member "$id"
        else
          api_account DELETE "$collab_base/invites/$id" >/dev/null && collab_removed invite "$id"
        fi ;;
      *) api_account DELETE "$collab_base/members/$who" >/dev/null && collab_removed member "$who" ;;
    esac
    ;;
  *) die "unknown command: $CMD" ;;
esac
