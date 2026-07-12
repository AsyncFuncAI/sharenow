#!/usr/bin/env bash
set -euo pipefail

# sharenow kb.sh: an agent-facing CLI for ephemeral codebase knowledge bases.
# Give it a public GitHub repo URL, or a local directory path, and it spins up a
# sandbox, materializes the code (git clone, or a gitignore-aware tar upload),
# indexes it with a fast code-graph engine (no embeddings), and answers structural
# queries in milliseconds: list functions, search symbols, read real source, or run
# a graph query. The knowledge base is temporary and self-cleans when it goes idle.
#
# Auth model: KEYLESS in v1 (no API key needed). Each session is created from a
# repo URL or local path and identified by its sessionId, persisted in
# .sharenow/state.json so later commands find the live session without
# re-passing the id.
#
# Typical flow (one command does create + wait):
#   kb.sh open https://github.com/pallets/click   # or: kb.sh open .
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

Global options (accepted anywhere on the command line, before or after the command):
  --base-url <url>       API base (default: https://sharenow.today)
  --allow-nonsharenow-base-url
                         Allow talking to a non-default API base URL
  --session <kb_...>     Session id override (or $SHARENOW_KB_SESSION)
  --client <name>        Agent name for attribution (e.g. cursor, claude-code)

Commands:
  open <repo-url|path> [--timeout <sec>] [--fresh]
                                      Create a KB from a public GitHub URL or a local
                                      directory (e.g. `.`) and wait until it is ready
                                      (default timeout 60s). Polls status for you until
                                      ready, so no separate `status` call is needed here.
                                      Prints the sessionId + project and saves the session.
                                      A repeat open of the same GitHub repo may reuse an
                                      existing ready session (~1s, shared with other agents);
                                      it prints `reused: true`. --fresh forces a new,
                                      isolated session instead of reusing one.
  create <repo-url|path>              Create only (do not wait); prints sessionId + state.
  status                              Re-check the current session's state later (and project
                                      when ready). `open` already polls until ready.
  query [tool] [args]                 Run a query against the ready session. With no tool,
                                      defaults to `architecture` (orient first). Tools + args:
                                        architecture                             orient: languages, entry points, routes, hotspots
                                        schema                                   node labels + edge types (run before `graph`)
                                        search_graph  [--label <L>] [--name <re>] [--file <re>]
                                                      [--min-degree <n>] [--max-degree <n>]
                                                      [--exclude-entry-points] [--limit <n>] [--offset <n>]
                                        search_code   --pattern <text>
                                        source        --qualified-name <qname>   read real source (get_code_snippet)
                                        context       --qualified-name <qname>   symbol + depth-1 callers/callees in one call
                                        trace         --function <qname> [--direction inbound|outbound|both]
                                                      [--depth 1-5] [--risk-labels]   call paths (trace_path)
                                        graph         --query "<cypher>"          arbitrary read-only query (query_graph)
  source <qualified-name>             Shorthand for: query source --qualified-name <qname>
  context <qualified-name>            Shorthand for: query context --qualified-name <qname>.
                                      One call returns { symbol, callers, callees, warnings? }
                                      - the symbol source plus its depth-1 callers and callees.
                                      Reach for this first on "what is X / how is X used".
  cat <path> [--from <n>] [--to <n>]  Read a raw file from the indexed repo by its
                                      repo-relative path (configs, READMEs, module
                                      top-level code that has no symbol). Output is
                                      capped at 64KB; page big files with --from/--to
                                      (1-based lines). Prefer `source` for symbols.
  close                               Free the current session. A session THIS client
                                      provisioned fresh is DELETEd (frees the sandbox now).
                                      A session obtained via reuse is shared with other
                                      agents, so close only detaches locally and lets it
                                      expire on idle - it is never DELETEd.

The active session is remembered in .sharenow/state.json under .kb.current, so
status/query/source/close act on the last opened KB without repeating the id. Use
--session to target a specific one. URL targets must be public https github.com
repos; a local directory is tarred client-side (gitignore-aware inside a git work
tree) and uploaded, capped at 32MiB compressed.

