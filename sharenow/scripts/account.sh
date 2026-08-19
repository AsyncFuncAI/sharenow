#!/usr/bin/env bash
set -euo pipefail

# sharenow account.sh: drives every sharenow capability beyond Sites (publish.sh)
# and Drives (drive.sh): Site Data, profiles, custom domains, handles, links,
# service variables, analytics, API key management, and Site list/search/access.
# All operations use an account API key (snk_).

BASE_URL="https://sharenow.today"
CREDENTIALS_FILE="$HOME/.sharenow/credentials"
API_KEY="${SHARENOW_API_KEY:-}"

usage() {
  local code="${1:-1}"
  cat <<'USAGE'
Usage: account.sh [global options] <command> [args]

Global options:
  --help                  Show this help

Connection:
  login [--client <name>] Connect in a first-party browser page. The key is
                          saved locally and is never printed in chat.
  capabilities            Show the account tier and available product features

Sites:
  sites                                  List your Sites
  search <query> [--limit N] [--cursor C]
  rename <slug> <new-slug>               Rename a Site's address (All Access); the old address redirects

Site Data:
  site-data ls <slug> <collection> [--limit N] [--cursor C]
  site-data create <slug> <collection> --json '<inline|@file>' [--idempotency-key K]
  site-data get   <slug> <collection> <recordId>
  site-data patch <slug> <collection> <recordId> --json '<inline|@file>'
  site-data rm    <slug> <collection> <recordId>

Profile:
  profile get
  profile set [--enabled true|false] [--add-new-sites true|false]
  profile username <name>
  profile sites
  profile add <slug>
  profile remove <slug>

Domains & handle:
  domains
  domain add <domain>
  domain status <domain>
  domain rm <domain>
  handle get
  handle create <handle> [--username U]
  handle update <handle> [--username U]
  handle rm

Links & variables:
  links
  link create --slug S [--location L] [--mount-path P] [--domain D]
  link get   <location>
  link patch <location> --slug S [--domain D]
  link rm    <location>
  variables
  variable set <name> --value V [--pin-upstream]
  variable rm <name>

Analytics:
  analytics [<slug>] [--range 24h|7d|30d|90d|all]

API keys:
  keys
  keys revoke <id>

Access (singular /publish/):
  access <slug>
  metadata set <slug> --json '<inline|@file>'
USAGE
  exit "$code"
}

die() { echo "error: $1" >&2; exit 1; }

valid_account_key() {
  local value="$1"
  [[ "$value" == snk_????????????????????* ]] || return 1
  [[ "$value" != *[!A-Za-z0-9_-]* ]]
}

json_field() {
  local field="$1"
  command -v node >/dev/null 2>&1 || die "login requires node"
  node -e '
    let body="";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => body += chunk);
    process.stdin.on("end", () => {
      try {
        const value = JSON.parse(body)[process.argv[1]];
        if (value !== undefined && value !== null) process.stdout.write(String(value));
      } catch { process.exit(2); }
    });
  ' "$field"
}

local_trial_sites() {
  local state_file=".sharenow/state.json"
  [[ -f "$state_file" ]] || return 0
  node - "$state_file" <<'NODE'
const fs = require("node:fs");
try {
  const state = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const publishes = state && typeof state.publishes === "object" ? state.publishes : {};
  const sites = Object.keys(publishes)
    .filter((slug) => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(slug))
    .map((slug, index) => ({
      slug,
      token: publishes[slug]?.claimToken,
      expiresAt: Date.parse(publishes[slug]?.expiresAt ?? "") || 0,
      index,
    }))
    .filter(({ token }) => typeof token === "string" && /^clm_[A-Za-z0-9_-]{20,}$/.test(token))
    .sort((left, right) => right.expiresAt - left.expiresAt || right.index - left.index)
    .slice(0, 20);
  for (const { slug, token } of sites) process.stdout.write(`${slug}\t${token}\n`);
} catch {}
NODE
}

