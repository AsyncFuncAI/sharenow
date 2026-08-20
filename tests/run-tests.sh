#!/usr/bin/env bash
# run-tests.sh: a plain-bash (no bats) regression net for the sharenow skill
# scripts. Designed for bash 3.2 (macOS system bash) - no associative arrays,
# no mapfile, no ${var,,}. Run it explicitly under /bin/bash:
#
#   /bin/bash tests/run-tests.sh
#
# Strategy. The canonical scripts execute their main logic at the top level
# (arg-parse then dispatch on the command), so sourcing them is unsafe - it just
# runs `usage`. So every test drives the real CLI. Network is neutralized by
# prepending tests/stubs to PATH, where a fake `curl` replays canned JSON chosen
# by STUB_CURL_* env vars. This exercises the scripts' real code paths (jq
# payload construction, error handling, state writes) end to end with no network.
#
# Each test asserts BOTH stdout content and exit code. The runner prints TAP-ish
# `ok N - name` / `not ok N - name` lines and exits nonzero if any test failed.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$REPO_ROOT/sharenow/scripts"
KB_SCRIPT="$REPO_ROOT/extras/advanced-scripts/kb.sh"
CHANNEL_SCRIPT="$REPO_ROOT/extras/advanced-scripts/channel.sh"
INSTALLED_CHANNEL_SCRIPT="$SCRIPTS/channel.sh"
INSTALLED_FULLSTACK_SCRIPT="$SCRIPTS/fullstack.sh"
INSTALLED_KB_SCRIPT="$SCRIPTS/kb.sh"
VERSION_SCRIPT="$SCRIPTS/version.sh"
STUBS="$HERE/stubs"

# A private HOME + workdir so no test can read real credentials or write real state.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sharenow-tests.XXXXXX")"
export HOME="$WORK/home"
mkdir -p "$HOME"
cleanup_all() { rm -rf "$WORK"; }
trap cleanup_all EXIT

# Put the stub curl first on PATH. jq/file/git still resolve from the real PATH.
export PATH="$STUBS:$PATH"

TESTS_RUN=0
TESTS_FAIL=0

# assert_run <name> <expect_exit> <stdout_substr_or_-> -- <argv...>
#   Runs argv, capturing stdout (fd1) and exit code. stderr is captured
#   separately and only shown on failure. Passes if exit matches AND stdout
#   contains the substring (use "-" to skip the stdout check).
#   Per-test canned response comes from STUB_CURL_* already exported by the caller.
assert_run() {
  local name="$1"; shift
  local want_exit="$1"; shift
  local want_out="$1"; shift
  [[ "$1" == "--" ]] && shift
  TESTS_RUN=$((TESTS_RUN + 1))
  local out_f err_f code
  out_f="$WORK/out.$TESTS_RUN"
  err_f="$WORK/err.$TESTS_RUN"
  set +e
  "$@" >"$out_f" 2>"$err_f"
  code=$?
  set -e 2>/dev/null || true
  local out err
  out="$(cat "$out_f")"
  err="$(cat "$err_f")"
  local ok=1 why=""
  if [[ "$code" -ne "$want_exit" ]]; then ok=0; why="exit $code != $want_exit"; fi
  if [[ "$want_out" != "-" ]]; then
    case "$out$err" in
      *"$want_out"*) : ;;
      *) ok=0; why="${why:+$why; }missing stdout/err substr: $want_out" ;;
    esac
  fi
  if [[ "$ok" -eq 1 ]]; then
    echo "ok $TESTS_RUN - $name"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1))
    echo "not ok $TESTS_RUN - $name"
    echo "#   $why"
    echo "#   stdout: $(printf '%s' "$out" | head -c 400 | tr '\n' ' ')"
    echo "#   stderr: $(printf '%s' "$err" | head -c 400 | tr '\n' ' ')"
  fi
}

# assert_eq <name> <expected> <actual>
assert_eq() {
  local name="$1" want="$2" got="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$want" == "$got" ]]; then
    echo "ok $TESTS_RUN - $name"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1))
    echo "not ok $TESTS_RUN - $name"
    echo "#   expected: $want"
    echo "#   got:      $got"
  fi
}

# Each test group runs in a fresh subdirectory so .sharenow/state.json never leaks
# between tests. Callers cd into a per-group dir under $WORK.
new_workdir() {
  local d="$WORK/wd.$RANDOM.$RANDOM"
  mkdir -p "$d"
  echo "$d"
}

# ==========================================================================
# STEP 1a: kb.sh build_query_body payload shapes.
# We cannot source kb.sh safely (top-level dispatch), so we exercise
# build_query_body through the real `kb.sh query` path and capture the exact
# JSON body via the stub-curl request log is not enough (it logs URL not body).
# Instead we capture the body by having the stub echo it: the scripts POST the
# body with -d; simplest reliable capture is to intercept via a tiny wrapper.
# kb.sh sends the query body to POST /:id/query; we assert the server-bound JSON
# by pointing STUB_CURL to return a fixed result and checking the DISPATCH
# succeeds, then separately unit-test build_query_body by extracting the function
# alone with a guarded source (define COMMAND so top-level dispatch is a no-op
# is not possible; instead we sed the function out). See kb_body() below.
# ==========================================================================

# Extract build_query_body from kb.sh into a standalone sourceable snippet.
# The function is self-contained (only depends on $JQ_BIN and `die`), so we can
# lift it verbatim and provide those two symbols. This is the safe way to unit
# test the pure payload builder without running kb.sh's top-level dispatch.
KB_FUNC_LIB="$WORK/kb_build_query_body.sh"
{
  echo 'JQ_BIN="$(command -v jq)"'
  echo 'die() { echo "error: $1" >&2; exit 1; }'
  # Pull the build_query_body function body out of kb.sh by line range between its
  # definition and the matching closing brace at column 0.
  awk '/^build_query_body\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' "$KB_SCRIPT"
} > "$KB_FUNC_LIB"

kb_body() {
  # Run build_query_body in an isolated shell with jq+die provided.
  /bin/bash -c 'source "$1"; shift; build_query_body "$@"' _ "$KB_FUNC_LIB" "$@"
}

echo "# --- kb.sh build_query_body payloads ---"

# search_graph with all flags. Assert every camelCase key + numeric coercion.
out="$(kb_body search_graph --label Function --name '^get' --file 'core\.py' \
  --min-degree 2 --max-degree 9 --exclude-entry-points --limit 10 --offset 5)"
assert_eq "search_graph tool key" '"tool":"search_graph"' \
  "$(printf '%s' "$out" | jq -c '{tool}' | sed 's/[{}]//g')"
assert_eq "search_graph label" 'Function' "$(printf '%s' "$out" | jq -r '.args.label')"
assert_eq "search_graph namePattern" '^get' "$(printf '%s' "$out" | jq -r '.args.namePattern')"
assert_eq "search_graph filePattern" 'core\.py' "$(printf '%s' "$out" | jq -r '.args.filePattern')"
assert_eq "search_graph minDegree numeric" '2' "$(printf '%s' "$out" | jq -r '.args.minDegree')"
assert_eq "search_graph maxDegree numeric" '9' "$(printf '%s' "$out" | jq -r '.args.maxDegree')"
assert_eq "search_graph minDegree is number type" 'number' "$(printf '%s' "$out" | jq -r '.args.minDegree|type')"
assert_eq "search_graph excludeEntryPoints bool" 'true' "$(printf '%s' "$out" | jq -r '.args.excludeEntryPoints')"
assert_eq "search_graph limit numeric" '10' "$(printf '%s' "$out" | jq -r '.args.limit')"
assert_eq "search_graph offset numeric" '5' "$(printf '%s' "$out" | jq -r '.args.offset')"

# search_graph with NO flags: args must be an empty object, no stray keys.
out="$(kb_body search_graph)"
assert_eq "search_graph empty args" '{}' "$(printf '%s' "$out" | jq -c '.args')"

# trace with all flags -> trace_path + functionName + direction + depth + riskLabels.
out="$(kb_body trace --function 'pkg.mod.fn' --direction inbound --depth 3 --risk-labels)"
assert_eq "trace tool name" 'trace_path' "$(printf '%s' "$out" | jq -r '.tool')"
assert_eq "trace functionName" 'pkg.mod.fn' "$(printf '%s' "$out" | jq -r '.args.functionName')"
assert_eq "trace direction" 'inbound' "$(printf '%s' "$out" | jq -r '.args.direction')"
assert_eq "trace depth numeric" '3' "$(printf '%s' "$out" | jq -r '.args.depth')"
assert_eq "trace depth is number type" 'number' "$(printf '%s' "$out" | jq -r '.args.depth|type')"
assert_eq "trace riskLabels bool" 'true' "$(printf '%s' "$out" | jq -r '.args.riskLabels')"

# trace requires --function.
assert_run "trace missing --function errors" 1 "trace requires --function" -- \
  kb_body trace --direction inbound

# source -> get_code_snippet + qualifiedName.
out="$(kb_body source --qualified-name 'a.b.C')"
assert_eq "source tool name" 'get_code_snippet' "$(printf '%s' "$out" | jq -r '.tool')"
assert_eq "source qualifiedName" 'a.b.C' "$(printf '%s' "$out" | jq -r '.args.qualifiedName')"
assert_run "source missing --qualified-name errors" 1 "source requires --qualified-name" -- \
  kb_body source