Each tool returns a different JSON envelope; see the "Response shapes" table in
SKILL.md for the top-level shape of every tool (source also accepts an unprefixed
dot-suffix name, e.g. `core.Command`).
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

# Shared HTTP response handling (needs JQ_BIN + die, both defined above).
. "$SCRIPT_DIR/lib/http.sh"

CLIENT_ARGS=()

# Global options are accepted ANYWHERE on the command line, not just before the
# command: agents habitually append `--client claude-code` after the subcommand
# (the shape publish.sh accepts), and a "global flags first" rule kept failing
# them with "unknown open option: --client". This pre-scan walks the whole argv
# once, consumes the four global options wherever they appear, and keeps every
# other argument in order for the command dispatch below.
#
# KB_VALUE_OPTS lists every value-taking SUBCOMMAND option, so an option's VALUE
# is never misread as a global flag (e.g. `--name "--client"` stays a literal
# name pattern). Keep it in sync when a subcommand gains a new value-taking
# option; boolean options (--fresh, --exclude-entry-points, --risk-labels) need
# no entry. Everything after a literal `--` is kept verbatim.
KB_VALUE_OPTS=" --timeout --label --name --limit --offset --file --min-degree --max-degree --pattern --qualified-name --query --function --direction --depth --from --to "
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-url) [[ $# -ge 2 ]] || die "--base-url requires a value"; BASE_URL="$2"; shift 2 ;;
    --allow-nonsharenow-base-url) ALLOW_NON_SHARENOW_BASE_URL=1; shift ;;
    --session) [[ $# -ge 2 ]] || die "--session requires a value"; SESSION_OVERRIDE="$2"; shift 2 ;;
    --client) [[ $# -ge 2 ]] || die "--client requires a value"; CLIENT="$2"; shift 2 ;;
    -h|--help) usage ;;
    --) shift; ARGS+=("$@"); break ;;
    *)
      if [[ "$KB_VALUE_OPTS" == *" $1 "* && $# -ge 2 ]]; then
        ARGS+=("$1" "$2"); shift 2
      else
        ARGS+=("$1"); shift
      fi
      ;;
  esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

[[ $# -ge 1 ]] || usage
COMMAND="$1"; shift

# Guard: sending anything to a non-default base needs the explicit opt-in flag.
if [[ "$BASE_URL" != "https://sharenow.today" && "$ALLOW_NON_SHARENOW_BASE_URL" -ne 1 ]]; then
  die "refusing a non-default --base-url without --allow-nonsharenow-base-url"
fi

if [[ -n "$CLIENT" ]]; then
  normalized_client=$(echo "$CLIENT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')
  normalized_client="${normalized_client#-}"
  normalized_client="${normalized_client%-}"
  if [[ -n "$normalized_client" ]]; then
    CLIENT_ARGS=(-H "x-sharenow-client: ${normalized_client}/kb-sh")
  fi
fi

STATE_DIR=".sharenow"
STATE_FILE="${STATE_DIR}/state.json"

save_current_session() {
  local id="$1" repo="$2" project="$3" reused="${4:-false}"
  mkdir -p "$STATE_DIR"
  [[ -f "$STATE_FILE" ]] || echo '{}' > "$STATE_FILE"
  # Write to a UNIQUE temp in the same directory (same filesystem, so `mv` stays
  # atomic) instead of a fixed "$STATE_FILE.tmp": concurrent invocations in one
  # directory would otherwise clobber each other's temp and lose/corrupt the file.
  # rm the temp on any jq failure so a bad write never leaves a stray file behind.
  # `reused` records that this session was HANDED BACK by the server (an existing
  # ready session for the same repo), so close knows not to DELETE a shared session.
  local tmp
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || die "cannot create temp state file in $STATE_DIR"
  if "$JQ_BIN" --arg id "$id" --arg repo "$repo" --arg project "$project" \
    --argjson reused "${reused:-false}" \
    '.kb = (.kb // {}) | .kb.current = $id | .kb.byId = (.kb.byId // {}) | .kb.byId[$id] = {repoUrl: $repo, project: $project, reused: $reused}' \
    "$STATE_FILE" > "$tmp"; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
    die "failed to update $STATE_FILE"
  fi
}

current_session() {
  if [[ -n "$SESSION_OVERRIDE" ]]; then echo "$SESSION_OVERRIDE"; return; fi
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  "$JQ_BIN" -r '.kb.current // ""' "$STATE_FILE" 2>/dev/null || echo ""
}

# The shared response tail (curl wrote the body to a temp file + gave the status;
# surface a clean error or print the body) now lives in lib/http.sh as
# http_handle_response, sourced above. api()/api_upload_gzip() call it below.

# Keyless HTTP call. Errors on a non-2xx and surfaces the JSON `.error`.
api() {
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"
  local tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(curl -sS --max-time "${KB_HTTP_DEADLINE:-150}" -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}" \
      -H "content-type: application/json" -d "$body")
  else
    code=$(curl -sS --max-time "${KB_HTTP_DEADLINE:-150}" -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}")
  fi
  http_handle_response "$code" "$tmp"
}

# Raw-body variant of api(): POSTs a file's bytes verbatim (application/gzip),
# used only by the local-directory upload. Same non-2xx handling as api(), so a
# server-side 413/400 surfaces its JSON `.error` cleanly.
api_upload_gzip() {
  local url="$1" file="$2"
  local tmp code
  tmp=$(mktemp)
  code=$(curl -sS --max-time "${KB_HTTP_DEADLINE:-150}" -o "$tmp" -w "%{http_code}" -X POST "$url" \
    "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}" \
    -H "content-type: application/gzip" --data-binary "@$file")
  http_handle_response "$code" "$tmp"
}

require_session() {
  local sid
  sid="$(current_session)"
  [[ -n "$sid" ]] || die "no active KB session (run: kb.sh open <repo-url|path>)"
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
    context)
      # Server-side composite: symbol + inbound/outbound wiring in one call. Same
      # positional arg as source (suffix-friendly qualifiedName); the tool name IS
      # "context" (not a cbmem tool) - the server composes it from get_code_snippet
      # + trace_path depth 1.
      [[ -n "$qname" ]] || die "context requires --qualified-name"
      "$JQ_BIN" -nc --arg q "$qname" '{tool:"context", args:{qualifiedName:$q}}'
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
    *) die "unknown tool: $tool (use search_graph|search_code|source|context|graph|architecture|schema|trace)" ;;
  esac
}

# Validate a public https github.com repo URL (the v1 allowlist, mirrored client
# side so an obviously-bad URL fails before a round trip).
assert_github_url() {
  local url="$1"
  [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/?$ || "$url" =~ ^https://github\.com/[^/]+/[^/]+\.git$ ]] \
    || die "only public https://github.com/<owner>/<repo> URLs are accepted (got: $url); a local directory path is also a valid target (e.g. kb.sh open .)"
}

# ── Local-directory targets (v1.2) ─────────────────────────────────────────────
# open/create accept a local directory as well as a GitHub URL: the client tars
# the directory (gitignore-aware inside a git work tree), size-checks it, and
# POSTs the gzipped archive as a raw body to /api/v1/kb/local. From the 202 on,
# the lifecycle (status/query/source/close) is identical to the GitHub flow.

# Client-side mirror of the server's upload cap (32MiB compressed). The server
# cap is authoritative; this mirror just turns an oversize directory into a fast
# local error instead of a 413 after shipping the whole archive.
UPLOAD_MAX_BYTES=33554432

# The archive (and the file-list scratch) are built into mktemp files; the EXIT
# trap guarantees cleanup on every path (success, die, signal). Written `-z || rm`
# so the trap body itself can never fail and mask the script's real exit status
# under set -e.
ARCHIVE_TMP=""
LIST_TMP=""
cleanup_archive() {
  [[ -z "$ARCHIVE_TMP" ]] || rm -f "$ARCHIVE_TMP"
  [[ -z "$LIST_TMP" ]] || rm -f "$LIST_TMP"
}
trap cleanup_archive EXIT

# Sanitize a directory basename into the server's name charset ([A-Za-z0-9._-],
# max 64 chars). The name is only a directory label inside the per-session
# sandbox, so lossy is fine: every out-of-charset byte becomes `-`, and an
# empty or dot-only result falls back to `workspace` (the server's own default).
sanitize_project_name() {
  local name
  name=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64)
  if [[ -z "$name" || "$name" == "." || "$name" == ".." ]]; then name="workspace"; fi
  printf '%s' "$name"
}

# Build the gzipped tar of a local directory into ARCHIVE_TMP. Inside a git work
# tree: tracked + untracked-unignored files (`git ls-files -co
# --exclude-standard`), which respects .gitignore and never ships `.git` itself,
# matching what "index my current directory" means. Outside git: plain tar with
# conservative default excludes for the usual dependency/build dirs. NUL
# delimiting keeps filenames with spaces intact, and the flag set (`--null -T`)
# works on both bsdtar (macOS) and GNU tar (Linux agents); with `--null`, GNU
# tar also reads dash-leading names verbatim instead of as options.
# COPYFILE_DISABLE stops macOS bsdtar from injecting AppleDouble `._*` metadata
# entries (junk files in the sandbox index); GNU tar ignores it harmlessly.
#
# The ls-files output is FILTERED into LIST_TMP before tar sees it, because git
# reads the INDEX, not the disk: (a) a tracked file whose working-tree copy was
# deleted (an unstaged deletion, an everyday mid-refactor state) is still emitted,
# and tar would abort the whole open on the missing path; (b) an initialized
# submodule is emitted as ONE gitlink directory entry, and tar -T would recurse
# the entire checkout, shipping the submodule's .git pointer and its
# own-gitignored files (.env, node_modules), breaking the gitignore promise. So:
# keep regular files and symlinks that still exist, drop real directories
# (gitlinks; submodules are deliberately not indexed) and vanished paths. The
# if/elif shape keeps every loop iteration exiting 0 under set -euo pipefail.
build_local_archive() {
  local dir="$1"
  ARCHIVE_TMP=$(mktemp "${TMPDIR:-/tmp}/sharenow-kb.XXXXXX")
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    LIST_TMP=$(mktemp "${TMPDIR:-/tmp}/sharenow-kb-list.XXXXXX")
    (cd "$dir" && git ls-files -co --exclude-standard -z) \
      | while IFS= read -r -d '' f; do
          if [[ -d "$dir/$f" && ! -L "$dir/$f" ]]; then
            : # gitlink (submodule) directory, excluded from the archive
          elif [[ -e "$dir/$f" || -L "$dir/$f" ]]; then
            printf '%s\0' "$f"
          fi
        done > "$LIST_TMP"
    # Fail fast on nothing-to-index (empty dir / everything gitignored): bsdtar
    # would silently build an empty archive (a "ready" KB with nothing in it)
    # while GNU tar aborts with a cryptic "cowardly refusing"; neither helps.
    [[ -s "$LIST_TMP" ]] || die "nothing to index in $dir (empty, or everything gitignored?)"
    (cd "$dir" && COPYFILE_DISABLE=1 tar --null -czf "$ARCHIVE_TMP" -T "$LIST_TMP")
  else
    COPYFILE_DISABLE=1 tar -czf "$ARCHIVE_TMP" \
      --exclude .git --exclude node_modules --exclude dist \
      --exclude build --exclude .next --exclude target \
      -C "$dir" .
  fi
}

# Source-detect an open/create target and stage the request. A URL keeps the v1
# GitHub path byte-identically; anything else must be an existing local
# directory. Sets (in the parent shell, so callers must NOT run this inside a
# command substitution):
#   TARGET_KIND   github | local
#   TARGET_LABEL  what save_current_session records: the URL verbatim, or
#                 local:<abs-path> (mirrors the server's repoUrl label)
#   TARGET_NAME   (local only) the sanitized project name sent as ?name=
#   ARCHIVE_TMP   (local only) the built, size-checked archive
TARGET_KIND=""
TARGET_LABEL=""
TARGET_NAME=""
resolve_target() {
  local target="$1"
  if [[ "$target" =~ ^https?:// ]]; then
    assert_github_url "$target"
    TARGET_KIND="github"
    TARGET_LABEL="$target"
    return
  fi
  [[ -d "$target" ]] || die "not a directory: $target (open takes a public GitHub URL or an existing local directory)"
  # Resolve to an absolute path so the saved label is stable regardless of where
  # later commands run from.
  local abs size
  abs=$(cd "$target" && pwd)
  TARGET_KIND="local"
  TARGET_LABEL="local:$abs"
  TARGET_NAME=$(sanitize_project_name "$(basename "$abs")")
  build_local_archive "$abs"
  size=$(wc -c < "$ARCHIVE_TMP" | tr -d '[:space:]')
  if [[ "$size" -gt "$UPLOAD_MAX_BYTES" ]]; then
    die "directory too large: compressed archive is ${size} bytes, over the ${UPLOAD_MAX_BYTES}-byte (32MiB) upload cap; exclude large artifacts (.gitignore is honored in a git work tree) or index a subdirectory"
  fi
}

# Fire the create request for the resolved target and print the create JSON. Both
# sources return the same {sessionId, slug, state} shape; a GitHub create may also
# carry {reused:true, state:"ready"} when the server hands back an existing session.
# FRESH=1 (from `open --fresh`) sends {"fresh":true} to force a new provision;
# local uploads never reuse, so the flag is a no-op there.
FRESH=0
request_create() {
  if [[ "$TARGET_KIND" == "github" ]]; then
    local body
    if [[ "$FRESH" -eq 1 ]]; then
      body=$("$JQ_BIN" -nc --arg u "$TARGET_LABEL" '{repoUrl:$u, fresh:true}')
    else
      body=$("$JQ_BIN" -nc --arg u "$TARGET_LABEL" '{repoUrl:$u}')
    fi
    api POST "$BASE_URL/api/v1/kb" "$body"
  else
    api_upload_gzip \
      "$BASE_URL/api/v1/kb/local?name=$("$JQ_BIN" -nr --arg v "$TARGET_NAME" '$v|@uri')" \
      "$ARCHIVE_TMP"
  fi
}

cmd_create() {
  [[ $# -ge 1 ]] || die "create requires a repo URL or local directory"
  resolve_target "$1"
  local resp id slug state reused
  resp=$(request_create)
  id=$(echo "$resp" | "$JQ_BIN" -r '.sessionId')
  slug=$(echo "$resp" | "$JQ_BIN" -r '.slug // ""')
  state=$(echo "$resp" | "$JQ_BIN" -r '.state')
  # Record reuse so a later close on this session detaches instead of DELETEing it.
  reused=$(echo "$resp" | "$JQ_BIN" -r 'if .reused == true then "true" else "false" end')
  save_current_session "$id" "$TARGET_LABEL" "" "$reused"
  echo "sessionId: $id"
  [[ -n "$slug" ]] && echo "slug: $slug"
  echo "state: $state"
  [[ "$reused" == "true" ]] && echo "reused: true" >&2
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
  [[ $# -ge 1 ]] || die "open requires a repo URL or local directory"
  local target="$1"; shift
  local timeout=60
  FRESH=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      --fresh) FRESH=1; shift ;;
      *) die "unknown open option: $1" ;;
    esac
  done
  resolve_target "$target"
  local resp id reused
  resp=$(request_create)
  id=$(echo "$resp" | "$JQ_BIN" -r '.sessionId')
  # The server marks a handed-back existing session with reused:true. Record it so
  # `close` knows this session is shared and must not be DELETEd.
  reused=$(echo "$resp" | "$JQ_BIN" -r 'if .reused == true then "true" else "false" end')
  save_current_session "$id" "$TARGET_LABEL" "" "$reused"
  echo "opening $TARGET_LABEL" >&2
  echo "sessionId: $id" >&2
  # Poll status until ready | failed | timeout. Ramp the delay (0.5s, 1s, 2s, then
  # a 3s cap) so a fast index is caught quickly while a slow one settles into the
  # same steady cadence the old fixed sleep used. `waited` tracks real elapsed time
  # (fractional-aware) so --timeout keeps its wall-clock meaning.
  local waited=0 state project delay
  while awk "BEGIN{exit !($waited < $timeout)}"; do
    resp=$(api GET "$BASE_URL/api/v1/kb/$id/status")
    state=$(echo "$resp" | "$JQ_BIN" -r '.state')
    case "$state" in
      ready)
        project=$(echo "$resp" | "$JQ_BIN" -r '.project // ""')
        # Preserve the reused flag captured from the create response (the status
        # payload does not carry it), so close still sees a shared session.
        save_current_session "$id" "$TARGET_LABEL" "$project" "$reused"
        echo "state: ready" >&2
        echo "project: $project" >&2
        # A reused session was handed back from an existing ready provision: print
        # it AFTER the ready line so an agent knows this open was shared (and cheap).
        [[ "$reused" == "true" ]] && echo "reused: true" >&2
        echo "$id"
        return 0
        ;;
      failed)
        die "indexing failed: $(echo "$resp" | "$JQ_BIN" -r '.error // "unknown error"')"
        ;;
    esac
    # Backoff schedule: 0.5 -> 1 -> 2 -> 3 (capped). Derived from elapsed time so it
    # holds regardless of how long each status round trip takes.
    if   awk "BEGIN{exit !($waited < 0.5)}"; then delay=0.5
    elif awk "BEGIN{exit !($waited < 1.5)}"; then delay=1
    elif awk "BEGIN{exit !($waited < 3.5)}"; then delay=2
    else delay=3
    fi
    sleep "$delay"
    waited=$(awk "BEGIN{print $waited + $delay}")
  done
  die "timed out after ${timeout}s waiting for ready (last state: ${state:-unknown}); the session may still be provisioning, so re-check with: kb.sh status; if you are abandoning it, kb.sh close frees the sandbox"
}

cmd_query() {
  # Bare `query` (no tool) defaults to the architecture tool: the right first move
  # for orienting in an unfamiliar repo. A named tool is passed through unchanged;
  # an unknown tool still errors in build_query_body with the valid-tool list.
  local tool="architecture"
  if [[ $# -ge 1 ]]; then tool="$1"; shift; fi
  local sid body resp
  sid="$(require_session)"
  body=$(build_query_body "$tool" "$@")
  resp=$(api POST "$BASE_URL/api/v1/kb/$sid/query" "$body")
  # Print cbmem's result object verbatim (pretty when a tty, compact otherwise).
  if [[ -t 1 ]]; then echo "$resp" | "$JQ_BIN" '.result'; else echo "$resp" | "$JQ_BIN" -c '.result'; fi
  # A successful query with zero hits is a valid result, not an error (exit stays 0
  # and stdout above is untouched). But a silent empty set often means the filters or
  # regex were too narrow, or the requested node label just does not exist on this
  # graph (label sets vary per language). Nudge toward the two orientation commands.
  case "$tool" in
    search_graph|search_code|graph)
      local empty
      empty=$(echo "$resp" | "$JQ_BIN" -r \
        '(.result | if type=="object" then (.results // .rows) else null end) as $r | if ($r|type)=="array" and ($r|length)==0 then "1" else "0" end')
      if [[ "$empty" == "1" ]]; then
        echo "hint: no results. Filters/regex may be too narrow, and node labels vary per graph (a label valid on one repo may not exist here). Try 'query architecture' or 'query schema' to see the graph's real labels and shapes." >&2
      fi
      ;;
  esac
}

cmd_source() {
  [[ $# -ge 1 ]] || die "source requires a qualified name"
  cmd_query source --qualified-name "$1"
}

# One-call "what is X and how is it wired": the symbol source plus its depth-1
# callers and callees, composed server side. Mirrors cmd_source's arg shape (a
# positional, suffix-friendly qualified name) and prints the result verbatim like
# every other tool (pretty on a tty, compact when piped) via cmd_query.
cmd_context() {
  [[ $# -ge 1 ]] || die "context requires a qualified name"
  cmd_query context --qualified-name "$1"
}

# Read a raw file from the indexed repo (POST /:id/file). Prints the CONTENT raw
# on stdout (not JSON) so it pipes like cat; a truncation warning goes to stderr.
# The path is repo-relative; --from/--to are 1-based line numbers (either alone
# is an open range). Symbol reads should keep using `source` - this is the
# escape hatch for files the code graph has no symbol for.
cmd_cat() {
  [[ $# -ge 1 ]] || die "cat requires a repo-relative file path"
  local path="$1"; shift
  local from="" to=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      --to) to="$2"; shift 2 ;;
      *) die "unknown cat option: $1 (use --from <n> / --to <n>)" ;;
    esac
  done
  local sid body resp
  sid="$(require_session)"
  body=$("$JQ_BIN" -nc --arg p "$path" --arg f "$from" --arg t "$to" \
    '{path:$p}
     + (if $f!="" then {startLine:($f|tonumber)} else {} end)
     + (if $t!="" then {endLine:($t|tonumber)} else {} end)')
  resp=$(api POST "$BASE_URL/api/v1/kb/$sid/file" "$body")
  if [[ "$(echo "$resp" | "$JQ_BIN" -r '.result.truncated')" == "true" ]]; then
    echo "warning: output truncated at 64KB; page with --from/--to" >&2
  fi
  # -j prints the string raw with NO added trailing newline (content is verbatim).
  echo "$resp" | "$JQ_BIN" -j '.result.content'
}

# Read the recorded `reused` flag for a session id from state.json (default false
# when there is no state file, no entry, or the field is absent).
session_reused() {
  local id="$1"
  [[ -f "$STATE_FILE" ]] || { echo "false"; return; }
  "$JQ_BIN" -r --arg id "$id" '.kb.byId[$id].reused // false' "$STATE_FILE" 2>/dev/null || echo "false"
}

# Clear .kb.current locally without touching the server. Used when detaching from a
# shared (reused) session: the entry stays in byId, but this client stops pointing at it.
clear_current_session() {
  [[ -f "$STATE_FILE" ]] || return 0
  local tmp
  tmp=$(mktemp "$STATE_DIR/.state.XXXXXX") || die "cannot create temp state file in $STATE_DIR"
  if "$JQ_BIN" 'if (.kb | type) == "object" then .kb.current = null else . end' \
    "$STATE_FILE" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
  fi
}

cmd_close() {
  local sid resp
  sid="$(require_session)"
  # S2 mitigation: a session we obtained by REUSE is shared with other agents, so a
  # polite client must not DELETE it (that would yank the sandbox out from under
  # them; it self-heals on the next open, but destroying shared state is rude). We
  # only detach locally and let it expire on idle. A session THIS client provisioned
  # fresh is ours to delete, so it keeps the normal DELETE behavior.
  if [[ "$(session_reused "$sid")" == "true" ]]; then
    echo "session $sid was obtained via reuse (shared with other agents); not deleting it - it expires on idle. Detached locally." >&2
    clear_current_session
    return 0
  fi
  resp=$(api DELETE "$BASE_URL/api/v1/kb/$sid")
  echo "$resp" | "$JQ_BIN" -r '"closed: \(.sessionId) (\(.state))"'
}

case "$COMMAND" in
  open)   cmd_open "$@" ;;
  create) cmd_create "$@" ;;
  status) cmd_status "$@" ;;
  query)  cmd_query "$@" ;;
  source) cmd_source "$@" ;;
  context) cmd_context "$@" ;;
  cat)    cmd_cat "$@" ;;
  close)  cmd_close "$@" ;;
  *) die "unknown command: $COMMAND (see: kb.sh --help)" ;;
esac
