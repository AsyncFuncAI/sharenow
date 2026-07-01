#!/usr/bin/env bash
set -euo pipefail

# sharenow kb.sh: an agent-facing CLI for ephemeral codebase knowledge bases.
# Give it a public GitHub repo URL and it spins up a sandbox, clones the repo,
# indexes it with a fast code-graph engine (no embeddings), and answers structural
# queries in milliseconds: list functions, search symbols, read real source, or run
# a graph query. The knowledge base is temporary and self-cleans when it goes idle.
#
# Auth model: KEYLESS in v1 (no API key needed). Each session is created from a
# repo URL and identified by its sessionId, persisted in .sharenow/state.json so
# later commands find the live session without re-passing the id.
#
# Typical flow (one command does create + wait):
#   kb.sh open https://github.com/pallets/click
#   kb.sh query search_graph --label Function --limit 10
#   kb.sh source home-user-click.src.click.core.Command
#   kb.sh close

BASE_URL="https://sharenow.today"
ALLOW_NON_SHARENOW_BASE_URL=0
CLIENT=""
SESSION_OVERRIDE="${SHARENOW_KB_SESSION:-}"

usage() {
  cat <<'USAGE'
Usage: kb.sh [global options] <command> [args]

Global options:
  --base-url <url>       API base (default: https://sharenow.today)
  --allow-nonsharenow-base-url
                         Allow talking to a non-default API base URL
  --session <kb_...>     Session id override (or $SHARENOW_KB_SESSION)
  --client <name>        Agent name for attribution (e.g. cursor, claude-code)

Commands:
  open <repo-url> [--timeout <sec>]   Create a KB from a public GitHub URL and wait
                                      until it is ready (default timeout 60s). Prints
                                      the sessionId + project and saves the session.
  create <repo-url>                   Create only (do not wait); prints sessionId + state.
  status                              Print the current session's state (and project when ready).
  query <tool> [args]                 Run a query against the ready session. Tools + args:
                                        architecture                             orient: languages, entry points, routes, hotspots
                                        schema                                   node labels + edge types (run before `graph`)
                                        search_graph  [--label <L>] [--name <re>] [--file <re>]
                                                      [--min-degree <n>] [--max-degree <n>]
                                                      [--exclude-entry-points] [--limit <n>] [--offset <n>]
                                        search_code   --pattern <text>
                                        source        --qualified-name <qname>   read real source (get_code_snippet)
                                        trace         --function <qname> [--direction inbound|outbound|both]
                                                      [--depth 1-5] [--risk-labels]   call paths (trace_path)
                                        graph         --query "<cypher>"          arbitrary read-only query (query_graph)
  source <qualified-name>             Shorthand for: query source --qualified-name <qname>
  close                               Delete the current session (frees the sandbox now).

The active session is remembered in .sharenow/state.json under .kb.current, so
status/query/source/close act on the last opened KB without repeating the id. Use
--session to target a specific one. Only public https github.com repos are accepted.
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

CLIENT_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) BASE_URL="$2"; shift 2 ;;
    --allow-nonsharenow-base-url) ALLOW_NON_SHARENOW_BASE_URL=1; shift ;;
    --session) SESSION_OVERRIDE="$2"; shift 2 ;;
    --client) CLIENT="$2"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; break ;;
    -*) die "unknown global option: $1" ;;
    *) break ;;
  esac
done