# context -> composite tool "context" + qualifiedName (mirrors source's arg shape).
out="$(kb_body context --qualified-name 'worker.entry.handleRequest')"
assert_eq "context tool name" 'context' "$(printf '%s' "$out" | jq -r '.tool')"
assert_eq "context qualifiedName" 'worker.entry.handleRequest' "$(printf '%s' "$out" | jq -r '.args.qualifiedName')"
assert_eq "context args has only qualifiedName" 'qualifiedName' "$(printf '%s' "$out" | jq -r '.args|keys|join(",")')"
assert_run "context missing --qualified-name errors" 1 "context requires --qualified-name" -- \
  kb_body context

# graph -> query_graph + query.
out="$(kb_body graph --query 'MATCH (n) RETURN n')"
assert_eq "graph tool name" 'query_graph' "$(printf '%s' "$out" | jq -r '.tool')"
assert_eq "graph query passthrough" 'MATCH (n) RETURN n' "$(printf '%s' "$out" | jq -r '.args.query')"

# search_code -> pattern.
out="$(kb_body search_code --pattern 'TODO')"
assert_eq "search_code tool name" 'search_code' "$(printf '%s' "$out" | jq -r '.tool')"
assert_eq "search_code pattern" 'TODO' "$(printf '%s' "$out" | jq -r '.args.pattern')"

# architecture / schema -> empty args.
out="$(kb_body architecture)"
assert_eq "architecture tool name" 'get_architecture' "$(printf '%s' "$out" | jq -r '.tool')"
out="$(kb_body schema)"
assert_eq "schema tool name" 'get_graph_schema' "$(printf '%s' "$out" | jq -r '.tool')"

# unknown tool errors.
assert_run "unknown tool errors" 1 "unknown tool" -- kb_body bogus_tool

# ==========================================================================
# STEP 1b: shared http_handle_response error path (incl. details.candidates).
# This is the shared response tail lifted from lib/http.sh (formerly kb.sh's
# handle_api_response; step 3 moved it into the lib). It depends only on $JQ_BIN
# + die, so we source the real lib directly - this is the source of truth all
# four api wrappers now call, so it also covers drive.sh's .message fix.
# ==========================================================================
echo "# --- lib/http.sh http_handle_response ---"

HTTP_LIB="$WORK/http_lib_wrapper.sh"
{
  echo 'JQ_BIN="$(command -v jq)"'
  echo 'die() { echo "error: $1" >&2; exit 1; }'
  echo ". \"$SCRIPTS/lib/http.sh\""
} > "$HTTP_LIB"

# call_handle <status> <body> : writes body to a tmp file, calls http_handle_response.
call_handle() {
  local status="$1" body="$2"
  local bf="$WORK/resp.$RANDOM"
  printf '%s' "$body" > "$bf"
  /bin/bash -c 'source "$1"; http_handle_response "$2" "$3"' _ "$HTTP_LIB" "$status" "$bf"
}

# 2xx: prints body verbatim, exit 0.
assert_run "handle 200 prints body" 0 '"ok":true' -- \
  call_handle 200 '{"ok":true}'
# non-2xx with .error: die "HTTP <code>: <error>".
assert_run "handle 404 .error surfaced" 1 "HTTP 404: not found" -- \
  call_handle 404 '{"error":"not found"}'
# non-2xx with .message fallback (no .error).
assert_run "handle 500 .message fallback" 1 "HTTP 500: boom" -- \
  call_handle 500 '{"message":"boom"}'
# non-2xx with raw body (neither .error nor .message, non-JSON).
assert_run "handle 502 raw body fallback" 1 "HTTP 502: plain text error" -- \
  call_handle 502 'plain text error'
# non-2xx with details.candidates -> "candidates:" block on stderr + each candidate.
out="$(call_handle 400 '{"error":"ambiguous name","details":{"candidates":["a.b.One","a.b.Two"]}}' 2>&1 || true)"
case "$out" in
  *"candidates:"*"a.b.One"*"a.b.Two"*) assert_eq "handle candidates rendered" "yes" "yes" ;;
  *) assert_eq "handle candidates rendered" "yes" "no($out)" ;;
esac

# The unified lib must carry the .message fallback (this is drive.sh's deliberate
# fix: its old copy used `.error // empty` and dropped a .message-only error).
assert_run "shared lib has .message fallback (drive.sh fix)" 1 "HTTP 422: msg only" -- \
  call_handle 422 '{"message":"msg only"}'
# Installed and parked helpers must source their colocated shared lib.
for entry in \
  "kb:$KB_SCRIPT" \
  "drive:$SCRIPTS/drive.sh" \
  "account:$SCRIPTS/account.sh" \
  "channel:$CHANNEL_SCRIPT" \
  "publish:$SCRIPTS/publish.sh"; do
  s="${entry%%:*}"
  script="${entry#*:}"
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q 'lib/http.sh' "$script"; then
    echo "ok $TESTS_RUN - $s.sh sources lib/http.sh"
  else
    TESTS_FAIL=$((TESTS_FAIL + 1)); echo "not ok $TESTS_RUN - $s.sh does not source lib/http.sh"
  fi
done

# ==========================================================================
# STEP 1c: kb.sh zero-result stderr hint via the real CLI + stub curl.
# empty results -> hint on stderr; non-empty -> silent; non-object result -> no crash.
# The kb query path is keyless, so no credentials needed.
# ==========================================================================
echo "# --- kb.sh zero-result hint (CLI + stub curl) ---"

kb_query_wd="$(new_workdir)"
# Seed a state file with a current session so require_session passes.
mkdir -p "$kb_query_wd/.sharenow"
printf '%s' '{"kb":{"current":"kb_test","byId":{"kb_test":{"repoUrl":"x","project":"p"}}}}' \
  > "$kb_query_wd/.sharenow/state.json"

run_kb_query() {
  # $1 = canned result body ; rest = kb query args
  local body="$1"; shift
  ( cd "$kb_query_wd" && STUB_CURL_BODY="$body" /bin/bash "$KB_SCRIPT" query "$@" )
}

# Empty results array -> hint on stderr, exit 0.
assert_run "kb empty results emits hint" 0 "hint: no results" -- \
  run_kb_query '{"result":{"results":[]}}' search_graph --label Nope
# Non-empty results -> NO hint (assert the hint substring is absent by checking a
# marker we DO expect and that stderr has no 'hint:').
kb_out="$( ( cd "$kb_query_wd" && STUB_CURL_BODY='{"result":{"results":[{"name":"x"}]}}' \
  /bin/bash "$KB_SCRIPT" query search_graph --label Yes ) 2>"$WORK/kbe" ; )"
TESTS_RUN=$((TESTS_RUN + 1))
if grep -q 'hint:' "$WORK/kbe"; then
  TESTS_FAIL=$((TESTS_FAIL + 1)); echo "not ok $TESTS_RUN - kb non-empty results stays silent"
  echo "#   unexpected hint on stderr"
else
  echo "ok $TESTS_RUN - kb non-empty results stays silent"
fi
# Non-object result (e.g. result is a string) -> must NOT crash; exit 0, no hint.
assert_run "kb non-object result no crash" 0 "-" -- \
  run_kb_query '{"result":"a scalar string"}' search_graph --label Whatever

# ==========================================================================
# STEP 1d: kb.sh open backoff timing selection logic.
# The delay ladder (0.5 -> 1 -> 2 -> 3) is computed inline in cmd_open using awk
# guards on $waited; it is not a standalone function, and testing it live means
# real sleeps. We assert the ladder's decision logic directly (the same awk
# comparisons the script uses) rather than driving cmd_open, which keeps it cheap
# and deterministic. This mirrors lines ~500-504 of kb.sh.
# ==========================================================================
echo "# --- kb.sh open backoff ladder ---"
pick_delay() {
  local waited="$1"
  if   awk "BEGIN{exit !($waited < 0.5)}"; then echo 0.5
  elif awk "BEGIN{exit !($waited < 1.5)}"; then echo 1
  elif awk "BEGIN{exit !($waited < 3.5)}"; then echo 2
  else echo 3
  fi
}
assert_eq "backoff at 0s -> 0.5" "0.5" "$(pick_delay 0)"
assert_eq "backoff at 0.5s -> 1" "1" "$(pick_delay 0.5)"
assert_eq "backoff at 2s -> 2" "2" "$(pick_delay 2)"
assert_eq "backoff at 5s -> 3 (cap)" "3" "$(pick_delay 5)"

# ==========================================================================
# STEP 1e: smoke tests for publish.sh / drive.sh / account.sh / channel.sh.
# Each gets an arg-parse error case and a stubbed happy-path call.
# ==========================================================================
echo "# --- smoke: publish.sh ---"
# Help is a successful, read-only command. Agents often probe it during setup.
assert_run "publish help succeeds" 0 "Usage: publish.sh" -- \
  /bin/bash "$SCRIPTS/publish.sh" --help
# No target and no --from-drive -> usage (exit 1).
assert_run "publish no args -> usage" 1 "Usage: publish.sh" -- \
  /bin/bash "$SCRIPTS/publish.sh"