device_post() {
  local path="$1" body="$2" out code
  out=$(mktemp)
  code=$(printf '%s' "$body" | curl -sS -o "$out" -w "%{http_code}" -X POST \
    "$BASE_URL$path" -H "content-type: application/json" --data-binary @-)
  DEVICE_HTTP_CODE="$code"
  DEVICE_HTTP_BODY=$(cat "$out")
  rm -f "$out"
}

save_credentials() {
  local key="$1" dir tmp
  dir=$(dirname "$CREDENTIALS_FILE")
  mkdir -p "$dir"
  umask 077
  tmp=$(mktemp "$dir/.credentials.XXXXXX") || die "could not create credentials file"
  printf '%s\n' "$key" > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$CREDENTIALS_FILE"
}

update_local_site_claim() {
  local state_file="$1" slug="$2" state="$3"
  node - "$state_file" "$slug" "$state" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const stateFile = process.argv[2];
const slug = process.argv[3];
const claimState = process.argv[4];
let temporary;
try {
  const state = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  const entry = state?.publishes?.[slug];
  if (!entry || typeof entry !== "object") process.exit(0);
  delete entry.claimToken;
  delete entry.claimUrl;
  delete entry.expiresAt;
  if (claimState === "permanent") entry.persistence = "permanent";
  temporary = path.join(path.dirname(stateFile), `.state.${process.pid}.tmp`);
  fs.writeFileSync(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, stateFile);
} catch {
  if (temporary) try { fs.rmSync(temporary, { force: true }); } catch {}
  process.exit(1);
}
NODE
}

claim_local_trial_sites() {
  local key="$1" state_file=".sharenow/state.json" claimed=0 slug token body_file out code message
  [[ -f "$state_file" ]] || return 0
  while IFS=$'\t' read -r slug token; do
    [[ -n "$slug" && -n "$token" ]] || continue
    umask 077
    body_file=$(mktemp)
    printf '{"token":"%s"}' "$token" > "$body_file"
    out=$(mktemp)
    if ! code=$(printf 'header = "authorization: Bearer %s"\n' "$key" | curl --config - \
      -sS -o "$out" -w "%{http_code}" -X POST \
      "$BASE_URL/api/v1/publish/$slug/claim" \
      -H "content-type: application/json" \
      --data-binary "@$body_file"); then
      rm -f "$body_file" "$out"
      continue
    fi
    if [[ "$code" -ge 200 && "$code" -lt 300 ]]; then
      if ! update_local_site_claim "$state_file" "$slug" permanent; then
        echo "warning: a Site was recovered, but $state_file could not be updated." >&2
      fi
      claimed=$((claimed + 1))
    elif [[ "$code" -eq 403 || "$code" -eq 404 || "$code" -eq 410 ]]; then
      if ! update_local_site_claim "$state_file" "$slug" stale; then
        echo "warning: stale recovery state could not be removed from $state_file." >&2
      fi
    elif [[ "$code" -eq 409 ]]; then
      message=$(json_field message < "$out" 2>/dev/null || true)
      if [[ "$message" == *"already claimed"* || "$message" == *"was claimed"* ]]; then
        if ! update_local_site_claim "$state_file" "$slug" stale; then
          echo "warning: stale recovery state could not be removed from $state_file." >&2
        fi
      fi
    fi
    rm -f "$body_file" "$out"
  done < <(local_trial_sites)
  if [[ "$claimed" -gt 0 ]]; then
    echo "Recovered $claimed local trial Site(s) into this account." >&2
  fi
}

