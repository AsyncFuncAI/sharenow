#!/usr/bin/env bash
set -euo pipefail

# sharenow account.sh: drives every sharenow capability beyond Sites (publish.sh)
# and Drives (drive.sh): Site Data, profiles, custom domains, handles, links,
# service variables, analytics, API key management, and Site list/search/access.
# All operations use an account API key (snk_).

BASE_URL="https://sharenow.today"
CREDENTIALS_FILE="$HOME/.sharenow/credentials"
API_KEY="${SHARENOW_API_KEY:-}"
ALLOW_NON_SHARENOW_BASE_URL=0

usage() {
  cat <<'USAGE'
Usage: account.sh [global options] <command> [args]

Global options:
  --api-key <key>        Account API key (or $SHARENOW_API_KEY / ~/.sharenow/credentials)
  --base-url <url>       API base (default: https://sharenow.today)
  --allow-nonsharenow-base-url

Sites:
  sites                                  List your Sites
  search <query> [--limit N] [--cursor C]

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
  keys create <name>          (the key is shown ONCE)
  keys revoke <id>

Access (singular /publish/):
  access <slug>
  metadata set <slug> --json '<inline|@file>'
USAGE
  exit 1
}

die() { echo "error: $1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLED_JQ="${SKILL_DIR}/bin/jq"
if [[ -x "$BUNDLED_JQ" ]]; then
  JQ_BIN="$BUNDLED_JQ"
elif command -v jq >/dev/null 2>&1; then
  JQ_BIN="$(command -v jq)"
else
  die "requires jq"
fi
command -v curl >/dev/null 2>&1 || die "requires curl"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-key) API_KEY="$2"; shift 2 ;;
    --base-url) BASE_URL="$2"; shift 2 ;;
    --allow-nonsharenow-base-url) ALLOW_NON_SHARENOW_BASE_URL=1; shift ;;
    --help|-h) usage ;;
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
BASE_URL="${BASE_URL%/}"
if [[ "$BASE_URL" != "https://sharenow.today" && "$ALLOW_NON_SHARENOW_BASE_URL" -ne 1 && -n "$API_KEY" ]]; then
  die "refusing to send credentials to non-default base URL; pass --allow-nonsharenow-base-url to override"
fi
[[ -n "$API_KEY" ]] || die "missing credentials; set SHARENOW_API_KEY or ~/.sharenow/credentials"
auth_header=(-H "authorization: Bearer $API_KEY")

api_json() {
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"
  local extra=("${@:2}")
  local tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" "${auth_header[@]}" -H "content-type: application/json" "${extra[@]+"${extra[@]}"}" -d "$body")
  else
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" "${auth_header[@]}" "${extra[@]+"${extra[@]}"}")
  fi
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    local err
    err=$("$JQ_BIN" -r '.error // .message // empty' "$tmp" 2>/dev/null || true)
    [[ -n "$err" ]] || err="$(cat "$tmp")"
    rm -f "$tmp"
    die "HTTP $code: $err"
  fi
  cat "$tmp"; rm -f "$tmp"
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
      create)
        name="${1:-}"; [[ -n "$name" ]] || die "keys create requires <name>"
        out=$(api_json POST "$BASE_URL/api/v1/me/keys" "$(jobj --arg n "$name" '{name:$n}')")
        echo "$out" | pp
        echo "key_result.shown_once=true (store this key; it cannot be retrieved again)" >&2 ;;
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