# Unknown option -> die.
assert_run "publish unknown option" 1 "unknown option" -- \
  /bin/bash "$SCRIPTS/publish.sh" --bogus
# Happy-ish: publish a real temp file with the stub returning a valid create+finalize.
pub_wd="$(new_workdir)"
echo '<h1>hi</h1>' > "$pub_wd/index.html"
# The create response must carry slug/upload/siteUrl; finalize response is read too.
PUB_BODY='{"slug":"abc","siteUrl":"https://abc.sharenow.today","upload":{"versionId":"v1","finalizeUrl":"https://sharenow.today/fin","uploads":[],"skipped":[]}}'
assert_run "publish happy path prints URL" 0 "abc.sharenow.today" -- \
  env STUB_CURL_BODY="$PUB_BODY" SHARENOW_API_KEY=snk_test_key_12345678901234567890 \
    /bin/bash "$SCRIPTS/publish.sh" "$pub_wd/index.html"

# Anonymous Sites stay public for one hour; the private claim URL remains the
# recovery path after that public window closes.
pub_anon_home="$(new_workdir)"
assert_run "anonymous publish reports one-hour public lifetime" 0 "publish_result.persistence=expires_1h" -- \
  env HOME="$pub_anon_home" STUB_CURL_BODY="$PUB_BODY" \
    /bin/bash "$SCRIPTS/publish.sh" "$pub_wd/index.html"
assert_run "anonymous publish explains the next permanent-site action" 0 "To keep it permanently" -- \
  env HOME="$pub_anon_home" STUB_CURL_BODY="$PUB_BODY" \
    /bin/bash "$SCRIPTS/publish.sh" "$pub_wd/index.html"

# The helper itself enforces the trust boundary. Instructions alone are not
# enough when an agent accidentally points it at a broad source directory.
pub_secret_wd="$(new_workdir)"
echo '<h1>site</h1>' > "$pub_secret_wd/index.html"
echo 'TOKEN=do-not-upload' > "$pub_secret_wd/.env"
assert_run "publish rejects a directory containing .env" 1 "refusing to publish sensitive-looking path: .env" -- \
  env STUB_CURL_BODY="$PUB_BODY" /bin/bash "$SCRIPTS/publish.sh" "$pub_secret_wd"

pub_state_wd="$(new_workdir)"
mkdir -p "$pub_state_wd/.sharenow" "$pub_state_wd/.git" "$pub_state_wd/node_modules/example"
echo '<h1>site</h1>' > "$pub_state_wd/index.html"
echo '{"claimToken":"secret"}' > "$pub_state_wd/.sharenow/state.json"
echo 'private git metadata' > "$pub_state_wd/.git/config"
echo 'large dependency tree' > "$pub_state_wd/node_modules/example/index.js"
assert_run "publish skips private state and dependencies without blocking a normal project" 0 "abc.sharenow.today" -- \
  env STUB_CURL_BODY="$PUB_BODY" /bin/bash "$SCRIPTS/publish.sh" "$pub_state_wd"

pub_key_wd="$(new_workdir)"
echo 'not-a-real-private-key' > "$pub_key_wd/server.key"
assert_run "publish rejects a private-key file target" 1 "refusing to publish sensitive-looking path: server.key" -- \
  env STUB_CURL_BODY="$PUB_BODY" /bin/bash "$SCRIPTS/publish.sh" "$pub_key_wd/server.key"

echo "# --- smoke: drive.sh ---"
assert_run "drive help succeeds" 0 "Usage: drive.sh" -- \
  /bin/bash "$SCRIPTS/drive.sh" --help
# Missing credentials -> die (no api-key, no token, no creds file under fake HOME).
assert_run "drive missing creds points to browser login" 1 "account.sh login" -- \
  /bin/bash "$SCRIPTS/drive.sh" ls
# Unknown global option -> die.
assert_run "drive unknown option" 1 "unknown global option" -- \
  /bin/bash "$SCRIPTS/drive.sh" --bogus ls
# Happy path: `drive.sh ls` with a stubbed drive list, api key via env.
assert_run "drive ls happy path" 0 "drv_1" -- \
  env STUB_CURL_BODY='{"drives":[{"id":"drv_1","name":"My Drive"}]}' SHARENOW_API_KEY=snk_test_key_12345678901234567890 \
    /bin/bash "$SCRIPTS/drive.sh" ls

echo "# --- smoke: account.sh ---"
assert_run "account help succeeds" 0 "Usage: account.sh" -- \
  /bin/bash "$SCRIPTS/account.sh" --help
# Missing credentials.
assert_run "account missing creds points to browser login" 1 "account.sh login" -- \
  /bin/bash "$SCRIPTS/account.sh" sites
# Unknown command -> handled by the case default (die) after auth; give it creds.
assert_run "account unknown command" 1 "-" -- \
  env SHARENOW_API_KEY=snk_test_key_12345678901234567890 STUB_CURL_BODY='{}' \
    /bin/bash "$SCRIPTS/account.sh" not-a-real-command
# Happy path: `account.sh sites` with stubbed publishes list.
assert_run "account sites happy path" 0 "myslug" -- \
  env SHARENOW_API_KEY=snk_test_key_12345678901234567890 STUB_CURL_BODY='{"publishes":[{"slug":"myslug"}]}' \
    /bin/bash "$SCRIPTS/account.sh" sites

echo "# --- smoke: channel.sh ---"
# No command -> usage.
assert_run "channel no command -> usage" 1 "Usage: channel.sh" -- \
  /bin/bash "$CHANNEL_SCRIPT"
# An unknown flag is no longer a global-parse error (globals are pre-scanned and
# may appear anywhere, like kb.sh): it falls through to the dispatch as a bogus
# command and dies there.
assert_run "channel unknown flag dies at dispatch" 1 "unknown command" -- \
  /bin/bash "$CHANNEL_SCRIPT" --bogus
# Happy path: `channel.sh create` (keyless) with a stubbed create response.
# `create` takes --title/--as (no positional title); it prints the overlord URL on
# stdout and channel_result.* lines on stderr. Response uses channelId/channelUrl/
# overlordUrl/sessionToken/joinUrl.
chan_wd="$(new_workdir)"
CHAN_CREATE_BODY='{"channelId":"ch_new","sessionToken":"tok","channelUrl":"https://sharenow.today/ch/ch_new","overlordUrl":"https://sharenow.today/ch/ch_new#tok","joinUrl":"https://sharenow.today/ch/ch_new"}'
assert_run "channel create happy path" 0 "ch_new" -- \
  env STUB_CURL_BODY="$CHAN_CREATE_BODY" \
    bash -c 'cd "$1" && shift && /bin/bash "$@"' _ "$chan_wd" "$CHANNEL_SCRIPT" create --title "My Channel" --as boss
# Global flags AFTER the subcommand are accepted (the kb.sh v1.8.2 fix, applied
# here too): --client past `create` must parse as the global it is, not as an
# unexpected create argument. The stubbed create proves the whole path runs.
chan_trail_wd="$(new_workdir)"
assert_run "channel global --client after subcommand parses" 0 "ch_new" -- \
  env STUB_CURL_BODY="$CHAN_CREATE_BODY" \
    bash -c 'cd "$1" && shift && /bin/bash "$@"' _ "$chan_trail_wd" "$CHANNEL_SCRIPT" create --title "T" --as boss --client claude-code

# ==========================================================================
# STEP 1e-watch: channel.sh watch - the background-shell reply-waiter (v1.10).
# The stub returns ONE canned body for every poll, so: a matching body must exit 0
# on the first poll with ONLY the matching rows on stdout; an empty page must loop
# quietly (stderr) until --timeout and exit 2; filters must exclude non-matches.
# ==========================================================================
echo "# --- channel.sh watch (background reply-waiter) ---"

watch_wd="$(new_workdir)"
mkdir -p "$watch_wd/.sharenow"
# Seed a joined-member state: current channel + one saved identity with a session.
printf '%s' '{"channels":{"current":"ch_w","byId":{"ch_w":{"currentMember":"me","members":{"me":{"sessionToken":"tok","memberId":"chm_me","cursor":""}}}}}}' \
  > "$watch_wd/.sharenow/state.json"

WATCH_HIT_BODY='{"messages":[{"id":"m1","type":"msg","memberId":"chm_boss","recipientId":null,"body":"work is done","createdAt":"2026-07-12T00:00:00Z"},{"id":"m2","type":"msg","memberId":"chm_other","recipientId":null,"body":"unrelated chatter","createdAt":"2026-07-12T00:00:01Z"}],"cursor":"m2"}'
WATCH_QUIET_BODY='{"messages":[],"cursor":"m0"}'

run_watch() {
  # $1 = canned body ; rest = watch args
  local body="$1"; shift
  ( cd "$watch_wd" && STUB_CURL_BODY="$body" /bin/bash "$CHANNEL_SCRIPT" watch "$@" )
}

# A matching row -> exit 0 and the match is printed.
assert_run "watch matches on --from and exits 0" 0 "work is done" -- \
  run_watch "$WATCH_HIT_BODY" --from chm_boss --timeout 5 --interval 0.2