[[ $# -ge 1 ]] || usage
COMMAND="$1"; shift

# Guard: sending anything to a non-default base needs the explicit opt-in flag.
if [[ "$BASE_URL" != "https://sharenow.today" && "$ALLOW_NON_SHARENOW_BASE_URL" -ne 1 ]]; then
  die "refusing a non-default --base-url without --allow-nonsharenow-base-url"
fi

if [[ -n "$CLIENT" ]]; then
  normalized_client=$(echo "$CLIENT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')
  CLIENT_ARGS=(-H "x-sharenow-client: $normalized_client")
fi

STATE_DIR=".sharenow"
STATE_FILE="${STATE_DIR}/state.json"

save_current_session() {
  local id="$1" repo="$2" project="$3"
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
  "$JQ_BIN" --arg id "$id" --arg repo "$repo" --arg project "$project" \
    '.kb = (.kb // {}) | .kb.current = $id | .kb.byId = (.kb.byId // {}) | .kb.byId[$id] = {repoUrl: $repo, project: $project}' \
    "$STATE_FILE" > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

current_session() {
  if [[ -n "$SESSION_OVERRIDE" ]]; then echo "$SESSION_OVERRIDE"; return; fi
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  "$JQ_BIN" -r '.kb.current // ""' "$STATE_FILE" 2>/dev/null || echo ""
}

# Keyless HTTP call. Errors on a non-2xx and surfaces the JSON `.error`.
api() {
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"
  local tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}" \
      -H "content-type: application/json" -d "$body")
  else
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}")
  fi
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    local err
    err=$("$JQ_BIN" -r '.error // .message // empty' "$tmp" 2>/dev/null || true)
    [[ -n "$err" ]] || err="$(cat "$tmp")"
    rm -f "$tmp"
    die "HTTP $code: $err"
  fi
  cat "$tmp"
  rm -f "$tmp"
}

require_session() {
  local sid
  sid="$(current_session)"
  [[ -n "$sid" ]] || die "no active KB session (run: kb.sh open <repo-url>)"
  echo "$sid"
}

# Build the per-tool query JSON payload from flags. The project is injected server
# side, so it is never sent here. Prints the JSON body for POST /:id/query.
build_query_body() {
  local tool="$1"; shift
  local label="" name="" limit="" pattern="" qname="" cypher=""
  local file="" offset="" min_degree="" max_degree="" exclude_entry_points=""
  local function_name="" direction="" depth="" risk_labels=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --label) label="$2"; shift 2 ;;
      --name) name="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      --offset) offset="$2"; shift 2 ;;
      --file) file="$2"; shift 2 ;;
      --min-degree) min_degree="$2"; shift 2 ;;
      --max-degree) max_degree="$2"; shift 2 ;;
      --exclude-entry-points) exclude_entry_points=true; shift ;;
      --pattern) pattern="$2"; shift 2 ;;
      --qualified-name) qname="$2"; shift 2 ;;
      --query) cypher="$2"; shift 2 ;;
      --function) function_name="$2"; shift 2 ;;
      --direction) direction="$2"; shift 2 ;;
      --depth) depth="$2"; shift 2 ;;
      --risk-labels) risk_labels=true; shift ;;
      *) die "unknown query option: $1" ;;
    esac
  done
  # The args object uses the SERVER's camelCase KbQueryArgs keys (namePattern,
  # filePattern, ...); the server maps them to cbmem's snake_case. Do NOT emit
  # snake_case here or the server drops the filter.
  case "$tool" in
    search_graph)
      # NOTE: bind to $lbl/$nm/$lim (etc.), NOT $label - `label` is a reserved jq
      # keyword and a `$label` variable fails to compile. Object KEYS are unaffected.
      # Degree is TWO ints (minDegree/maxDegree), NOT a degree_filters object.
      "$JQ_BIN" -nc \
        --arg lbl "$label" --arg nm "$name" --arg lim "$limit" \
        --arg fp "$file" --arg off "$offset" \
        --arg mnd "$min_degree" --arg mxd "$max_degree" \
        --argjson xep "${exclude_entry_points:-false}" \
        '{tool:"search_graph", args:( {}
           + (if $lbl!="" then {label:$lbl} else {} end)
           + (if $nm!="" then {namePattern:$nm} else {} end)
           + (if $fp!="" then {filePattern:$fp} else {} end)
           + (if $mnd!="" then {minDegree:($mnd|tonumber)} else {} end)
           + (if $mxd!="" then {maxDegree:($mxd|tonumber)} else {} end)
           + (if $xep then {excludeEntryPoints:true} else {} end)
           + (if $lim!="" then {limit:($lim|tonumber)} else {} end)
           + (if $off!="" then {offset:($off|tonumber)} else {} end) )}'
      ;;
    search_code)
      [[ -n "$pattern" ]] || die "search_code requires --pattern"
      "$JQ_BIN" -nc --arg pattern "$pattern" '{tool:"search_code", args:{pattern:$pattern}}'
      ;;
    source)
      [[ -n "$qname" ]] || die "source requires --qualified-name"
      "$JQ_BIN" -nc --arg q "$qname" '{tool:"get_code_snippet", args:{qualifiedName:$q}}'
      ;;
    graph)
      [[ -n "$cypher" ]] || die "graph requires --query"
      "$JQ_BIN" -nc --arg q "$cypher" '{tool:"query_graph", args:{query:$q}}'
      ;;
    architecture)
      # Project-only: the server injects the project, so there are no client args.
      "$JQ_BIN" -nc '{tool:"get_architecture", args:{}}'
      ;;
    schema)
      "$JQ_BIN" -nc '{tool:"get_graph_schema", args:{}}'
      ;;
    trace)
      [[ -n "$function_name" ]] || die "trace requires --function"
      "$JQ_BIN" -nc \
        --arg fn "$function_name" --arg dir "$direction" --arg dep "$depth" \
        --argjson risk "${risk_labels:-false}" \
        '{tool:"trace_path", args:( {functionName:$fn}
           + (if $dir!="" then {direction:$dir} else {} end)
           + (if $dep!="" then {depth:($dep|tonumber)} else {} end)
           + (if $risk then {riskLabels:true} else {} end) )}'
      ;;
    *) die "unknown tool: $tool (use search_graph|search_code|source|graph|architecture|schema|trace)" ;;
  esac
}

