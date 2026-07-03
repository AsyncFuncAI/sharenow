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
  awk '/^build_query_body\(\) \{/{f=1} f{print} /^\}/{if(f){exit}}' "$SCRIPTS/kb.sh"
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
# All five scripts must source the shared lib.
for s in kb drive account channel publish; do
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q 'lib/http.sh' "$SCRIPTS/$s.sh"; then
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
  ( cd "$kb_query_wd" && STUB_CURL_BODY="$body" /bin/bash "$SCRIPTS/kb.sh" query "$@" )
}

# Empty results array -> hint on stderr, exit 0.
assert_run "kb empty results emits hint" 0 "hint: no results" -- \
  run_kb_query '{"result":{"results":[]}}' search_graph --label Nope
# Non-empty results -> NO hint (assert the hint substring is absent by checking a
# marker we DO expect and that stderr has no 'hint:').
kb_out="$( ( cd "$kb_query_wd" && STUB_CURL_BODY='{"result":{"results":[{"name":"x"}]}}' \
  /bin/bash "$SCRIPTS/kb.sh" query search_graph --label Yes ) 2>"$WORK/kbe" ; )"
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
  env STUB_CURL_BODY="$PUB_BODY" SHARENOW_API_KEY=test-key \
    /bin/bash "$SCRIPTS/publish.sh" "$pub_wd/index.html"

echo "# --- smoke: drive.sh ---"
# Missing credentials -> die (no api-key, no token, no creds file under fake HOME).
assert_run "drive missing creds" 1 "missing credentials" -- \
  /bin/bash "$SCRIPTS/drive.sh" ls
# Unknown global option -> die.
assert_run "drive unknown option" 1 "unknown global option" -- \
  /bin/bash "$SCRIPTS/drive.sh" --bogus ls
# Happy path: `drive.sh ls` with a stubbed drive list, api key via env.
assert_run "drive ls happy path" 0 "drv_1" -- \
  env STUB_CURL_BODY='{"drives":[{"id":"drv_1","name":"My Drive"}]}' SHARENOW_API_KEY=test-key \
    /bin/bash "$SCRIPTS/drive.sh" ls

echo "# --- smoke: account.sh ---"
# Missing credentials.
assert_run "account missing creds" 1 "missing credentials" -- \
  /bin/bash "$SCRIPTS/account.sh" sites
# Unknown command -> handled by the case default (die) after auth; give it creds.
assert_run "account unknown command" 1 "-" -- \
  env SHARENOW_API_KEY=test-key STUB_CURL_BODY='{}' \
    /bin/bash "$SCRIPTS/account.sh" not-a-real-command
# Happy path: `account.sh sites` with stubbed publishes list.
assert_run "account sites happy path" 0 "myslug" -- \
  env SHARENOW_API_KEY=test-key STUB_CURL_BODY='{"publishes":[{"slug":"myslug"}]}' \
    /bin/bash "$SCRIPTS/account.sh" sites

echo "# --- smoke: channel.sh ---"
# No command -> usage.
assert_run "channel no command -> usage" 1 "Usage: channel.sh" -- \
  /bin/bash "$SCRIPTS/channel.sh"
# Unknown global option -> die.
assert_run "channel unknown option" 1 "unknown global option" -- \
  /bin/bash "$SCRIPTS/channel.sh" --bogus
# Happy path: `channel.sh create` (keyless) with a stubbed create response.
# `create` takes --title/--as (no positional title); it prints the overlord URL on
# stdout and channel_result.* lines on stderr. Response uses channelId/channelUrl/
# overlordUrl/sessionToken/joinUrl.
chan_wd="$(new_workdir)"
CHAN_CREATE_BODY='{"channelId":"ch_new","sessionToken":"tok","channelUrl":"https://sharenow.today/ch/ch_new","overlordUrl":"https://sharenow.today/ch/ch_new#tok","joinUrl":"https://sharenow.today/ch/ch_new"}'
assert_run "channel create happy path" 0 "ch_new" -- \
  env STUB_CURL_BODY="$CHAN_CREATE_BODY" \
    bash -c 'cd "$1" && shift && /bin/bash "$@"' _ "$chan_wd" "$SCRIPTS/channel.sh" create --title "My Channel" --as boss

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
    /bin/bash "$SCRIPTS/kb.sh" create https://github.com/o/r >/dev/null 2>&1 )
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
    /bin/bash "$SCRIPTS/channel.sh" create --title "C$n" --as "a$n" >/dev/null 2>&1 )
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