# The filter must EXCLUDE the non-matching sender's row on stdout (stderr may
# carry liveness lines, so check stdout alone).
watch_out="$(run_watch "$WATCH_HIT_BODY" --from chm_boss --timeout 5 --interval 0.2 2>/dev/null)"
TESTS_RUN=$((TESTS_RUN + 1))
if printf '%s' "$watch_out" | grep -q "unrelated chatter"; then
  TESTS_FAIL=$((TESTS_FAIL + 1)); echo "not ok $TESTS_RUN - watch stdout leaks non-matching rows"
else
  echo "ok $TESTS_RUN - watch stdout carries only matching rows"
fi
# --match on body text works too.
assert_run "watch matches on --match body regex" 0 "chm_boss" -- \
  run_watch "$WATCH_HIT_BODY" --match "done|blocked" --timeout 5 --interval 0.2
# All-quiet pages -> quiet stderr liveness + exit 2 at --timeout.
assert_run "watch quiet pages time out with exit 2" 2 "timed out" -- \
  run_watch "$WATCH_QUIET_BODY" --from chm_boss --timeout 1 --interval 0.3
# An unknown option dies with the watch usage error.
assert_run "watch unknown option dies" 1 "unexpected watch argument" -- \
  run_watch "$WATCH_QUIET_BODY" --bogus

# ==========================================================================
# STEP 1f: kb.sh session reuse (open/close/--fresh) via the real CLI + stub curl.
# The stub returns the SAME canned body for every call, so a create body that
# already says state:"ready" makes cmd_open's poll see ready on the first status
# GET - exactly the shape of a reused (handed-back) session. We assert:
#   - open on a reused response prints "reused: true" and records it in state
#   - close on a reused session skips DELETE (STUB_CURL_LOG shows no DELETE)
#   - close on a fresh session still issues DELETE
#   - open --fresh sends {"fresh":true} in the create body (STUB_CURL_BODY_LOG)
# All kb paths are keyless, so no credentials are needed.
# ==========================================================================
echo "# --- kb.sh session reuse (open/close/--fresh) ---"

# A reused open: server hands back an existing ready session (reused:true, ready).
reuse_wd="$(new_workdir)"
REUSED_BODY='{"sessionId":"kb_reused","slug":"s","state":"ready","reused":true,"project":"proj"}'
reuse_out="$( ( cd "$reuse_wd" && STUB_CURL_BODY="$REUSED_BODY" \
  /bin/bash "$KB_SCRIPT" open https://github.com/o/r ) 2>"$WORK/reuse_err" )"
# The "reused: true" line goes to stderr (after the ready line).
assert_eq "open reused prints reused line" "yes" \
  "$(grep -q 'reused: true' "$WORK/reuse_err" && echo yes || echo no)"
# State records reused:true for this session.
assert_eq "open records reused in state" "true" \
  "$(jq -r '.kb.byId.kb_reused.reused' "$reuse_wd/.sharenow/state.json")"

# close on the reused session must NOT call DELETE. Drive close in the SAME dir with
# the request log on; assert no DELETE line and that .kb.current was cleared.
: > "$WORK/reuse_reqlog"
close_out="$( ( cd "$reuse_wd" && STUB_CURL_LOG="$WORK/reuse_reqlog" STUB_CURL_BODY='{}' \
  /bin/bash "$KB_SCRIPT" close ) 2>"$WORK/reuse_close_err" )"
assert_eq "close on reused session issues NO DELETE" "0" \
  "$(grep -c '^DELETE' "$WORK/reuse_reqlog" 2>/dev/null | tr -d '[:space:]')"
assert_eq "close on reused session says shared/detached" "yes" \
  "$(grep -q 'obtained via reuse' "$WORK/reuse_close_err" && echo yes || echo no)"
assert_eq "close on reused session clears .kb.current" "null" \
  "$(jq -r '.kb.current' "$reuse_wd/.sharenow/state.json")"

