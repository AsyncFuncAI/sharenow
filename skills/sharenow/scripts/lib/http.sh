# http.sh: shared HTTP response handling for the sharenow skill scripts.
#
# This file is SOURCED, not executed. Every sharenow script computes its own
# SCRIPT_DIR and sources this as "$SCRIPT_DIR/lib/http.sh" AFTER it has defined
# the two symbols this code depends on:
#   - JQ_BIN : path to the jq binary (bundled or system)
#   - die    : die() { echo "error: $1" >&2; exit 1; }
#
# The whole scripts/ directory ships together in every skill layout, so the
# SCRIPT_DIR-relative path resolves in both the repo and an installed skill.
# There are no repo-root-relative paths here by design.
#
# What it factors out: the identical "curl wrote the body to a temp file and told
# me the status code; now surface a clean error or return the body" tail that was
# duplicated across kb.sh (handle_api_response), account.sh/drive.sh (api_json),
# and channel.sh (api_keyless/api_session). Each script keeps its own curl call
# (headers/auth differ per script); only this response tail is shared.
#
# NOTE (deliberate fix): drive.sh's copy previously extracted only `.error`
# (missing the `.message` fallback that account.sh and kb.sh already had). This
# unified version always uses `.error // .message // empty`, so a server error
# that reports `.message` now surfaces cleanly from drive.sh too, matching the
# other scripts.

# http_handle_response <http_status> <body_tmp_file>
#   On a 2xx: print the body verbatim to stdout, remove the temp file, return 0.
#   On a non-2xx: extract a human error (prefer JSON .error, then .message, else
#   the raw body), render any .details.candidates list to stderr, remove the temp
#   file, and exit nonzero via die (or a candidates-specific exit 1). The temp
#   file is removed on every path.
http_handle_response() {
  local code="$1" tmp="$2"
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    local err candidates
    err=$("$JQ_BIN" -r '.error // .message // empty' "$tmp" 2>/dev/null || true)
    [[ -n "$err" ]] || err="$(cat "$tmp")"
    candidates=$("$JQ_BIN" -r '.details.candidates // [] | .[]' "$tmp" 2>/dev/null || true)
    rm -f "$tmp"
    if [[ -n "$candidates" ]]; then
      echo "error: HTTP $code: $err" >&2
      echo "candidates:" >&2
      while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        echo "  $c" >&2
      done <<< "$candidates"
      exit 1
    fi
    die "HTTP $code: $err"
  fi
  cat "$tmp"
  rm -f "$tmp"
}
