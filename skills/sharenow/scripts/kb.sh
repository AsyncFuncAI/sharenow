#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://sharenow.today"
CREDENTIALS_FILE="$HOME/.sharenow/credentials"
STATE_FILE="${SHARENOW_STATE_DIR:-$HOME/.sharenow}/kb.json"
API_KEY="${SHARENOW_API_KEY:-}"

usage() {
  local code="${1:-1}"
  cat <<'USAGE'
Usage: kb.sh <command> [args]

Commands:
  list
  open <public-github-url> [--ref <branch-or-tag>] [--fresh] [--timeout <seconds>] [--dry-run]
  status [session-id]
  query [session-id] architecture|schema
  query [session-id] search-code --pattern <text>
  query [session-id] source|context --qualified-name <name>
  query [session-id] trace --function <name> [--direction inbound|outbound|both] [--depth 1-5]
  close [session-id] [--dry-run]

The starter path accepts only a public https github.com repository URL. It does
not archive or upload a local directory. Account credentials are never accepted
as command arguments.
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
. "$SCRIPT_DIR/lib/http.sh"

valid_account_key() { [[ "$1" == snk_????????????????????* && "$1" != *[!A-Za-z0-9_-]* ]]; }
load_account_key() {
  if [[ -z "$API_KEY" && -f "$CREDENTIALS_FILE" ]]; then API_KEY=$(tr -d '[:space:]' < "$CREDENTIALS_FILE"); fi
  [[ -n "$API_KEY" ]] || die "not connected. Run ./scripts/account.sh login --client <agent-name>, then retry"
  valid_account_key "$API_KEY" || die "invalid account credential format"
}

api_account() {
  local method="$1" url="$2" body="${3:-}" tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(printf 'header = "authorization: Bearer %s"\n' "$API_KEY" | curl --config - -sS --max-time "${SHARENOW_KB_HTTP_TIMEOUT:-150}" -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "content-type: application/json" -d "$body")
  else
    code=$(printf 'header = "authorization: Bearer %s"\n' "$API_KEY" | curl --config - -sS --max-time "${SHARENOW_KB_HTTP_TIMEOUT:-150}" -o "$tmp" -w "%{http_code}" -X "$method" "$url")
  fi
  http_handle_response "$code" "$tmp"
}

validate_repo_url() {
  local value="$1" rest owner repo
  case "$value" in
    https://github.com/*) ;;
    *) die "repository must be a public https github.com URL (https://github.com/<owner>/<repo>)" ;;
  esac
  [[ "$value" != *\?* && "$value" != *\#* ]] || die "repository URL must not contain a query or fragment"
  rest="${value#https://github.com/}"; rest="${rest%/}"; owner="${rest%%/*}"; repo="${rest#*/}"; repo="${repo%.git}"
  [[ -n "$owner" && -n "$repo" && "$repo" != */* ]] || die "repository must be a public https github.com URL (https://github.com/<owner>/<repo>)"
  [[ "$owner" != *[!A-Za-z0-9_.-]* && "$repo" != *[!A-Za-z0-9_.-]* ]] || die "repository owner and name contain unsupported characters"
  printf 'https://github.com/%s/%s\n' "$owner" "$repo"
}

validate_session() { [[ "$1" == kb_* && "$1" != *[!A-Za-z0-9_-]* ]] || die "invalid Knowledge Base session id"; }

save_session() {
  local id="$1" repo="$2" reused="$3" dir tmp current
  dir=$(dirname "$STATE_FILE"); mkdir -p "$dir"; umask 077
  current='{"current":null,"sessions":{}}'; [[ -f "$STATE_FILE" ]] && current=$(cat "$STATE_FILE")
  tmp=$(mktemp "$dir/.kb.XXXXXX") || die "could not create Knowledge Base state"
  if printf '%s' "$current" | "$JQ_BIN" --arg id "$id" --arg repo "$repo" --argjson reused "$reused" '.current=$id | .sessions[$id]={repoUrl:$repo,reused:$reused}' > "$tmp"; then
    chmod 600 "$tmp"; mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"; die "could not update Knowledge Base state"
  fi
}

current_session() {
  local requested="${1:-}" value
  if [[ -n "$requested" ]]; then validate_session "$requested"; printf '%s\n' "$requested"; return; fi
  [[ -f "$STATE_FILE" ]] || die "no active Knowledge Base session; run kb.sh open <public-github-url>"
  value=$("$JQ_BIN" -r '.current // empty' "$STATE_FILE")
  validate_session "$value"; printf '%s\n' "$value"
}

clear_current() {
  [[ -f "$STATE_FILE" ]] || return 0
  local dir tmp; dir=$(dirname "$STATE_FILE"); umask 077; tmp=$(mktemp "$dir/.kb.XXXXXX")
  "$JQ_BIN" '.current=null' "$STATE_FILE" > "$tmp"; chmod 600 "$tmp"; mv "$tmp" "$STATE_FILE"
}

session_reused() {
  local id="$1"
  [[ -f "$STATE_FILE" ]] || { printf 'false\n'; return; }
  "$JQ_BIN" -r --arg id "$id" '.sessions[$id].reused // false' "$STATE_FILE"
}

build_query() {
  local tool="$1"; shift
  case "$tool" in
    architecture) "$JQ_BIN" -n '{tool:"get_architecture",args:{}}' ;;
    schema) "$JQ_BIN" -n '{tool:"get_graph_schema",args:{}}' ;;
    search-code)
      [[ "${1:-}" == --pattern && $# -eq 2 ]] || die "search-code requires --pattern <text>"
      "$JQ_BIN" -n --arg pattern "$2" '{tool:"search_code",args:{pattern:$pattern}}' ;;
    source|context)
      [[ "${1:-}" == --qualified-name && $# -eq 2 ]] || die "$tool requires --qualified-name <name>"
      if [[ "$tool" == source ]]; then query_tool="get_code_snippet"; else query_tool="context"; fi
      "$JQ_BIN" -n --arg tool "$query_tool" --arg qualifiedName "$2" '{tool:$tool,args:{qualifiedName:$qualifiedName}}' ;;
    trace)
      function_name=""; direction="both"; depth=3
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --function) function_name="$2"; shift 2 ;;
          --direction) direction="$2"; shift 2 ;;
          --depth) depth="$2"; shift 2 ;;
          *) die "unexpected trace argument: $1" ;;
        esac
      done
      [[ -n "$function_name" ]] || die "trace requires --function <name>"
      case "$direction" in inbound|outbound|both) ;; *) die "trace direction must be inbound, outbound, or both" ;; esac
      [[ "$depth" =~ ^[1-5]$ ]] || die "trace depth must be 1-5"
      "$JQ_BIN" -n --arg functionName "$function_name" --arg direction "$direction" --argjson depth "$depth" '{tool:"trace_path",args:{functionName:$functionName,direction:$direction,depth:$depth}}' ;;
    *) die "unknown query tool: $tool" ;;
  esac
}

CMD="${1:-}"
case "$CMD" in --help|-h) usage 0 ;; "") usage ;; esac
shift

case "$CMD" in
  list)
    [[ $# -eq 0 ]] || die "usage: kb.sh list"
    load_account_key; api_account GET "$BASE_URL/api/v1/kb" | "$JQ_BIN" . ;;
  open)
    [[ $# -ge 1 ]] || die "usage: kb.sh open <public-github-url> [options]"
    repo=$(validate_repo_url "$1"); shift; ref=""; fresh=false; timeout=90; dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --ref) ref="$2"; shift 2 ;;
        --fresh) fresh=true; shift ;;
        --timeout) timeout="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) die "unexpected open argument: $1" ;;
      esac
    done
    [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -ge 1 && "$timeout" -le 600 ]] || die "--timeout must be 1-600 seconds"
    if [[ -n "$ref" ]]; then [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]] || die "invalid git branch or tag"; fi
    if [[ "$dry" -eq 1 ]]; then
      "$JQ_BIN" -n --arg repoUrl "$repo" --arg ref "$ref" --argjson fresh "$fresh" '{dryRun:true,action:"open",source:"public GitHub repository",repoUrl:$repoUrl,fresh:$fresh} + (if $ref == "" then {} else {ref:$ref} end)'
      exit 0
    fi
    load_account_key
    body=$($JQ_BIN -n --arg repoUrl "$repo" --arg ref "$ref" --argjson fresh "$fresh" '{repoUrl:$repoUrl,fresh:$fresh} + (if $ref == "" then {} else {ref:$ref} end)')
    created=$(api_account POST "$BASE_URL/api/v1/kb" "$body")
    id=$(printf '%s' "$created" | "$JQ_BIN" -r '.sessionId // empty'); state=$(printf '%s' "$created" | "$JQ_BIN" -r '.state // empty'); reused=$(printf '%s' "$created" | "$JQ_BIN" -r '.reused // false')
    validate_session "$id"; save_session "$id" "$repo" "$reused"
    waited=0
    while [[ "$state" == provisioning && "$waited" -lt "$timeout" ]]; do
      sleep 1; waited=$((waited + 1)); status=$(api_account GET "$BASE_URL/api/v1/kb/$id/status"); state=$(printf '%s' "$status" | "$JQ_BIN" -r '.state // empty')
    done
    [[ "$state" == ready ]] || die "Knowledge Base did not become ready (state: ${state:-unknown})"
    "$JQ_BIN" -n --arg state "$state" --arg repoUrl "$repo" --argjson reused "$reused" '{state:$state,repoUrl:$repoUrl,reused:$reused}'
    ;;
  status)
    id=$(current_session "${1:-}"); [[ $# -le 1 ]] || die "usage: kb.sh status [session-id]"
    load_account_key; api_account GET "$BASE_URL/api/v1/kb/$id/status" | "$JQ_BIN" . ;;
  query)
    requested=""
    if [[ "${1:-}" == kb_* ]]; then requested="$1"; shift; fi
    tool="${1:-}"; [[ -n "$tool" ]] || die "query tool required"; shift
    id=$(current_session "$requested"); payload=$(build_query "$tool" "$@")
    load_account_key; api_account POST "$BASE_URL/api/v1/kb/$id/query" "$payload" | "$JQ_BIN" . ;;
  close)
    requested=""; dry=0
    if [[ "${1:-}" == kb_* ]]; then requested="$1"; shift; fi
    while [[ $# -gt 0 ]]; do case "$1" in --dry-run) dry=1; shift ;; *) die "unexpected close argument: $1" ;; esac; done
    id=$(current_session "$requested")
    if [[ "$dry" -eq 1 ]]; then "$JQ_BIN" -n --arg sessionId "$id" '{dryRun:true,action:"close",sessionId:$sessionId}'; exit 0; fi
    if [[ "$(session_reused "$id")" == true ]]; then
      clear_current
      "$JQ_BIN" -n --arg sessionId "$id" '{sessionId:$sessionId,state:"detached",reused:true}'
      exit 0
    fi
    load_account_key; api_account DELETE "$BASE_URL/api/v1/kb/$id" | "$JQ_BIN" .; clear_current ;;
  *) die "unknown command: $CMD" ;;
esac