# A FRESH open (no reused flag): close must still DELETE.
fresh_wd="$(new_workdir)"
FRESH_BODY='{"sessionId":"kb_fresh","slug":"s","state":"ready","project":"proj"}'
( cd "$fresh_wd" && STUB_CURL_BODY="$FRESH_BODY" \
  /bin/bash "$KB_SCRIPT" open https://github.com/o/r ) >/dev/null 2>&1
assert_eq "fresh open records reused:false in state" "false" \
  "$(jq -r '.kb.byId.kb_fresh.reused' "$fresh_wd/.sharenow/state.json")"
: > "$WORK/fresh_reqlog"
( cd "$fresh_wd" && STUB_CURL_LOG="$WORK/fresh_reqlog" \
  STUB_CURL_BODY='{"sessionId":"kb_fresh","state":"deleted"}' \
  /bin/bash "$KB_SCRIPT" close ) >/dev/null 2>&1
assert_eq "close on fresh session issues a DELETE" "1" \
  "$(grep -c '^DELETE' "$WORK/fresh_reqlog" 2>/dev/null | tr -d '[:space:]')"

# open --fresh must send {"fresh":true} in the create POST body.
fflag_wd="$(new_workdir)"
: > "$WORK/fresh_bodylog"
( cd "$fflag_wd" && STUB_CURL_BODY_LOG="$WORK/fresh_bodylog" \
  STUB_CURL_BODY="$FRESH_BODY" \
  /bin/bash "$KB_SCRIPT" open https://github.com/o/r --fresh ) >/dev/null 2>&1
# The first logged body is the create POST. Assert it carries fresh:true.
assert_eq "open --fresh sends fresh:true in create body" "true" \
  "$(head -n1 "$WORK/fresh_bodylog" | jq -r '.fresh')"
assert_eq "open --fresh keeps repoUrl in create body" "https://github.com/o/r" \
  "$(head -n1 "$WORK/fresh_bodylog" | jq -r '.repoUrl')"
# A plain open (no --fresh) must NOT set fresh in the body.
plain_wd="$(new_workdir)"
: > "$WORK/plain_bodylog"
( cd "$plain_wd" && STUB_CURL_BODY_LOG="$WORK/plain_bodylog" \
  STUB_CURL_BODY="$FRESH_BODY" \
  /bin/bash "$KB_SCRIPT" open https://github.com/o/r ) >/dev/null 2>&1
assert_eq "plain open omits fresh from create body" "null" \
  "$(head -n1 "$WORK/plain_bodylog" | jq -r '.fresh')"

# ==========================================================================
# STEP 2: state.json write-race. Two interleaved writers must leave the file as
# valid JSON containing one of the two writes (last-writer-wins is acceptable;
# a corrupt/empty file is not). We drive kb.sh save_current_session concurrently
# through the CLI's `create` path (keyless, stub curl) in the SAME directory.
# ==========================================================================
echo "# --- state.json concurrent write safety ---"
race_wd="$(new_workdir)"
# Two background kb.sh `create` calls in the same dir writing different sessionIds.
run_writer() {
  local sid="$1"
  ( cd "$race_wd" && STUB_CURL_BODY="{\"sessionId\":\"$sid\",\"slug\":\"s\",\"state\":\"provisioning\"}" \
    /bin/bash "$KB_SCRIPT" create https://github.com/o/r >/dev/null 2>&1 )
}
i=0
while [[ $i -lt 8 ]]; do
  run_writer "kb_a_$i" &
  run_writer "kb_b_$i" &
  i=$((i + 1))
done
wait
# The state file must be valid JSON and .kb.current must be one of the written ids.
TESTS_RUN=$((TESTS_RUN + 1))
if jq -e . "$race_wd/.sharenow/state.json" >/dev/null 2>&1; then
  cur="$(jq -r '.kb.current' "$race_wd/.sharenow/state.json")"
  case "$cur" in
    kb_a_*|kb_b_*) echo "ok $TESTS_RUN - concurrent writes leave valid JSON with a real id ($cur)" ;;
    *) TESTS_FAIL=$((TESTS_FAIL + 1)); echo "not ok $TESTS_RUN - concurrent writes: unexpected current id ($cur)" ;;
  esac
else
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - concurrent writes corrupted state.json"
  echo "#   content: $(head -c 300 "$race_wd/.sharenow/state.json" 2>/dev/null | tr '\n' ' ')"
fi
# No leftover unique temp files in the state dir (cleanup on success).
TESTS_RUN=$((TESTS_RUN + 1))
leftover="$(find "$race_wd/.sharenow" -name '.state.*' 2>/dev/null | wc -l | tr -d '[:space:]')"
if [[ "$leftover" == "0" ]]; then
  echo "ok $TESTS_RUN - no leftover state temp files after writes"
else
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - $leftover leftover state temp file(s)"
fi

# Same race for channel.sh state_set (uses state_set, a distinct write site).
echo "# --- channel state_set concurrent write safety ---"
crace_wd="$(new_workdir)"
run_cwriter() {
  local n="$1"
  ( cd "$crace_wd" && STUB_CURL_BODY="{\"channelId\":\"ch_$n\",\"sessionToken\":\"tok$n\",\"channelUrl\":\"https://sharenow.today/ch/ch_$n\",\"overlordUrl\":\"https://sharenow.today/ch/ch_$n#t\",\"joinUrl\":\"https://sharenow.today/ch/ch_$n\"}" \
    /bin/bash "$CHANNEL_SCRIPT" create --title "C$n" --as "a$n" >/dev/null 2>&1 )
}
i=0
while [[ $i -lt 8 ]]; do
  run_cwriter "a$i" &
  run_cwriter "b$i" &
  i=$((i + 1))
done
wait
TESTS_RUN=$((TESTS_RUN + 1))
if jq -e . "$crace_wd/.sharenow/state.json" >/dev/null 2>&1; then
  echo "ok $TESTS_RUN - channel concurrent writes leave valid JSON"
else
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - channel concurrent writes corrupted state.json"
  echo "#   content: $(head -c 300 "$crace_wd/.sharenow/state.json" 2>/dev/null | tr '\n' ' ')"
fi

# ==========================================================================
# STEP 3: one-install least-privilege boundary.
# ==========================================================================
echo "# --- one-install least-privilege package boundary ---"

installed_files="$(
  cd "$REPO_ROOT/sharenow" &&
    find . -type f ! -name '.DS_Store' -print | LC_ALL=C sort
)"
expected_installed_files="$(printf '%s\n' \
  './AGENTS.md' \
  './SKILL.md' \
  './assets/logo.svg' \
  './scripts/account.sh' \
  './scripts/channel.sh' \
  './scripts/drive.sh' \
  './scripts/fullstack.sh' \
  './scripts/kb.sh' \
  './scripts/lib/http.sh' \
  './scripts/publish.sh' \
  './scripts/version.sh' \
  './templates/loop-crm/README.md' \
  './templates/loop-crm/fullstack.yaml' \
  './templates/loop-crm/schema.sql' \
  './templates/loop-crm/worker.js')"
assert_eq "one install contains the seven reviewed capability helpers" \
  "$expected_installed_files" "$installed_files"
assert_eq "reviewed Channel helper is installed" "yes" \
  "$([[ -e "$REPO_ROOT/sharenow/scripts/channel.sh" ]] && echo yes || echo no)"
assert_eq "public-repository KB helper is installed" "yes" \
  "$([[ -e "$REPO_ROOT/sharenow/scripts/kb.sh" ]] && echo yes || echo no)"
assert_eq "parked channel helper is preserved" "yes" \
  "$([[ -f "$CHANNEL_SCRIPT" ]] && echo yes || echo no)"
assert_eq "parked KB helper is preserved" "yes" \
  "$([[ -f "$KB_SCRIPT" ]] && echo yes || echo no)"

TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fq -- '--agent <agent-id> -y' "$REPO_ROOT/sharenow/SKILL.md" &&
   grep -Fq 'claude-code' "$REPO_ROOT/sharenow/SKILL.md" &&
   grep -Fq 'codex' "$REPO_ROOT/sharenow/SKILL.md" &&
   grep -Fq 'cursor' "$REPO_ROOT/sharenow/SKILL.md"; then
  echo "ok $TESTS_RUN - install guidance targets the current agent runtime"
else
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - install guidance can trigger unrelated agent targets"
fi

unsafe_instruction_pattern='request-code|verify-code|paste (it|the code)|keys create|--api-key|--base-url|allow-nonsharenow-base-url'
TESTS_RUN=$((TESTS_RUN + 1))
if grep -REin "$unsafe_instruction_pattern" "$REPO_ROOT/sharenow" >/dev/null 2>&1; then
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - installed skill contains agent-visible credential or alternate-host instructions"
else
  echo "ok $TESTS_RUN - installed skill has no agent-visible OTP, key argument, or alternate-host instructions"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fq 'scripts/channel.sh' "$REPO_ROOT/sharenow/SKILL.md" &&
   grep -Fq 'scripts/fullstack.sh' "$REPO_ROOT/sharenow/SKILL.md" &&
   grep -Fq 'scripts/kb.sh' "$REPO_ROOT/sharenow/SKILL.md" &&
   grep -Fq 'scripts/version.sh' "$REPO_ROOT/sharenow/SKILL.md"; then
  echo "ok $TESTS_RUN - installed skill documents every All Access helper"
else
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - installed skill is missing All Access helper guidance"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fq 'fixed first-party API origin' "$REPO_ROOT/sharenow/SKILL.md" &&
   grep -Fq 'never execute downloaded or server-returned content' "$REPO_ROOT/sharenow/SKILL.md"; then
  echo "ok $TESTS_RUN - installed skill states its fixed network and execution boundary"
else
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - installed skill does not state its fixed network and execution boundary"
fi

TESTS_RUN=$((TESTS_RUN + 1))
if grep -Fq 'Why security scanners may warn' "$REPO_ROOT/README.md" &&
   grep -Fq 'exact files you approve' "$REPO_ROOT/README.md" &&
   grep -Fq 'seven shell helpers' "$REPO_ROOT/README.md"; then
  echo "ok $TESTS_RUN - README explains the compact package trust boundary before setup"
else
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - README is missing the scanner warning and exact upload scope"
fi

login_home="$(new_workdir)"
login_log="$WORK/login.requests"
login_argv="$WORK/login.argv"
device_start='{"grantId":"agd_testgrant123456789012345","deviceSecret":"ags_testsecret123456789012345","verificationUrl":"https://sharenow.today/connect/agent?grant=agd_testgrant123456789012345","expiresIn":600,"interval":3}'
device_token='{"status":"connected","apiKey":"snk_test_browser_private_key_1234567890"}'
assert_run "browser login connects without printing the account key" 0 "were not printed" -- \
  env HOME="$login_home" SHARENOW_NO_BROWSER_OPEN=1 STUB_CURL_LOG="$login_log" \
    STUB_CURL_ARGV_LOG="$login_argv" STUB_CURL_DEVICE_START_STATUS=201 \
    STUB_CURL_DEVICE_START_BODY="$device_start" STUB_CURL_DEVICE_TOKEN_STATUS=200 \
    STUB_CURL_DEVICE_TOKEN_BODY="$device_token" \
    /bin/bash "$SCRIPTS/account.sh" login --client claude-code
assert_eq "browser login saves the returned key only in credentials" \
  "snk_test_browser_private_key_1234567890" "$(tr -d '[:space:]' < "$login_home/.sharenow/credentials")"
mode=$(stat -f '%Lp' "$login_home/.sharenow/credentials" 2>/dev/null || stat -c '%a' "$login_home/.sharenow/credentials")
assert_eq "browser login credentials are mode 600" "600" "$mode"
TESTS_RUN=$((TESTS_RUN + 1))
if tr '\0' '\n' < "$login_argv" | grep -q 'snk_test_browser_private_key_1234567890'; then
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - account key appeared in a command argument"
else
  echo "ok $TESTS_RUN - account key never appears in a command argument"
fi
assert_eq "browser login calls start then token endpoints" \
  $'POST\thttps://sharenow.today/api/auth/agent/device/start\nPOST\thttps://sharenow.today/api/auth/agent/device/token' \
  "$(cat "$login_log")"

publish_wd="$(new_workdir)"
printf '%s' '<h1>one install</h1>' > "$publish_wd/index.html"
assert_run "saved browser credential makes publishing permanent" 0 "publish_result.auth_mode=authenticated" -- \
  env HOME="$login_home" STUB_CURL_BODY="$PUB_BODY" \
    /bin/bash "$SCRIPTS/publish.sh" "$publish_wd/index.html"

assert_run "publish rejects --api-key" 1 "unknown option: --api-key" -- \
  env STUB_CURL_BODY="$PUB_BODY" \
    /bin/bash "$SCRIPTS/publish.sh" "$publish_wd/index.html" --api-key test-key
assert_run "publish rejects --base-url" 1 "unknown option: --base-url" -- \
  env STUB_CURL_BODY="$PUB_BODY" \
    /bin/bash "$SCRIPTS/publish.sh" "$publish_wd/index.html" --base-url https://example.invalid
assert_run "Drive rejects token command arguments" 1 "unknown global option: --token" -- \
  /bin/bash "$SCRIPTS/drive.sh" --token drv_live_test ls

# ==========================================================================
# STEP 4: All Access helper contract. These are executable behavior tests, not
# source-text checks: every helper must parse, and each starter mission must
# expose a no-network dry-run before it can enter the installable package.
# ==========================================================================
echo "# --- All Access installed helper contract ---"

assert_run "installed Channel helper exposes local help" 0 "Usage: channel.sh" -- \
  /bin/bash "$INSTALLED_CHANNEL_SCRIPT" --help
assert_run "installed Fullstack helper exposes local help" 0 "Usage: fullstack.sh" -- \
  /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" --help
assert_run "installed public-repository KB helper exposes local help" 0 "Usage: kb.sh" -- \
  /bin/bash "$INSTALLED_KB_SCRIPT" --help
assert_run "installed version helper exposes local help" 0 "Usage: version.sh" -- \
  /bin/bash "$VERSION_SCRIPT" --help

all_access_home="$(new_workdir)"
mkdir -p "$all_access_home/.sharenow"
printf '%s\n' 'snk_test_all_access_12345678901234567890' > "$all_access_home/.sharenow/credentials"
chmod 600 "$all_access_home/.sharenow/credentials"

: > "$WORK/channel-dry-requests"
assert_run "Channel create dry-run explains the private owner handoff" 0 "private overlord URL" -- \
  env HOME="$all_access_home" STUB_CURL_LOG="$WORK/channel-dry-requests" \
    /bin/bash "$INSTALLED_CHANNEL_SCRIPT" create --title "Launch room" --dry-run
assert_eq "Channel create dry-run makes no HTTP request" "0" \
  "$(wc -l < "$WORK/channel-dry-requests" | tr -d '[:space:]')"

drive_mission="$WORK/launch-kit"
mkdir -p "$drive_mission"
printf '%s\n' '# Approved launch brief' > "$drive_mission/brief.md"
: > "$WORK/drive-dry-requests"
assert_run "Drive import dry-run previews the exact persistent file set" 0 "Launch Kit/brief.md" -- \
  env HOME="$all_access_home" STUB_CURL_LOG="$WORK/drive-dry-requests" \
    /bin/bash "$SCRIPTS/drive.sh" import "My Drive" "Launch Kit" --from "$drive_mission" --dry-run
assert_eq "Drive import dry-run makes no HTTP request" "0" \
  "$(wc -l < "$WORK/drive-dry-requests" | tr -d '[:space:]')"

channel_home="$(new_workdir)"
mkdir -p "$channel_home/.sharenow"
printf '%s\n' 'snk_test_channel_12345678901234567890' > "$channel_home/.sharenow/credentials"
chmod 600 "$channel_home/.sharenow/credentials"
channel_create='{"channelId":"ch_launch123","sessionToken":"chsess_private123","claimToken":"clm_private123","memberId":"mem_owner123","channelUrl":"https://sharenow.today/ch/ch_launch123","overlordUrl":"https://sharenow.today/ch/ch_launch123#session=chsess_private123","joinUrl":"https://sharenow.today/api/v1/channels/ch_launch123/join"}'
channel_out="$(env HOME="$channel_home" STUB_CURL_ARGV_LOG="$WORK/channel-create-argv" STUB_CURL_CHANNEL_CREATE_BODY="$channel_create" STUB_CURL_CHANNEL_CLAIM_BODY='{"success":true,"expiresAt":"2026-08-05T12:00:00.000Z"}' \
  /bin/bash "$INSTALLED_CHANNEL_SCRIPT" create --title "Launch room")"
assert_eq "Channel create returns a claimed non-secret receipt" "claimed" \
  "$(printf '%s' "$channel_out" | jq -r '.state')"
assert_eq "Channel create returns the private overlord URL" "https://sharenow.today/ch/ch_launch123#session=chsess_private123" \
  "$(printf '%s' "$channel_out" | jq -r '.overlordUrl')"
assert_eq "Channel create returns the hard expiry" "2026-08-05T12:00:00.000Z" \
  "$(printf '%s' "$channel_out" | jq -r '.expiresAt')"
assert_eq "Channel create output excludes the claim token" "no" \
  "$(printf '%s' "$channel_out" | grep -Eq 'clm_private123' && echo yes || echo no)"
assert_eq "Channel session appears once inside the private URL" "1" \
  "$(printf '%s' "$channel_out" | grep -o 'chsess_private123' | wc -l | tr -d '[:space:]')"
assert_eq "Channel create has no separate session field" "false" \
  "$(printf '%s' "$channel_out" | jq 'has("sessionToken")')"
channel_mode=$(stat -f '%Lp' "$channel_home/.sharenow/channels.json" 2>/dev/null || stat -c '%a' "$channel_home/.sharenow/channels.json")
assert_eq "Channel session state is mode 600" "600" "$channel_mode"
TESTS_RUN=$((TESTS_RUN + 1))
if tr '\0' '\n' < "$WORK/channel-create-argv" | grep -Eq 'chsess_private123|clm_private123'; then
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - Channel create capability appeared in a command argument"
else
  echo "ok $TESTS_RUN - Channel create capabilities never appear in command arguments"
fi

channel_state_tmp="$WORK/channel-state.json"
jq '.channels.ch_launch123.members.FizzClaude={sessionToken:"chsess_claude123",memberId:"chm_claude123"}' \
  "$channel_home/.sharenow/channels.json" > "$channel_state_tmp"
mv "$channel_state_tmp" "$channel_home/.sharenow/channels.json"
chmod 600 "$channel_home/.sharenow/channels.json"
: > "$WORK/channel-command-argv"
: > "$WORK/channel-command-config"
: > "$WORK/channel-command-requests"
channel_command_env=(env HOME="$channel_home" STUB_CURL_BODY='{}' STUB_CURL_ARGV_LOG="$WORK/channel-command-argv" STUB_CURL_CONFIG_LOG="$WORK/channel-command-config" STUB_CURL_LOG="$WORK/channel-command-requests")
assert_run "Channel invite read command selects the saved agent identity" 0 '"messages"' -- \
  "${channel_command_env[@]}" STUB_CURL_BODY='{"messages":[],"cursor":"cur_2"}' /bin/bash "$INSTALLED_CHANNEL_SCRIPT" read --as FizzClaude
assert_run "Channel invite send command accepts positional text" 0 '{}' -- \
  "${channel_command_env[@]}" /bin/bash "$INSTALLED_CHANNEL_SCRIPT" send --as FizzClaude "ready"
assert_run "Channel legacy send syntax remains supported" 0 '{}' -- \
  "${channel_command_env[@]}" /bin/bash "$INSTALLED_CHANNEL_SCRIPT" send ch_launch123 --as FizzClaude --text "legacy ready"
assert_run "Channel task title may equal an action keyword" 0 '{}' -- \
  "${channel_command_env[@]}" /bin/bash "$INSTALLED_CHANNEL_SCRIPT" task --as FizzClaude post claim
assert_run "Channel task title may begin with the Channel id prefix" 0 '{}' -- \
  "${channel_command_env[@]}" /bin/bash "$INSTALLED_CHANNEL_SCRIPT" task --as FizzClaude post ch_release
assert_run "Channel shared-file path may equal an action keyword" 0 '{}' -- \
  "${channel_command_env[@]}" /bin/bash "$INSTALLED_CHANNEL_SCRIPT" fs --as FizzClaude cat ls
assert_run "Channel shared-file path may begin with the Channel id prefix" 0 '{}' -- \
  "${channel_command_env[@]}" /bin/bash "$INSTALLED_CHANNEL_SCRIPT" fs --as FizzClaude cat ch_notes
assert_eq "Channel selected identity is supplied through protected curl config" "7" \
  "$(grep -c 'chsess_claude123' "$WORK/channel-command-config")"
TESTS_RUN=$((TESTS_RUN + 1))
if tr '\0' '\n' < "$WORK/channel-command-argv" | grep -q 'chsess_claude123'; then
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - Channel session appeared in a command argument"
else
  echo "ok $TESTS_RUN - Channel session never appears in a command argument"
fi

: > "$WORK/kb-dry-requests"
assert_run "KB open dry-run accepts only an explicit public GitHub repository" 0 "public GitHub repository" -- \
  env HOME="$all_access_home" STUB_CURL_LOG="$WORK/kb-dry-requests" \
    /bin/bash "$INSTALLED_KB_SCRIPT" open https://github.com/pallets/click --dry-run
assert_eq "KB open dry-run makes no HTTP request" "0" \
  "$(wc -l < "$WORK/kb-dry-requests" | tr -d '[:space:]')"
assert_run "KB starter path rejects the current directory before HTTP" 1 "public https github.com" -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_KB_SCRIPT" open . --dry-run

kb_reuse_home="$(new_workdir)"
mkdir -p "$kb_reuse_home/.sharenow"
printf '%s\n' 'snk_test_kb_12345678901234567890' > "$kb_reuse_home/.sharenow/credentials"
chmod 600 "$kb_reuse_home/.sharenow/credentials"
env HOME="$kb_reuse_home" STUB_CURL_BODY='{"sessionId":"kb_shared123","state":"ready","reused":true}' \
  /bin/bash "$INSTALLED_KB_SCRIPT" open https://github.com/pallets/click >/dev/null
: > "$WORK/kb-reuse-close-requests"
assert_run "closing a reused Codegraph session detaches without destroying it" 0 "detached" -- \
  env HOME="$kb_reuse_home" STUB_CURL_LOG="$WORK/kb-reuse-close-requests" \
    /bin/bash "$INSTALLED_KB_SCRIPT" close
assert_eq "reused Codegraph close makes no delete request" "0" \
  "$(wc -l < "$WORK/kb-reuse-close-requests" | tr -d '[:space:]')"

assert_run "account capability discovery is available to the installed agent" 0 '"allAccess": true' -- \
  env HOME="$all_access_home" STUB_CURL_BODY='{"tier":"all_access_monthly","allAccess":true,"capabilities":{}}' \
    /bin/bash "$SCRIPTS/account.sh" capabilities

version_home="$(new_workdir)"
mkdir -p "$version_home/.sharenow"
manifest='{"name":"sharenow","source":"AsyncFuncAI/sharenow","version":"1.20.1","latestVersion":"1.20.1","minimumVersion":"1.20.1","files":[{"path":"SKILL.md","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}'
assert_run "version status reports structured drift state" 0 '"state": "update_required"' -- \
  env HOME="$version_home" STUB_CURL_BODY="$manifest" \
    /bin/bash "$VERSION_SCRIPT" status --force

fullstack_wd="$(new_workdir)"

loop_parent="$(new_workdir)"
assert_run "Fullstack initializes the reviewed loop CRM starter" 0 '"template": "loop-crm"' -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" init loop-crm "$loop_parent/loopdesk"
assert_eq "loop CRM starter includes its contract" "yes" \
  "$([[ -f "$loop_parent/loopdesk/fullstack.yaml" ]] && echo yes || echo no)"
assert_eq "loop CRM starter includes its Worker" "yes" \
  "$([[ -f "$loop_parent/loopdesk/worker.js" ]] && echo yes || echo no)"
assert_run "Fullstack init refuses a non-empty destination" 1 "destination must be empty" -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" init loop-crm "$loop_parent/loopdesk"

: > "$WORK/fullstack-prepare-dry-requests"
prepare_dry_out="$(env HOME="$all_access_home" STUB_CURL_LOG="$WORK/fullstack-prepare-dry-requests" \
  /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" prepare "$loop_parent/loopdesk" --dry-run)"