# Validate a public https github.com repo URL (the v1 allowlist, mirrored client
# side so an obviously-bad URL fails before a round trip).
assert_github_url() {
  local url="$1"
  [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/?$ || "$url" =~ ^https://github\.com/[^/]+/[^/]+\.git$ ]] \
    || die "only public https://github.com/<owner>/<repo> URLs are accepted (got: $url)"
}

cmd_create() {
  [[ $# -ge 1 ]] || die "create requires a repo URL"
  local url="$1"
  assert_github_url "$url"
  local body resp id slug state
  body=$("$JQ_BIN" -nc --arg u "$url" '{repoUrl:$u}')
  resp=$(api POST "$BASE_URL/api/v1/kb" "$body")
  id=$(echo "$resp" | "$JQ_BIN" -r '.sessionId')
  slug=$(echo "$resp" | "$JQ_BIN" -r '.slug // ""')
  state=$(echo "$resp" | "$JQ_BIN" -r '.state')
  save_current_session "$id" "$url" ""
  echo "sessionId: $id"
  [[ -n "$slug" ]] && echo "slug: $slug"
  echo "state: $state"
  echo "$id"
}

cmd_status() {
  local sid resp state project
  sid="$(require_session)"
  resp=$(api GET "$BASE_URL/api/v1/kb/$sid/status")
  state=$(echo "$resp" | "$JQ_BIN" -r '.state')
  project=$(echo "$resp" | "$JQ_BIN" -r '.project // ""')
  echo "state: $state"
  [[ -n "$project" ]] && echo "project: $project"
  echo "$resp"
}

cmd_open() {
  [[ $# -ge 1 ]] || die "open requires a repo URL"
  local url="$1"; shift
  local timeout=60
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      *) die "unknown open option: $1" ;;
    esac
  done
  assert_github_url "$url"
  local body resp id
  body=$("$JQ_BIN" -nc --arg u "$url" '{repoUrl:$u}')
  resp=$(api POST "$BASE_URL/api/v1/kb" "$body")
  id=$(echo "$resp" | "$JQ_BIN" -r '.sessionId')
  save_current_session "$id" "$url" ""
  echo "opening $url" >&2
  echo "sessionId: $id" >&2
  # Poll status until ready | failed | timeout.
  local waited=0 state project
  while [[ "$waited" -lt "$timeout" ]]; do
    resp=$(api GET "$BASE_URL/api/v1/kb/$id/status")
    state=$(echo "$resp" | "$JQ_BIN" -r '.state')
    case "$state" in
      ready)
        project=$(echo "$resp" | "$JQ_BIN" -r '.project // ""')
        save_current_session "$id" "$url" "$project"
        echo "state: ready" >&2
        echo "project: $project" >&2
        echo "$id"
        return 0
        ;;
      failed)
        die "indexing failed: $(echo "$resp" | "$JQ_BIN" -r '.error // "unknown error"')"
        ;;
    esac
    sleep 3
    waited=$((waited + 3))
  done
  die "timed out after ${timeout}s waiting for ready (last state: ${state:-unknown}); check: kb.sh status"
}

cmd_query() {
  [[ $# -ge 1 ]] || die "query requires a tool (architecture|schema|search_graph|search_code|source|trace|graph)"
  local tool="$1"; shift
  local sid body resp
  sid="$(require_session)"
  body=$(build_query_body "$tool" "$@")
  resp=$(api POST "$BASE_URL/api/v1/kb/$sid/query" "$body")
  # Print cbmem's result object verbatim (pretty when a tty, compact otherwise).
  if [[ -t 1 ]]; then echo "$resp" | "$JQ_BIN" '.result'; else echo "$resp" | "$JQ_BIN" -c '.result'; fi
}

cmd_source() {
  [[ $# -ge 1 ]] || die "source requires a qualified name"
  cmd_query source --qualified-name "$1"
}

cmd_close() {
  local sid resp
  sid="$(require_session)"
  resp=$(api DELETE "$BASE_URL/api/v1/kb/$sid")
  echo "$resp" | "$JQ_BIN" -r '"closed: \(.sessionId) (\(.state))"'
}

case "$COMMAND" in
  open)   cmd_open "$@" ;;
  create) cmd_create "$@" ;;
  status) cmd_status "$@" ;;
  query)  cmd_query "$@" ;;
  source) cmd_source "$@" ;;
  close)  cmd_close "$@" ;;
  *) die "unknown command: $COMMAND (see: kb.sh --help)" ;;
esac