login() {
  local client="agent" normalized start_body grant_id device_secret verification_url interval
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --client) [[ $# -ge 2 ]] || die "--client requires a value"; client="$2"; shift 2 ;;
      --help|-h) echo "Usage: account.sh login [--client <name>]"; return 0 ;;
      *) die "unknown login option: $1" ;;
    esac
  done
  normalized=$(printf '%s' "$client" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._ -' '-')
  normalized="${normalized#-}"
  normalized="${normalized%-}"
  [[ -n "$normalized" ]] || normalized="agent"
  start_body=$(printf '{"client":"%s"}' "$normalized")
  device_post "/api/auth/agent/device/start" "$start_body"
  [[ "$DEVICE_HTTP_CODE" -eq 201 ]] || die "could not start browser connection (HTTP $DEVICE_HTTP_CODE)"
  grant_id=$(printf '%s' "$DEVICE_HTTP_BODY" | json_field grantId) || die "invalid connection response"
  device_secret=$(printf '%s' "$DEVICE_HTTP_BODY" | json_field deviceSecret) || die "invalid connection response"
  verification_url=$(printf '%s' "$DEVICE_HTTP_BODY" | json_field verificationUrl) || die "invalid connection response"
  interval=$(printf '%s' "$DEVICE_HTTP_BODY" | json_field interval) || interval=3
  [[ "$grant_id" == agd_* && "$device_secret" == ags_* && "$verification_url" == https://sharenow.today/connect/agent* ]] \
    || die "invalid connection response"
  echo "Open this secure sharenow page to connect:" >&2
  echo "$verification_url" >&2
  if [[ "${SHARENOW_NO_BROWSER_OPEN:-}" == "1" ]]; then
    :
  elif command -v open >/dev/null 2>&1; then
    open "$verification_url" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$verification_url" >/dev/null 2>&1 || true
  fi

  while true; do
    device_post "/api/auth/agent/device/token" \
      "$(printf '{"grantId":"%s","deviceSecret":"%s"}' "$grant_id" "$device_secret")"
    if [[ "$DEVICE_HTTP_CODE" -eq 202 ]]; then
      sleep "$interval"
      continue
    fi
    [[ "$DEVICE_HTTP_CODE" -eq 200 ]] || die "connection failed or expired (HTTP $DEVICE_HTTP_CODE)"
    local api_key status
    status=$(printf '%s' "$DEVICE_HTTP_BODY" | json_field status) || die "invalid token response"
    api_key=$(printf '%s' "$DEVICE_HTTP_BODY" | json_field apiKey) || die "invalid token response"
    [[ "$status" == "connected" ]] && valid_account_key "$api_key" || die "invalid token response"
    save_credentials "$api_key"
    claim_local_trial_sites "$api_key"
    unset api_key DEVICE_HTTP_BODY device_secret
    echo "sharenow connected. Credentials were saved locally and were not printed." >&2
    return 0
  done
}

if [[ "${1:-}" == "login" ]]; then
  shift
  login "$@"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLED_JQ="${SKILL_DIR}/bin/jq"
if [[ -x "$BUNDLED_JQ" ]]; then
  JQ_BIN="$BUNDLED_JQ"
elif command -v jq >/dev/null 2>&1; then
  JQ_BIN="$(command -v jq)"
else
  die "requires jq. Install it with 'brew install jq' (macOS) or 'sudo apt-get install jq' (Debian/Ubuntu), then retry"
fi
command -v curl >/dev/null 2>&1 || die "requires curl"

# Shared HTTP response handling (needs JQ_BIN + die, both defined above).
. "$SCRIPT_DIR/lib/http.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
  --help|-h) usage 0 ;;
    --*) die "unknown global option: $1" ;;
    *) break ;;
  esac
done

CMD="${1:-}"
[[ -n "$CMD" ]] || usage
shift || true

if [[ -z "$API_KEY" && -f "$CREDENTIALS_FILE" ]]; then
  API_KEY=$(tr -d '[:space:]' < "$CREDENTIALS_FILE")
fi
[[ -n "$API_KEY" ]] || die "not connected. Run ./scripts/account.sh login --client <agent-name>, then retry"
valid_account_key "$API_KEY" || die "invalid account credential format"

curl_account() {
  printf 'header = "authorization: Bearer %s"\n' "$API_KEY" | curl --config - "$@"
}