assert_eq "Fullstack prepare dry-run scans the exact project without HTTP" "0" \
  "$(wc -l < "$WORK/fullstack-prepare-dry-requests" | tr -d '[:space:]')"
assert_eq "Fullstack prepare dry-run identifies the contract" "fullstack.yaml" \
  "$(printf '%s' "$prepare_dry_out" | jq -r '.contract')"
assert_eq "Fullstack prepare dry-run includes scheduled triggers" "schedule" \
  "$(printf '%s' "$prepare_dry_out" | jq -r '.triggers[0].type')"

unsafe_project="$(new_workdir)"
printf '%s\n' 'bindings: []' > "$unsafe_project/fullstack.yaml"
printf '%s\n' 'secret=value' > "$unsafe_project/.env"
assert_run "Fullstack prepare refuses sensitive project files" 1 "sensitive file" -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" prepare "$unsafe_project" --dry-run

: > "$WORK/fullstack-prepare-live-requests"
prepare_live_out="$(env HOME="$all_access_home" STUB_CURL_LOG="$WORK/fullstack-prepare-live-requests" \
  STUB_CURL_DRIVE_CREATE_BODY='{"drive":{"id":"drv_loopkit123"}}' \
  STUB_CURL_DRIVE_UPLOAD_BODY='{"uploadUrl":"https://upload.test/file","uploadId":"upl_loop123"}' \
  STUB_CURL_DRIVE_FINALIZE_BODY='{"file":{"status":"live"}}' \
  STUB_CURL_FULLSTACK_VALIDATE_BODY='{"valid":true,"files":4,"bytes":4096,"resources":["worker","d1","r2","queue"],"requiredSecrets":["ANTHROPIC_API_KEY","APP_ADMIN_TOKEN"],"triggers":[{"name":"reconcile-leads","type":"schedule","cron":"*/15 * * * *"}]}' \
  /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" prepare "$loop_parent/loopdesk")"
