# Shared HTTP response handling retained for parked advanced helpers.

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
