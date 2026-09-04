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
  domain add <domain> --slug S
  domain update <domain> --slug S
  domain status <domain>
  domain rm <domain>
  handle get
  handle create <handle> --slug S [--username U]
  handle update <handle> [--slug S] [--username U]
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

Collaborators (owner invites editors by email; --app targets a Fullstack app):
  members <slug> [--app <app-id>]
  invite <slug> <email> [--app <app-id>]
  uninvite <slug> <email|inv_...|account-id> [--app <app-id>]
  invites                    List invitations addressed to this account
  accept <inviteId>          Accept an invitation
  decline <inviteId>         Decline an invitation

Source (shared Sites and apps; --app targets a Fullstack app):
  pull <slug> <dir> [--force]   Fetch the live version into <dir> and stamp it
  status <slug>                 Live version, last commit, whether they agree
  undo <slug> [--to <commit>]   Redeploy the previous recorded commit
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
# The source stamp and its messages (pull/status/undo, and the stale refusal
# publish.sh renders from the same wording).
. "$SCRIPT_DIR/lib/source.sh"

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
      add|update)
        slug=""
        while [[ $# -gt 0 ]]; do case "$1" in --slug) slug="$2"; shift 2 ;; *) die "unknown option: $1" ;; esac; done
        [[ -n "$dom" ]] || die "domain $sub requires <domain>"
        [[ -n "$slug" ]] || die "domain $sub requires --slug <site-or-app-slug>"
        if [[ "$sub" == "add" ]]; then
          api_json POST "$BASE_URL/api/v1/domains" "$(jobj --arg d "$dom" --arg s "$slug" '{domain:$d,targetSlug:$s}')" | pp
        else
          api_json PATCH "$BASE_URL/api/v1/domains/$(urlenc "$dom")" "$(jobj --arg s "$slug" '{targetSlug:$s}')" | pp
        fi ;;
      status) [[ -n "$dom" ]] || die "domain status requires <domain>"; $req GET "$BASE_URL/api/v1/domains/$(urlenc "$dom")" | pp ;;
      rm) [[ -n "$dom" ]] || die "domain rm requires <domain>"; $req DELETE "$BASE_URL/api/v1/domains/$(urlenc "$dom")" | pp ;;
      *) die "unknown domain subcommand: $sub" ;;
    esac ;;

  handle)
    sub="${1:-}"; shift || true
    case "$sub" in
      get) $req GET "$BASE_URL/api/v1/handle" | pp ;;
      create|update)
        h="${1:-}"; shift || true; user=""; slug=""
        while [[ $# -gt 0 ]]; do case "$1" in --username) user="$2"; shift 2 ;; --slug) slug="$2"; shift 2 ;; *) die "unknown option: $1" ;; esac; done
        [[ -n "$h" ]] || die "handle $sub requires <handle>"
        [[ "$sub" == "update" || -n "$slug" ]] || die "handle create requires --slug <site-or-app-slug>"
        body=$(jobj --arg h "$h" '{handle:$h}'); [[ -n "$user" ]] && body=$("$JQ_BIN" -n --arg u "$user" --argjson c "$body" '$c + {username:$u}')
        [[ -n "$slug" ]] && body=$("$JQ_BIN" -n --arg s "$slug" --argjson c "$body" '$c + {targetSlug:$s}')
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

  members|invite|uninvite)
    # Collaborators: an owner invites other sharenow accounts as editors of one
    # Site or Fullstack app. --app <app-id> selects the Fullstack target; the
    # positional target is a Site slug otherwise. Flags may appear anywhere.
    app=""; positional=()
    while [[ $# -gt 0 ]]; do case "$1" in
      --app) [[ $# -ge 2 ]] || die "--app requires an app id"; app="$2"; shift 2 ;;
      --*) die "unknown option: $1" ;;
      *) positional+=("$1"); shift ;;
    esac; done
    set -- ${positional[@]+"${positional[@]}"}
    if [[ -n "$app" ]]; then
      [[ "$app" == fsa_* && "$app" != *[!A-Za-z0-9_-]* ]] || die "invalid Fullstack app id"
      # With --app the app id is the target; a positional target is optional and
      # must match it when given.
      if [[ $# -gt 0 && "${1:-}" == fsa_* ]]; then
        [[ "$1" == "$app" ]] || die "$CMD received two different app ids"
        shift
      fi
      collab_base="$BASE_URL/api/v1/fullstack/$(urlenc "$app")"
      target_label="$app"
    else
      slug="${1:-}"; [[ -n "$slug" ]] || die "$CMD requires <slug> (or --app <app-id>)"; shift
      collab_base="$BASE_URL/api/v1/publish/$(urlenc "$slug")"
      target_label="$slug"
    fi
    case "$CMD" in
      members)
        [[ $# -eq 0 ]] || die "unexpected members argument: $1"
        $req GET "$collab_base/members" | pp ;;
      invite)
        email="${1:-}"; [[ -n "$email" ]] || die "invite requires <email>"; shift || true
        [[ $# -eq 0 ]] || die "unexpected invite argument: $1"
        [[ "$email" == *@*.* && "$email" != *" "* ]] || die "invite requires a valid email address"
        api_json POST "$collab_base/members/invite" "$(jobj --arg e "$email" '{email:$e}')" | pp ;;
      uninvite)
        who="${1:-}"; [[ -n "$who" ]] || die "uninvite requires <email|inv_...|account-id>"; shift || true
        [[ $# -eq 0 ]] || die "unexpected uninvite argument: $1"
        # The DELETE routes answer 204 with no body; report the outcome explicitly.
        collab_removed() { printf '{"removed":true,"kind":"%s","id":"%s"}\n' "$1" "$2"; }
        case "$who" in
          inv_*) $req DELETE "$collab_base/invites/$(urlenc "$who")" >/dev/null && collab_removed invite "$who" ;;
          acc_*) $req DELETE "$collab_base/members/$(urlenc "$who")" >/dev/null && collab_removed member "$who" ;;
          *@*)
            # Resolve the email against this resource: an accepted member wins over
            # a still-pending invitation with the same address.
            listing=$($req GET "$collab_base/members")
            resolved=$(printf '%s' "$listing" | "$JQ_BIN" -r --arg e "$who" '
              ((.members // [] | map(select((.email // "" | ascii_downcase) == ($e | ascii_downcase))) | .[0].accountId // empty | "member\t" + .),
               (.invites // [] | map(select((.email // "" | ascii_downcase) == ($e | ascii_downcase))) | .[0].id // empty | "invite\t" + .))
              | select(. != null)' | head -1)
            [[ -n "$resolved" ]] || die "no member or pending invitation for $who on $target_label"
            kind="${resolved%%$'\t'*}"; id="${resolved#*$'\t'}"
            if [[ "$kind" == "member" ]]; then
              $req DELETE "$collab_base/members/$(urlenc "$id")" >/dev/null && collab_removed member "$id"
            else
              $req DELETE "$collab_base/invites/$(urlenc "$id")" >/dev/null && collab_removed invite "$id"
            fi ;;
          *) $req DELETE "$collab_base/members/$(urlenc "$who")" >/dev/null && collab_removed member "$who" ;;
        esac ;;
    esac ;;

  pull|status|undo)
    # Source verbs. A Site is addressed by slug and a Fullstack app by
    # --app <app-id>; both resolve to the same three endpoints under
    # `.../source`, so the target resolution is shared and only the verb differs.
    #
    # Exit codes are a contract agents branch on, so they are deliberate:
    #   3  the folder is behind the live version, or would be overwritten
    #   4  the source is not available yet (pending) or was never recorded
    #   5  the export could not be unpacked safely
    # Everything else stays 1 via `die`, as in every other verb.
    src_app=""; src_force=0; src_to=""; src_positional=()
    while [[ $# -gt 0 ]]; do case "$1" in
      --help|-h)
        case "$CMD" in
          pull) echo "Usage: account.sh pull <slug> <dir> | pull --app <app-id> <dir>  [--force]"
                echo "  Fetches the live files into <dir> with a version stamp. Exit 3: <dir> has newer local edits (pass --force to discard). Exit 4: source not recorded yet." ;;
          status) echo "Usage: account.sh status <slug> | status --app <app-id>"
                  echo "  JSON on stdout (live, recorded, pending, push, agree, cloneUrl); one human line on stderr." ;;
          undo) echo "Usage: account.sh undo <slug> [--to <commit>] | undo --app <app-id> [--to <commit>]"
                echo "  Queues a redeploy of the previous recorded commit (or <commit>). It goes live within about a minute; watch with: account.sh status <slug>." ;;
        esac; exit 0 ;;
      --app) [[ $# -ge 2 ]] || die "--app requires an app id"; src_app="$2"; shift 2 ;;
      --force) src_force=1; shift ;;
      --to) [[ $# -ge 2 ]] || die "--to requires a commit id"; src_to="$2"; shift 2 ;;
      --*) die "unknown option: $1" ;;
      *) src_positional+=("$1"); shift ;;
    esac; done
    set -- ${src_positional[@]+"${src_positional[@]}"}
    if [[ -n "$src_app" ]]; then
      [[ "$src_app" == fsa_* && "$src_app" != *[!A-Za-z0-9_-]* ]] || die "invalid Fullstack app id"
      # A positional app id alongside --app is accepted when it agrees, the same
      # way the collaborator verbs treat it.
      if [[ $# -gt 0 && "${1:-}" == fsa_* ]]; then
        [[ "$1" == "$src_app" ]] || die "$CMD received two different app ids"
        shift
      fi
      src_base="$BASE_URL/api/v1/fullstack/$(urlenc "$src_app")/source"
      src_label="$src_app"
      src_kind="fullstack"
    else
      src_slug="${1:-}"
      [[ -n "$src_slug" ]] || die "$CMD requires <slug> (or --app <app-id>)"
      shift
      src_base="$BASE_URL/api/v1/publish/$(urlenc "$src_slug")/source"
      src_label="$src_slug"
      src_kind="site"
    fi

    case "$CMD" in
      status)
        [[ $# -eq 0 ]] || die "unexpected status argument: $1"
        [[ "$src_force" -eq 0 ]] || die "status does not accept --force"
        [[ -z "$src_to" ]] || die "status does not accept --to"
        # The payload goes to stdout VERBATIM so a caller can pipe it to jq; the
        # human sentence goes to stderr so it never corrupts that stream.
        src_status=$($req GET "$src_base")
        printf '%s\n' "$src_status"
        printf '%s' "$src_status" | "$JQ_BIN" -r '
          def short: if . == null or . == "" then "none" else .[0:10] end;
          def state:
            if .push != null and .push.state == "failed" then "\(if .push.mine then "Your" else "A teammate'"'"'s" end) git push \(.push.commit | short) was refused: \(.push.error // .push.reason // "validation failed"); the live site is unchanged"
            elif .push != null and (.push.state == "received" or .push.state == "deploying") then "Deploying \(if .push.mine then "your" else "a teammate'"'"'s" end) git push \(.push.commit | short), live within about a minute"
            elif .pending != null and (.pending.state == "failed") then "Not recorded"
            elif .pending != null then "Recording"
            elif .agree then "In sync"
            elif .head != null and .recorded != null and .head != .recorded.commit then "Out of sync: main is at \(.head | short) but the last recorded deploy is \(.recorded.commit | short)"
            elif .recorded == null then "Not recorded"
            else "Out of sync" end;
          "\(.slug): live \(.live.version // "none") · commit \(.recorded.commit | short) · \(state)"
        ' >&2 ;;

      undo)
        [[ $# -eq 0 ]] || die "unexpected undo argument: $1"
        [[ "$src_force" -eq 0 ]] || die "undo does not accept --force"
        if [[ -n "$src_to" ]]; then
          [[ "$src_to" =~ ^[0-9a-f]{40}$ ]] || die "--to requires a 40-character commit id"
          src_undo=$(api_json POST "$src_base/undo" "$(jobj --arg t "$src_to" '{target:$t}')")
        else
          src_undo=$(api_json POST "$src_base/undo" "{}")
        fi
        printf '%s\n' "$src_undo" | pp
        # The payload is a queue receipt, not a result: say what happens next
        # and how to watch it, so nobody reads a bare commit id as "done".
        printf '%s' "$src_undo" | "$JQ_BIN" -r --arg target "$src_label" --arg flag "$([[ -n "$src_app" ]] && echo "--app " || true)" '
          if .queued then "Rolling back to commit \(.target[0:10]). It goes live within about a minute; watch it with: ./scripts/account.sh status \($flag)\($target)"
          else "Nothing to do: a rollback to commit \(.target[0:10]) is already queued or live." end
        ' >&2 ;;

      pull)
        src_dir="${1:-}"
        [[ -n "$src_dir" ]] || die "pull requires <dir>"
        shift || true
        [[ $# -eq 0 ]] || die "unexpected pull argument: $1"
        [[ -z "$src_to" ]] || die "pull does not accept --to"

        # Refuse BEFORE the download when the folder holds work newer than its
        # stamp. Overwriting an editor's uncommitted edits with a "refresh" is
        # the same class of loss the stale refusal exists to prevent, so it gets
        # the same exit code and the same explicit opt-out.
        if [[ -d "$src_dir" && "$src_force" -eq 0 ]]; then
          src_stamp_file="$(source_stamp_path "$src_dir")"
          if [[ -f "$src_stamp_file" && -n "$(source_stamp_version "$src_dir")" ]]; then
            # Anything modified after the stamp was written, excluding the
            # caches nobody edits by hand. The reference is the STAMP FILE
            # itself, not a timestamp parsed out of it: `find -newer <file>` is
            # portable everywhere, while `-newermt` is GNU-only and `touch -t`
            # reads LOCAL time, either of which quietly turns this check into a
            # no-op on the wrong platform. `pull` writes the stamp last, so its
            # mtime is exactly "when this folder was pulled".
            src_newer=$(find "$src_dir" \
              \( -type d \( -name .git -o -name node_modules -o -name .sharenow \) -prune \) -o \
              -type f -newer "$src_stamp_file" -print 2>/dev/null | head -5 || true)
            if [[ -n "$src_newer" ]]; then
              {
                echo "$src_dir has local changes newer than the version it was pulled at."
                echo "Nothing was downloaded and nothing in $src_dir was changed."
                printf '%s\n' "$src_newer" | sed 's/^/  changed: /'
                echo "Next: pull the newer version alongside: ./scripts/account.sh pull $src_label $(source_sibling_dir "$src_dir"), or pass --force to discard the local changes."
              } >&2
              exit 3
            fi
          elif [[ -e "$src_stamp_file" ]]; then
            echo "$src_dir has a stamp that cannot be read; pass --force to overwrite it." >&2
            exit 3
          fi
        fi

        src_tar=$(mktemp "${TMPDIR:-/tmp}/sharenow-export.XXXXXX")
        src_err=$(mktemp "${TMPDIR:-/tmp}/sharenow-export-err.XXXXXX")
        src_headers=$(mktemp "${TMPDIR:-/tmp}/sharenow-export-hdr.XXXXXX")
        # `-D` writes the response headers: the stamp is built from
        # x-sharenow-version / x-sharenow-commit, which is what binds the folder
        # to the live version rather than to whatever the recorder holds.
        src_code=$(curl_account -sS -o "$src_tar" -D "$src_headers" -w "%{http_code}" \
          "$src_base/export" 2>"$src_err") || src_code="000"
        if [[ "$src_code" -lt 200 || "$src_code" -ge 300 ]]; then
          src_error_code=$("$JQ_BIN" -r '.code // empty' "$src_tar" 2>/dev/null || true)
          src_error_msg=$("$JQ_BIN" -r '.error // .message // empty' "$src_tar" 2>/dev/null || true)
          rm -f "$src_tar" "$src_headers"
          case "$src_error_code" in
            source_pending)
              rm -f "$src_err"
              echo "The latest deploy of $src_label is still being recorded. Try again in a minute." >&2
              exit 4 ;;
            source_missing)
              rm -f "$src_err"
              echo "No source was recorded for the latest deploy of $src_label. Ask the deployer to run \`fullstack.sh up\` again." >&2
              exit 4 ;;
          esac
          [[ -n "$src_error_msg" ]] || src_error_msg="$(cat "$src_err")"
          rm -f "$src_err"
          die "HTTP $src_code: ${src_error_msg:-could not fetch the source for $src_label}"
        fi
        rm -f "$src_err"

        src_version=$(awk 'BEGIN{IGNORECASE=1} /^x-sharenow-version:/ {sub(/^[^:]*:[[:space:]]*/,""); gsub(/\r/,""); print}' "$src_headers" | tail -1)
        src_commit=$(awk 'BEGIN{IGNORECASE=1} /^x-sharenow-commit:/ {sub(/^[^:]*:[[:space:]]*/,""); gsub(/\r/,""); print}' "$src_headers" | tail -1)
        rm -f "$src_headers"
        [[ -n "$src_version" ]] || { rm -f "$src_tar"; die "the export did not name a version; retry, and if it persists report it"; }

        # Validate every entry BEFORE anything is written. An absolute path or a
        # `..` segment in an archive is the classic path-traversal write, and a
        # pull targets a folder the agent cares about.
        src_bad=$(tar -tf "$src_tar" 2>/dev/null | awk '
          { p = $0
            sub(/^\.\//, "", p)
            if (p == "") next
            if (p ~ /^\//) { print; next }
            if (p ~ /(^|\/)\.\.(\/|$)/) { print; next }
            if (p ~ /^~/) { print; next }
          }' | head -5 || true)
        if [[ -n "$src_bad" ]]; then
          rm -f "$src_tar"
          {
            echo "The export contains an unsafe path and was not unpacked:"
            printf '%s\n' "$src_bad" | sed 's/^/  /'
          } >&2
          exit 5
        fi

        # Unpack into a staging folder first, so a tar that fails halfway never
        # leaves the destination half-written.
        src_stage=$(mktemp -d "${TMPDIR:-/tmp}/sharenow-pull.XXXXXX")
        if ! tar -xf "$src_tar" -C "$src_stage" 2>/dev/null; then
          rm -rf "$src_stage"; rm -f "$src_tar"
          echo "The export could not be unpacked." >&2
          exit 5
        fi
        rm -f "$src_tar"

        mkdir -p "$src_dir" || { rm -rf "$src_stage"; die "could not create $src_dir"; }
        # Copy rather than move: the destination may already exist, and a pull
        # replaces the files the export carries without deleting anything else
        # the agent put there.
        if ! (cd "$src_stage" && tar -cf - .) | (cd "$src_dir" && tar -xf -); then
          rm -rf "$src_stage"
          die "could not write into $src_dir"
        fi
        rm -rf "$src_stage"

        # Date every pulled file to this instant. The dirty check compares file
        # mtimes against the stamp, and an archive carries whatever mtimes its
        # builder chose (sharenow's exports are epoch-dated for reproducibility);
        # without this a freshly pulled folder's own files could read as either
        # local edits or as suspiciously ancient, depending on the sender.
        find "$src_dir" -type f ! -path "$src_dir/$SOURCE_STAMP_REL" -exec touch {} + 2>/dev/null || true

        # An app pulled from its history must know which app it is, or the next
        # `fullstack.sh up` here would create a second app instead of updating
        # this one. A contract recorded before this feature may lack the line.
        if [[ "$src_kind" == fullstack && -f "$src_dir/fullstack.yaml" ]] && ! grep -qE '^app_id:' "$src_dir/fullstack.yaml"; then
          printf 'app_id: %s\n' "$src_app" | cat - "$src_dir/fullstack.yaml" > "$src_dir/fullstack.yaml.tmp" && mv "$src_dir/fullstack.yaml.tmp" "$src_dir/fullstack.yaml"
        fi
        source_write_stamp "$src_dir" "$src_kind" "$src_label" "$src_version" "$src_commit" \
          || die "pulled into $src_dir but could not write $src_dir/$SOURCE_STAMP_REL"

        "$JQ_BIN" -n --arg dir "$src_dir" --arg slug "$src_label" --arg version "$src_version" \
          --arg commit "$src_commit" --arg kind "$src_kind" \
          '{pulled:true,kind:$kind,slug:$slug,dir:$dir,version:$version,commit:(if $commit == "" then null else $commit end)}'
        if [[ -n "$src_commit" ]]; then
          echo "Pulled $src_label at version $src_version (commit ${src_commit:0:10}) into $src_dir." >&2
        else
          echo "Pulled $src_label at version $src_version into $src_dir (its commit is still being recorded)." >&2
        fi
        echo "Edit the folder, then publish from it: the version stamp keeps someone else's newer publish from being overwritten." >&2 ;;
    esac ;;

  invites)
    [[ $# -eq 0 ]] || die "invites accepts no arguments"
    $req GET "$BASE_URL/api/v1/invites" | pp ;;

  accept|decline)
    invite_id="${1:-}"; [[ -n "$invite_id" ]] || die "$CMD requires <inviteId>"; shift || true
    [[ $# -eq 0 ]] || die "unexpected $CMD argument: $1"
    [[ "$invite_id" == inv_* && "$invite_id" != *[!A-Za-z0-9_-]* ]] || die "invalid invitation id"
    api_json POST "$BASE_URL/api/v1/invites/$(urlenc "$invite_id")/$CMD" "{}" | pp ;;

  *) die "unknown command: $CMD" ;;
esac