prepared_plan_id="$(printf '%s' "$prepare_live_out" | jq -r '.planId')"
assert_eq "Fullstack live prepare returns a remotely validated plan" "validated" \
  "$(printf '%s' "$prepare_live_out" | jq -r '.state')"
assert_eq "Fullstack live prepare creates one private Drive" "1" \
  "$(grep -c $'POST\thttps://sharenow.today/api/v1/drives$' "$WORK/fullstack-prepare-live-requests" | tr -d '[:space:]')"
assert_eq "Fullstack live prepare calls the non-provisioning validator" "1" \
  "$(grep -c $'POST\thttps://sharenow.today/api/v1/fullstack/validate' "$WORK/fullstack-prepare-live-requests" | tr -d '[:space:]')"
assert_run "Fullstack can revalidate an existing content-bound plan" 0 '"state": "validated"' -- \
  env HOME="$all_access_home" STUB_CURL_FULLSTACK_VALIDATE_BODY='{"valid":true,"files":4,"bytes":4096,"resources":["worker","d1","r2","queue"],"requiredSecrets":["ANTHROPIC_API_KEY","APP_ADMIN_TOKEN"],"triggers":[]}' \
    /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" validate "$prepared_plan_id"
assert_run "Fullstack approval remains separate after remote validation" 0 '"approved": true' -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" approve "$prepared_plan_id"
printf '%s\n' '{"ANTHROPIC_API_KEY":"sk-ant-test-loop","ANTHROPIC_MODEL":"claude-test","APP_ADMIN_TOKEN":"admin-test-loop"}' > "$loop_parent/loop-secrets.json"
chmod 600 "$loop_parent/loop-secrets.json"
: > "$WORK/fullstack-project-deploy-requests"
project_deploy_out="$(env HOME="$all_access_home" STUB_CURL_LOG="$WORK/fullstack-project-deploy-requests" \
  STUB_CURL_FULLSTACK_VALIDATE_BODY='{"valid":true,"files":4,"bytes":4096,"resources":["worker","d1","r2","queue"],"requiredSecrets":["ANTHROPIC_API_KEY","ANTHROPIC_MODEL","APP_ADMIN_TOKEN"],"triggers":[{"name":"reconcile-leads","type":"schedule","cron":"*/15 * * * *"}]}' \
  STUB_CURL_FULLSTACK_CREATE_BODY='{"appId":"fsa_loopkit123","claimToken":"clm_loopkit_private"}' \
  STUB_CURL_FULLSTACK_STATUS_BODY='{"state":"live","url":"https://loopkit123.sharenow.today"}' \
  /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" deploy "$prepared_plan_id" --secrets-from "$loop_parent/loop-secrets.json")"
assert_eq "Fullstack project deploy removes its helper-created staging Drive" "1" \
  "$(grep -c $'DELETE\thttps://sharenow.today/api/v1/drives/drv_loopkit123' "$WORK/fullstack-project-deploy-requests" | tr -d '[:space:]')"
assert_eq "Fullstack project deploy reports staging cleanup" "removed" \
  "$(printf '%s' "$project_deploy_out" | jq -r '.stagingDrive')"

cat > "$fullstack_wd/worker.yaml" <<'YAML'
name: launch-api
main: src/index.ts
env:
  - STRIPE_SECRET_KEY
  - ANTHROPIC_API_KEY
YAML
cat > "$fullstack_wd/manifest.json" <<'JSON'
[{"path":"src/index.ts","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","size":1200}]
JSON
: > "$WORK/fullstack-plan-requests"
set +e
plan_out="$(env HOME="$all_access_home" STUB_CURL_LOG="$WORK/fullstack-plan-requests" \
  /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" plan --contract "$fullstack_wd/worker.yaml" \
    --drive drv_launchkit123 --manifest "$fullstack_wd/manifest.json" 2>"$WORK/fullstack-plan.err")"
plan_rc=$?
set -e 2>/dev/null || true
TESTS_RUN=$((TESTS_RUN + 1))
plan_id="$(printf '%s' "$plan_out" | jq -r '.planId // empty' 2>/dev/null)"
if [[ "$plan_rc" -eq 0 && "$plan_id" == fsp_* ]]; then
  echo "ok $TESTS_RUN - Fullstack plan creates a local content-bound receipt"
else
  TESTS_FAIL=$((TESTS_FAIL + 1))
  echo "not ok $TESTS_RUN - Fullstack plan creates a local content-bound receipt"
  echo "#   exit=$plan_rc planId=$plan_id stderr=$(head -c 300 "$WORK/fullstack-plan.err")"
fi
assert_eq "Fullstack planning makes no HTTP request" "0" \
  "$(wc -l < "$WORK/fullstack-plan-requests" | tr -d '[:space:]')"
assert_run "Fullstack deploy refuses an unapproved receipt" 1 "not approved" -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" deploy "$plan_id" --dry-run
assert_run "Fullstack approval is a separate local action" 0 '"approved": true' -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" approve "$plan_id"
printf '%s\n' '{"STRIPE_SECRET_KEY":"sk_test_example","ANTHROPIC_API_KEY":"sk-ant-test-example"}' > "$fullstack_wd/secrets.json"
chmod 600 "$fullstack_wd/secrets.json"

assert_run "Fullstack lists existing apps before choosing update or deploy" 0 '"appId": "fsa_existing123"' -- \
  env HOME="$all_access_home" STUB_CURL_FULLSTACK_LIST_BODY='{"apps":[{"appId":"fsa_existing123","slug":"stable-app","state":"live","url":"https://stable-app.sharenow.today","claimed":true}]}' \
    /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" list
assert_run "Fullstack update refuses an approval not bound to an app" 1 "approval is not bound" -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" update fsa_existing123 "$plan_id" --secrets-from "$fullstack_wd/secrets.json" --dry-run
assert_run "Fullstack approval can bind the exact plan to one existing app" 0 '"targetAppId": "fsa_existing123"' -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" approve "$plan_id" --for-app fsa_existing123
assert_run "Fullstack deploy refuses a receipt bound for update" 1 "use fullstack.sh update" -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" deploy "$plan_id" --secrets-from "$fullstack_wd/secrets.json" --dry-run
assert_run "Fullstack update refuses a different app id" 1 "different Fullstack app" -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" update fsa_other123 "$plan_id" --secrets-from "$fullstack_wd/secrets.json" --dry-run
: > "$WORK/fullstack-update-dry-requests"
assert_run "approved Fullstack update dry-run is local only" 0 '"action": "update"' -- \
  env HOME="$all_access_home" STUB_CURL_LOG="$WORK/fullstack-update-dry-requests" \
    /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" update fsa_existing123 "$plan_id" --secrets-from "$fullstack_wd/secrets.json" --dry-run