api_json() {
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"
  local extra=("${@:2}")
  local tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(curl_account -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "content-type: application/json" "${extra[@]+"${extra[@]}"}" -d "$body")
  else
    code=$(curl_account -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" "${extra[@]+"${extra[@]}"}")
  fi
  http_handle_response "$code" "$tmp"
}

# Pretty-print JSON to stdout.
pp() { "$JQ_BIN" '.'; }

urlenc() { "$JQ_BIN" -nr --arg v "$1" '$v|@uri'; }

# Read a --json value that is either inline JSON or @file.
read_json_arg() {
  local v="$1"
  if [[ "$v" == @* ]]; then cat "${v:1}"; else printf '%s' "$v"; fi
}

# Build a JSON object from a list of key value pairs (string values).
jobj() { "$JQ_BIN" -n "$@"; }

req="api_json"

case "$CMD" in
  capabilities)
    [[ $# -eq 0 ]] || die "capabilities accepts no arguments"
    $req GET "$BASE_URL/api/v1/account/capabilities" | pp ;;

  sites)
    $req GET "$BASE_URL/api/v1/publishes" | pp ;;

  search)
    q="${1:-}"; [[ -n "$q" ]] || die "search requires a query"; shift || true
    limit=""; cursor=""
    while [[ $# -gt 0 ]]; do case "$1" in
      --limit) limit="$2"; shift 2 ;; --cursor) cursor="$2"; shift 2 ;; *) die "unknown option: $1" ;;
    esac; done
    url="$BASE_URL/api/v1/publishes/search?q=$(urlenc "$q")"
    [[ -n "$limit" ]] && url="$url&limit=$limit"
    [[ -n "$cursor" ]] && url="$url&cursor=$(urlenc "$cursor")"
    $req GET "$url" | pp ;;

  rename)
    slug="${1:-}"; new="${2:-}"
    [[ -n "$slug" && -n "$new" ]] || die "rename requires <slug> <new-slug>"
    shift 2 || true
    [[ $# -eq 0 ]] || die "unknown option: $1"
    api_json POST "$BASE_URL/api/v1/publish/$(urlenc "$slug")/rename" "$(jobj --arg s "$new" '{slug:$s}')" | pp ;;

  site-data)
    sub="${1:-}"; shift || true
    slug="${1:-}"; coll="${2:-}"; [[ -n "$slug" && -n "$coll" ]] || die "site-data needs <slug> <collection>"; shift 2 || true
    base="$BASE_URL/api/v1/publishes/$(urlenc "$slug")/data/$(urlenc "$coll")"
    case "$sub" in
      ls)
        limit=""; cursor=""
        while [[ $# -gt 0 ]]; do case "$1" in --limit) limit="$2"; shift 2 ;; --cursor) cursor="$2"; shift 2 ;; *) die "unknown option: $1" ;; esac; done
        url="$base"; [[ -n "$limit" ]] && url="$url?limit=$limit"
        [[ -n "$cursor" ]] && { [[ "$url" == *\?* ]] && url="$url&cursor=$(urlenc "$cursor")" || url="$url?cursor=$(urlenc "$cursor")"; }
        $req GET "$url" | pp ;;
      create)
        json=""; idem=()
        while [[ $# -gt 0 ]]; do case "$1" in --json) json="$2"; shift 2 ;; --idempotency-key) idem=(-H "idempotency-key: $2"); shift 2 ;; *) die "unknown option: $1" ;; esac; done
        [[ -n "$json" ]] || die "create requires --json"
        api_json POST "$base" "$(read_json_arg "$json")" "${idem[@]+"${idem[@]}"}" | pp ;;
      get) rid="${1:-}"; [[ -n "$rid" ]] || die "get requires <recordId>"; $req GET "$base/$(urlenc "$rid")" | pp ;;
      patch) rid="${1:-}"; shift || true; json=""; while [[ $# -gt 0 ]]; do case "$1" in --json) json="$2"; shift 2 ;; *) die "unknown option: $1" ;; esac; done
        [[ -n "$rid" && -n "$json" ]] || die "patch requires <recordId> --json"; api_json PATCH "$base/$(urlenc "$rid")" "$(read_json_arg "$json")" | pp ;;
      rm) rid="${1:-}"; [[ -n "$rid" ]] || die "rm requires <recordId>"; $req DELETE "$base/$(urlenc "$rid")" | pp ;;
      *) die "unknown site-data subcommand: $sub" ;;
    esac ;;

  profile)
    sub="${1:-}"; shift || true
    case "$sub" in
      get) $req GET "$BASE_URL/api/v1/profile" | pp ;;
      set)
        body="{}"
        while [[ $# -gt 0 ]]; do case "$1" in
          --enabled) body=$("$JQ_BIN" -n --argjson b "$2" --argjson cur "$body" '$cur + {enabled:$b}'); shift 2 ;;
          --add-new-sites) body=$("$JQ_BIN" -n --argjson b "$2" --argjson cur "$body" '$cur + {addNewSitesToProfile:$b}'); shift 2 ;;
          *) die "unknown option: $1" ;;
        esac; done
        api_json PATCH "$BASE_URL/api/v1/profile" "$body" | pp ;;
      username) name="${1:-}"; [[ -n "$name" ]] || die "username requires <name>"; api_json PATCH "$BASE_URL/api/v1/profile/username" "$(jobj --arg n "$name" '{username:$n}')" | pp ;;
      sites) $req GET "$BASE_URL/api/v1/profile/sites" | pp ;;
      add) slug="${1:-}"; [[ -n "$slug" ]] || die "add requires <slug>"; api_json POST "$BASE_URL/api/v1/profile/sites" "$(jobj --arg s "$slug" '{slug:$s}')" | pp ;;
      remove) slug="${1:-}"; [[ -n "$slug" ]] || die "remove requires <slug>"; $req DELETE "$BASE_URL/api/v1/profile/sites/$(urlenc "$slug")" | pp ;;
      *) die "unknown profile subcommand: $sub" ;;
    esac ;;

  domains) $req GET "$BASE_URL/api/v1/domains" | pp ;;
  domain)
    sub="${1:-}"; dom="${2:-}"; shift 2 || true
    case "$sub" in
      add) [[ -n "$dom" ]] || die "domain add requires <domain>"; api_json POST "$BASE_URL/api/v1/domains" "$(jobj --arg d "$dom" '{domain:$d}')" | pp ;;
      status) [[ -n "$dom" ]] || die "domain status requires <domain>"; $req GET "$BASE_URL/api/v1/domains/$(urlenc "$dom")" | pp ;;
      rm) [[ -n "$dom" ]] || die "domain rm requires <domain>"; $req DELETE "$BASE_URL/api/v1/domains/$(urlenc "$dom")" | pp ;;
      *) die "unknown domain subcommand: $sub" ;;
    esac ;;

  handle)
    sub="${1:-}"; shift || true
    case "$sub" in
      get) $req GET "$BASE_URL/api/v1/handle" | pp ;;
      create|update)
        h="${1:-}"; shift || true; user=""
        while [[ $# -gt 0 ]]; do case "$1" in --username) user="$2"; shift 2 ;; *) die "unknown option: $1" ;; esac; done
        [[ -n "$h" ]] || die "handle $sub requires <handle>"
        body=$(jobj --arg h "$h" '{handle:$h}'); [[ -n "$user" ]] && body=$("$JQ_BIN" -n --arg u "$user" --argjson c "$body" '$c + {username:$u}')
        meth="POST"; [[ "$sub" == "update" ]] && meth="PATCH"
        api_json "$meth" "$BASE_URL/api/v1/handle" "$body" | pp ;;
      rm) $req DELETE "$BASE_URL/api/v1/handle" | pp ;;
      *) die "unknown handle subcommand: $sub" ;;
    esac ;;

  links) $req GET "$BASE_URL/api/v1/links" | pp ;;
  link)
    sub="${1:-}"; shift || true
    case "$sub" in
      create)
        body="{}"
        while [[ $# -gt 0 ]]; do case "$1" in
          --slug) body=$("$JQ_BIN" -n --arg v "$2" --argjson c "$body" '$c + {slug:$v}'); shift 2 ;;
          --location) body=$("$JQ_BIN" -n --arg v "$2" --argjson c "$body" '$c + {location:$v}'); shift 2 ;;
          --mount-path) body=$("$JQ_BIN" -n --arg v "$2" --argjson c "$body" '$c + {mount_path:$v}'); shift 2 ;;
          --domain) body=$("$JQ_BIN" -n --arg v "$2" --argjson c "$body" '$c + {domain:$v}'); shift 2 ;;
          *) die "unknown option: $1" ;;
        esac; done
        api_json POST "$BASE_URL/api/v1/links" "$body" | pp ;;
      get) loc="${1:-}"; [[ -n "$loc" ]] || die "link get requires <location>"; $req GET "$BASE_URL/api/v1/links/$(urlenc "$loc")" | pp ;;
      patch) loc="${1:-}"; shift || true; body="{}"
        while [[ $# -gt 0 ]]; do case "$1" in --slug) body=$("$JQ_BIN" -n --arg v "$2" --argjson c "$body" '$c + {slug:$v}'); shift 2 ;; --domain) body=$("$JQ_BIN" -n --arg v "$2" --argjson c "$body" '$c + {domain:$v}'); shift 2 ;; *) die "unknown option: $1" ;; esac; done
        [[ -n "$loc" ]] || die "link patch requires <location>"; api_json PATCH "$BASE_URL/api/v1/links/$(urlenc "$loc")" "$body" | pp ;;
      rm) loc="${1:-}"; [[ -n "$loc" ]] || die "link rm requires <location>"; $req DELETE "$BASE_URL/api/v1/links/$(urlenc "$loc")" | pp ;;
      *) die "unknown link subcommand: $sub" ;;
    esac ;;

  variables) $req GET "$BASE_URL/api/v1/me/variables" | pp ;;
  variable)
    sub="${1:-}"; name="${2:-}"; shift 2 || true
    case "$sub" in
      set)
        [[ -n "$name" ]] || die "variable set requires <name>"; value=""; pin="false"
        while [[ $# -gt 0 ]]; do case "$1" in --value) value="$2"; shift 2 ;; --pin-upstream) pin="true"; shift ;; *) die "unknown option: $1" ;; esac; done
        [[ -n "$value" ]] || die "variable set requires --value"
        api_json PUT "$BASE_URL/api/v1/me/variables/$(urlenc "$name")" "$(jobj --arg v "$value" --argjson p "$pin" '{value:$v, pinToUpstreamOrigin:$p}')" | pp ;;
      rm) [[ -n "$name" ]] || die "variable rm requires <name>"; $req DELETE "$BASE_URL/api/v1/me/variables/$(urlenc "$name")" | pp ;;
      *) die "unknown variable subcommand: $sub" ;;
    esac ;;

  analytics)
    slug=""; range=""
    while [[ $# -gt 0 ]]; do case "$1" in --range) range="$2"; shift 2 ;; --*) die "unknown option: $1" ;; *) slug="$1"; shift ;; esac; done
    if [[ -n "$slug" ]]; then url="$BASE_URL/api/v1/publishes/$(urlenc "$slug")/analytics"; else url="$BASE_URL/api/v1/analytics"; fi
    [[ -n "$range" ]] && url="$url?range=$(urlenc "$range")"
    $req GET "$url" | pp ;;

  keys)
    sub="${1:-}"; shift || true
    case "$sub" in
      ""|list) $req GET "$BASE_URL/api/v1/me/keys" | pp ;;
      revoke) id="${1:-}"; [[ -n "$id" ]] || die "keys revoke requires <id>"; $req DELETE "$BASE_URL/api/v1/me/keys/$(urlenc "$id")" | pp ;;
      *) die "unknown keys subcommand: $sub" ;;
    esac ;;

  access)
    slug="${1:-}"; [[ -n "$slug" ]] || die "access requires <slug>"
    $req GET "$BASE_URL/api/v1/publish/$(urlenc "$slug")/access" | pp ;;

  metadata)
    sub="${1:-}"; slug="${2:-}"; shift 2 || true
    [[ "$sub" == "set" && -n "$slug" ]] || die "usage: metadata set <slug> --json '<inline|@file>'"
    json=""; while [[ $# -gt 0 ]]; do case "$1" in --json) json="$2"; shift 2 ;; *) die "unknown option: $1" ;; esac; done
    [[ -n "$json" ]] || die "metadata set requires --json"
    api_json PATCH "$BASE_URL/api/v1/publish/$(urlenc "$slug")/metadata" "$(read_json_arg "$json")" | pp ;;

  *) die "unknown command: $CMD" ;;
esac