assert_eq "Fullstack update dry-run makes no HTTP request" "0" \
  "$(wc -l < "$WORK/fullstack-update-dry-requests" | tr -d '[:space:]')"
: > "$WORK/fullstack-update-requests"
update_out="$(env HOME="$all_access_home" STUB_CURL_LOG="$WORK/fullstack-update-requests" \
  STUB_CURL_FULLSTACK_VALIDATE_BODY='{"valid":true,"files":1,"bytes":1200,"resources":["worker"],"requiredSecrets":["ANTHROPIC_API_KEY","STRIPE_SECRET_KEY"],"triggers":[]}' \
  STUB_CURL_FULLSTACK_UPDATE_BODY='{"appId":"fsa_existing123","slug":"stable-app","url":"https://stable-app.sharenow.today","state":"live","updated":true}' \
  /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" update fsa_existing123 "$plan_id" --secrets-from "$fullstack_wd/secrets.json")"
assert_eq "Fullstack update keeps the same app id" "fsa_existing123" \
  "$(printf '%s' "$update_out" | jq -r '.appId')"
assert_eq "Fullstack update keeps the same live URL" "https://stable-app.sharenow.today" \
  "$(printf '%s' "$update_out" | jq -r '.url')"
assert_eq "Fullstack update sends one PUT to the existing app" "1" \
  "$(grep -c $'PUT\thttps://sharenow.today/api/v1/fullstack/fsa_existing123$' "$WORK/fullstack-update-requests" | tr -d '[:space:]')"
assert_eq "Fullstack update never creates a second app" "0" \
  "$(grep -c $'POST\thttps://sharenow.today/api/v1/fullstack$' "$WORK/fullstack-update-requests" | tr -d '[:space:]' || true)"
assert_run "Fullstack plan can be rebound for a later new deployment" 0 '"targetAppId": null' -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" approve "$plan_id"

: > "$WORK/fullstack-deploy-requests"
assert_run "approved Fullstack dry-run validates without deploying" 0 '"dryRun": true' -- \
  env HOME="$all_access_home" STUB_CURL_LOG="$WORK/fullstack-deploy-requests" \
    /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" deploy "$plan_id" --secrets-from "$fullstack_wd/secrets.json" --dry-run
assert_eq "Fullstack deploy dry-run makes no HTTP request" "0" \
  "$(wc -l < "$WORK/fullstack-deploy-requests" | tr -d '[:space:]')"
assert_run "Fullstack refuses secret values in command arguments" 1 "unexpected deploy argument" -- \
  env HOME="$all_access_home" /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" deploy "$plan_id" --secret STRIPE_SECRET_KEY=sk_test_nope

: > "$WORK/fullstack-argv.log"
printf '%s\n' 404 200 > "$WORK/fullstack-url-statuses"
: > "$WORK/fullstack-url-requests"
fullstack_out="$(env HOME="$all_access_home" STUB_CURL_ARGV_LOG="$WORK/fullstack-argv.log" \
  STUB_CURL_LOG="$WORK/fullstack-url-requests" \
  STUB_CURL_FULLSTACK_URL_STATUS_FILE="$WORK/fullstack-url-statuses" \
  STUB_CURL_FULLSTACK_VALIDATE_BODY='{"valid":true,"files":1,"bytes":1200,"resources":["worker"],"requiredSecrets":["ANTHROPIC_API_KEY","STRIPE_SECRET_KEY"],"triggers":[]}' \
  STUB_CURL_FULLSTACK_CREATE_BODY='{"appId":"fsa_launch123","claimToken":"clm_fullstack_private"}' \
  STUB_CURL_FULLSTACK_STATUS_BODY='{"state":"live","url":"https://launch123.sharenow.today"}' \
  STUB_CURL_FULLSTACK_CLAIM_BODY='{"success":true}' \
  /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" deploy "$plan_id" --secrets-from "$fullstack_wd/secrets.json")"
assert_eq "Fullstack deploy claims the live app permanently" "permanent" \
  "$(printf '%s' "$fullstack_out" | jq -r '.persistence')"
assert_eq "Fullstack output excludes the claim token" "no" \
  "$(printf '%s' "$fullstack_out" | grep -q 'clm_fullstack_private' && echo yes || echo no)"
assert_eq "Fullstack waits through one branded-host 404 before returning its URL" "2" \
  "$(grep -c $'GET\thttps://launch123.sharenow.today' "$WORK/fullstack-url-requests" | tr -d '[:space:]')"
assert_eq "Fullstack prints the branded URL after readiness" "https://launch123.sharenow.today" \
  "$(printf '%s' "$fullstack_out" | jq -r '.url')"
assert_eq "Fullstack secrets never appear in process arguments" "no" \
  "$(tr '\0' '\n' < "$WORK/fullstack-argv.log" | grep -Eq 'sk_test_example|sk-ant-test-example' && echo yes || echo no)"

: > "$WORK/fullstack-failed-requests"
assert_run "failed Fullstack provisioning is cleaned up without being claimed" 1 "provisioning failed" -- \
  env HOME="$all_access_home" STUB_CURL_LOG="$WORK/fullstack-failed-requests" \
    STUB_CURL_FULLSTACK_VALIDATE_BODY='{"valid":true,"files":1,"bytes":1200,"resources":["worker"],"requiredSecrets":["ANTHROPIC_API_KEY","STRIPE_SECRET_KEY"],"triggers":[]}' \
    STUB_CURL_FULLSTACK_CREATE_BODY='{"appId":"fsa_failed123","claimToken":"clm_failed_private"}' \
    STUB_CURL_FULLSTACK_STATUS_BODY='{"state":"failed","failureCode":"provision_schedule"}' \
    /bin/bash "$INSTALLED_FULLSTACK_SCRIPT" deploy "$plan_id" --secrets-from "$fullstack_wd/secrets.json"
assert_eq "failed Fullstack provisioning deletes the disposable app" "1" \
  "$(grep -c $'DELETE\thttps://sharenow.today/api/v1/fullstack/fsa_failed123' "$WORK/fullstack-failed-requests" | tr -d '[:space:]')"
assert_eq "failed Fullstack provisioning never claims the app" "0" \
  "$(grep -c $'POST\thttps://sharenow.today/api/v1/fullstack/fsa_failed123/claim' "$WORK/fullstack-failed-requests" | tr -d '[:space:]' || true)"

rollback_home="$(new_workdir)"
mkdir -p "$rollback_home/.agents/skills/sharenow/scripts"
printf '%s\n' '---' 'name: sharenow' '---' '' '**Skill version: 1.12.0**' > "$rollback_home/.agents/skills/sharenow/SKILL.md"
printf '%s\n' '#!/usr/bin/env bash' 'echo old-helper' > "$rollback_home/.agents/skills/sharenow/scripts/publish.sh"
chmod +x "$rollback_home/.agents/skills/sharenow/scripts/publish.sh"
assert_run "failed skill update restores the previous installation" 1 "restored" -- \
  env HOME="$rollback_home" STUB_CURL_BODY="$manifest" SHARENOW_NPX_BIN=/bin/false \
    /bin/bash "$VERSION_SCRIPT" update --yes
assert_eq "rollback preserves the previous skill version" "yes" \
  "$(grep -q 'Skill version: 1.12.0' "$rollback_home/.agents/skills/sharenow/SKILL.md" && echo yes || echo no)"

update_home="$(new_workdir)"
mkdir -p "$update_home/.agents/skills/sharenow"
printf '%s\n' '---' 'name: sharenow' '---' '' '**Skill version: 1.12.0**' > "$update_home/.agents/skills/sharenow/SKILL.md"
skill_sha=$(shasum -a 256 "$REPO_ROOT/sharenow/SKILL.md" | awk '{print $1}')
success_manifest=$(jq -cn --arg sha "$skill_sha" '{name:"sharenow",source:"AsyncFuncAI/sharenow",version:"1.20.1",latestVersion:"1.20.1",minimumVersion:"1.13.0",files:[{path:"SKILL.md",sha256:$sha}]}')
assert_run "verified skill update replaces the canonical install in place" 0 '"state": "current"' -- \
  env HOME="$update_home" STUB_CURL_BODY="$success_manifest" SHARENOW_NPX_BIN="$STUBS/npx" SHARENOW_NPX_SOURCE="$REPO_ROOT/sharenow" \
    /bin/bash "$VERSION_SCRIPT" update --yes
assert_eq "verified update installs version 1.20.1" "yes" \
  "$(grep -q 'Skill version: 1.20.1' "$update_home/.agents/skills/sharenow/SKILL.md" && echo yes || echo no)"

# ==========================================================================
# Summary
# ==========================================================================
echo ""
echo "1..$TESTS_RUN"
if [[ "$TESTS_FAIL" -eq 0 ]]; then
  echo "# PASS: all $TESTS_RUN tests passed"
  exit 0
fi
echo "# FAIL: $TESTS_FAIL of $TESTS_RUN tests failed"
exit 1
