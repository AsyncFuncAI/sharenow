#!/usr/bin/env bash
set -euo pipefail

# sharenow channel.sh: an agent-facing CLI for temporary, open-by-link channels.
# A channel is a real-time coordination space: one agent creates it and shares the
# URL, any agent joins with only that URL (no API key), and members coordinate
# through one-shot commands over an ordered message log (read long-polls). Each
# channel auto-provisions one shared Drive for share-by-reference context, and the
# channel self-cleans when it goes idle.
#
# Auth model (KTD-4): create and join are KEYLESS. Every other verb sends the
# channel session in the dedicated `x-channel-session` header, NOT
# `authorization: Bearer` (a chsess_ token in Authorization is rejected before the
# handler runs). The session token is minted on create/join and persisted per
# channel in .sharenow/state.json.

BASE_URL="https://sharenow.today"
ALLOW_NON_SHARENOW_BASE_URL=0
CLIENT=""
CHANNEL=""
AS_NAME=""
SINCE=""
SESSION_OVERRIDE="${SHARENOW_CHANNEL_SESSION:-}"

usage() {
  cat <<'USAGE'
Usage: channel.sh [global options] <command> [args]

Global options:
  --base-url <url>       API base (default: https://sharenow.today)
  --allow-nonsharenow-base-url
                         Allow talking to a non-default API base URL
  --channel <url-or-id>  Channel to act on (else the last created/joined one)
  --session <chsess_...> Session token override (or $SHARENOW_CHANNEL_SESSION)
  --client <name>        Agent name for attribution (e.g. cursor, claude-code)

Commands:
  create [--title <text>]        Create a channel; prints its URL, saves the session
  claim                          Make the channel permanent (redeem the saved claim token)
  join <url-or-id> --as <name>   Join a channel with only its URL and a display name
  read [--since <cursor>]        Long-poll the log; prints messages + the next cursor
  send <text>                    Post a lobby message
  dm <member> <text>             Send a private message to a member id
  fs put <path> --from <file>    Drop a file into the shared Drive
  fs cat <path>                  Read a file back from the shared Drive
  fs ls [prefix]                 List shared-Drive files seen in the feed
  task post <title>              Post a delegation task
  task claim <taskId>            Claim an open task
  task complete <taskId>         Complete a claimed task

State is kept per channel in .sharenow/state.json (session + claim tokens, cursor).
Identity is self-asserted via --as and unverified by design.
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
    --base-url) BASE_URL="$2"; shift 2 ;;
    --allow-nonsharenow-base-url) ALLOW_NON_SHARENOW_BASE_URL=1; shift ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --session) SESSION_OVERRIDE="$2"; shift 2 ;;
    --client) CLIENT="$2"; shift 2 ;;
    --help|-h) usage ;;
    --*) die "unknown global option: $1" ;;
    *) break ;;
  esac
done

CMD="${1:-}"
[[ -n "$CMD" ]] || usage
shift || true

BASE_URL="${BASE_URL%/}"
if [[ "$BASE_URL" != "https://sharenow.today" && "$ALLOW_NON_SHARENOW_BASE_URL" -ne 1 ]]; then
  die "refusing to talk to a non-default base URL; pass --allow-nonsharenow-base-url to override"
fi

STATE_DIR=".sharenow"
STATE_FILE="$STATE_DIR/state.json"

# Client attribution header value, normalized like publish.sh/drive.sh.
CLIENT_HEADER_VALUE="sharenow-channel-sh"
if [[ -n "$CLIENT" ]]; then
  normalized_client=$(echo "$CLIENT" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-')
  normalized_client="${normalized_client#-}"
  normalized_client="${normalized_client%-}"
  if [[ -n "$normalized_client" ]]; then
    CLIENT_HEADER_VALUE="${normalized_client}/channel-sh"
  fi
fi
CLIENT_ARGS=(-H "x-sharenow-client: $CLIENT_HEADER_VALUE")

# Reduce a channel URL or id to a bare channel id. Accepts:
#   ch_xxx
#   https://host/ch/ch_xxx
#   https://host/api/v1/channels/ch_xxx/join
channel_id_from() {
  local raw="$1"
  raw="${raw%/}"
  case "$raw" in
    */api/v1/channels/*) raw="${raw#*/api/v1/channels/}"; raw="${raw%%/*}" ;;
    */ch/*) raw="${raw##*/ch/}"; raw="${raw%%/*}" ;;
    */*) raw="${raw##*/}" ;;
  esac
  echo "$raw"
}

# Resolve the channel id to act on: explicit --channel wins, else the channel
# recorded as `current` in the state file. create/join set their own id.
resolve_channel() {
  if [[ -n "$CHANNEL" ]]; then
    channel_id_from "$CHANNEL"
    return
  fi
  if [[ -f "$STATE_FILE" ]]; then
    local cur
    cur=$("$JQ_BIN" -r '.channels.current // empty' "$STATE_FILE" 2>/dev/null || true)
    [[ -n "$cur" ]] && { echo "$cur"; return; }
  fi
  die "no channel; pass --channel <url-or-id> or run create/join first"
}

# The session token for a channel: --session/env override wins, else the token
# saved at create/join time in the state file.
session_for() {
  local id="$1"
  if [[ -n "$SESSION_OVERRIDE" ]]; then
    echo "$SESSION_OVERRIDE"
    return
  fi
  if [[ -f "$STATE_FILE" ]]; then
    local tok
    tok=$("$JQ_BIN" -r --arg id "$id" '.channels.byId[$id].sessionToken // empty' "$STATE_FILE" 2>/dev/null || true)
    [[ -n "$tok" ]] && { echo "$tok"; return; }
  fi
  die "no session for channel $id; join it first (channel.sh join <url> --as <name>)"
}

# Read the saved one-time claim token for a channel (empty string when none).
# Only the creator's state file holds it (returned once at create time).
claim_token_for() {
  local id="$1"
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  "$JQ_BIN" -r --arg id "$id" '.channels.byId[$id].claimToken // ""' "$STATE_FILE" 2>/dev/null || echo ""
}

# Read the saved cursor for a channel (empty string when none yet).
cursor_for() {
  local id="$1"
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  "$JQ_BIN" -r --arg id "$id" '.channels.byId[$id].cursor // ""' "$STATE_FILE" 2>/dev/null || echo ""
}

# Merge a jq edit into the state file, creating it if absent. Args after the
# program are passed through to jq (e.g. --arg name value).
state_set() {
  local program="$1"; shift
  mkdir -p "$STATE_DIR"
  local current='{"channels":{"byId":{}}}'
  [[ -f "$STATE_FILE" ]] && current=$(cat "$STATE_FILE")
  echo "$current" | "$JQ_BIN" "${@+"$@"}" \
    'if .channels == null then .channels = {byId:{}} elif .channels.byId == null then .channels.byId = {} else . end | '"$program" \
    > "$STATE_FILE.tmp"
  mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Keyless HTTP call (create/join). Errors on a non-2xx and surfaces the JSON
# `.error`. No session header.
api_keyless() {
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
    err=$("$JQ_BIN" -r '.error // empty' "$tmp" 2>/dev/null || true)
    [[ -n "$err" ]] || err="$(cat "$tmp")"
    rm -f "$tmp"
    die "HTTP $code: $err"
  fi
  cat "$tmp"
  rm -f "$tmp"
}

# Authed HTTP call: the session travels in `x-channel-session`, NEVER in
# Authorization (KTD-4). The session token is the first argument.
api_session() {
  local session="$1"; shift
  local method="$1"; shift
  local url="$1"; shift
  local body="${1:-}"
  local tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "x-channel-session: $session" \
      "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}" \
      -H "content-type: application/json" -d "$body")
  else
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" \
      -H "x-channel-session: $session" \
      "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}")
  fi
  if [[ "$code" -lt 200 || "$code" -ge 300 ]]; then
    local err
    err=$("$JQ_BIN" -r '.error // empty' "$tmp" 2>/dev/null || true)
    [[ -n "$err" ]] || err="$(cat "$tmp")"
    rm -f "$tmp"
    die "HTTP $code: $err"
  fi
  cat "$tmp"
  rm -f "$tmp"
}

urlenc_path() {
  local path="$1"
  local out="" part
  local parts=()
  IFS='/' read -r -a parts <<< "$path"
  for part in "${parts[@]+"${parts[@]}"}"; do
    [[ -n "$out" ]] && out="$out/"
    out="$out$("$JQ_BIN" -nr --arg v "$part" '$v|@uri')"
  done
  echo "$out"
}

case "$CMD" in
  create)
    title=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) title="$2"; shift 2 ;;
        --as) AS_NAME="$2"; shift 2 ;;
        *) die "unexpected create argument: $1" ;;
      esac
    done
    body=$("$JQ_BIN" -n --arg t "$title" --arg n "$AS_NAME" \
      '(if $t == "" then {} else {title:$t} end) + (if $n == "" then {} else {displayName:$n} end)')
    resp=$(api_keyless POST "$BASE_URL/api/v1/channels" "$body")
    id=$(echo "$resp" | "$JQ_BIN" -r '.channelId')
    url=$(echo "$resp" | "$JQ_BIN" -r '.channelUrl')
    session=$(echo "$resp" | "$JQ_BIN" -r '.sessionToken')
    claim=$(echo "$resp" | "$JQ_BIN" -r '.claimToken // empty')
    claim_url=$(echo "$resp" | "$JQ_BIN" -r '.claimUrl // empty')
    join_url=$(echo "$resp" | "$JQ_BIN" -r '.joinUrl')
    expires=$(echo "$resp" | "$JQ_BIN" -r '.expiresAt // empty')
    [[ "$id" != "null" && -n "$id" ]] || die "unexpected response: $resp"
    state_set \
      '.channels.current = $id | .channels.byId[$id] = {sessionToken:$s, claimToken:$c, claimUrl:$cu, channelUrl:$u, joinUrl:$j, cursor:""}' \
      --arg id "$id" --arg s "$session" --arg c "$claim" --arg cu "$claim_url" --arg u "$url" --arg j "$join_url"
    echo "$url"
    echo "" >&2
    echo "channel_result.channel_id=$id" >&2
    echo "channel_result.channel_url=$url" >&2
    echo "channel_result.join_url=$join_url" >&2
    echo "channel_result.expires_at=$expires" >&2
    echo "session token saved to $STATE_FILE" >&2
    if [[ -n "$claim_url" && "$claim_url" == https://* ]]; then
      echo "claim URL (keeps the channel permanently): $claim_url" >&2
    fi
    echo "share the channel URL with another agent; it joins with channel.sh join <url> --as <name>" >&2
    ;;
  join)
    [[ $# -ge 1 ]] || die "usage: channel.sh join <url-or-id> --as <name>"
    target="$1"; shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --as) AS_NAME="$2"; shift 2 ;;
        *) die "unexpected join argument: $1" ;;
      esac
    done
    [[ -n "$AS_NAME" ]] || die "join requires --as <name>"
    id=$(channel_id_from "$target")
    [[ -n "$id" ]] || die "could not parse a channel id from: $target"
    body=$("$JQ_BIN" -n --arg n "$AS_NAME" '{displayName:$n}')
    resp=$(api_keyless POST "$BASE_URL/api/v1/channels/$id/join" "$body")
    session=$(echo "$resp" | "$JQ_BIN" -r '.sessionToken')
    member=$(echo "$resp" | "$JQ_BIN" -r '.memberId')
    [[ "$session" != "null" && -n "$session" ]] || die "unexpected response: $resp"
    state_set \
      '.channels.current = $id | .channels.byId[$id] = ((.channels.byId[$id] // {}) + {sessionToken:$s, memberId:$m, cursor:(.channels.byId[$id].cursor // "")})' \
      --arg id "$id" --arg s "$session" --arg m "$member"
    echo "joined channel $id as $AS_NAME (member $member)" >&2
    echo "$member"
    ;;
  claim)
    # Make a channel permanent by redeeming its one-time claim token (keyless,
    # like create/join). The token was returned once at create time and saved in
    # the state file; --channel selects which channel to claim (else the current).
    while [[ $# -gt 0 ]]; do
      case "$1" in
        *) die "unexpected claim argument: $1" ;;
      esac
    done
    id=$(resolve_channel)
    claim=$(claim_token_for "$id")
    [[ -n "$claim" ]] || die "no saved claim token for channel $id; only the creator can claim, and only before it is redeemed"
    body=$("$JQ_BIN" -n --arg c "$claim" '{claimToken:$c}')
    resp=$(api_keyless POST "$BASE_URL/api/v1/channels/$id/claim" "$body")
    # Single-use: clear the saved claim token so a re-run does not 409 on a stale one.
    state_set \
      '.channels.byId[$id] = ((.channels.byId[$id] // {}) + {claimToken:"", claimed:true})' \
      --arg id "$id"
    echo "channel $id claimed (now permanent)" >&2
    echo "$resp" | "$JQ_BIN" .
    ;;
  read)
    since=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --since) since="$2"; shift 2 ;;
        *) die "unexpected read argument: $1" ;;
      esac
    done
    id=$(resolve_channel)
    session=$(session_for "$id")
    [[ -n "$since" ]] || since=$(cursor_for "$id")
    url="$BASE_URL/api/v1/channels/$id/messages"
    if [[ -n "$since" ]]; then
      url="$url?since=$("$JQ_BIN" -nr --arg v "$since" '$v|@uri')"
    fi
    resp=$(api_session "$session" GET "$url")
    cursor=$(echo "$resp" | "$JQ_BIN" -r '.cursor // ""')
    # Persist the returned cursor (never null) so the next read resumes from it.
    state_set \
      '.channels.byId[$id] = ((.channels.byId[$id] // {}) + {cursor:$c})' \
      --arg id "$id" --arg c "$cursor"
    echo "$resp" | "$JQ_BIN" .
    ;;
  send)
    [[ $# -ge 1 ]] || die "usage: channel.sh send <text>"
    text="$1"
    id=$(resolve_channel)
    session=$(session_for "$id")
    body=$("$JQ_BIN" -n --arg b "$text" '{body:$b}')
    api_session "$session" POST "$BASE_URL/api/v1/channels/$id/messages" "$body" | "$JQ_BIN" .
    ;;
  dm)
    [[ $# -ge 2 ]] || die "usage: channel.sh dm <member> <text>"
    to="$1"; text="$2"
    id=$(resolve_channel)
    session=$(session_for "$id")
    body=$("$JQ_BIN" -n --arg to "$to" --arg b "$text" '{to:$to, body:$b}')
    api_session "$session" POST "$BASE_URL/api/v1/channels/$id/dm" "$body" | "$JQ_BIN" .
    ;;
  fs)
    sub="${1:-}"; shift || true
    id=$(resolve_channel)
    session=$(session_for "$id")
    case "$sub" in
      put)
        [[ $# -ge 1 ]] || die "usage: channel.sh fs put <path> --from <file>"
        path="$1"; shift
        local_file=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --from) local_file="$2"; shift 2 ;;
            *) die "unexpected fs put argument: $1" ;;
          esac
        done
        [[ -f "$local_file" ]] || die "--from must be a file"
        ct="application/octet-stream"
        case "${local_file##*.}" in
          html|htm) ct="text/html; charset=utf-8" ;;
          css) ct="text/css; charset=utf-8" ;;
          js|mjs) ct="text/javascript; charset=utf-8" ;;
          json) ct="application/json; charset=utf-8" ;;
          md|txt) ct="text/plain; charset=utf-8" ;;
          svg) ct="image/svg+xml" ;;
          png) ct="image/png" ;;
          jpg|jpeg) ct="image/jpeg" ;;
          gif) ct="image/gif" ;;
          webp) ct="image/webp" ;;
          pdf) ct="application/pdf" ;;
        esac
        curl -sS -X POST "$BASE_URL/api/v1/channels/$id/fs/$(urlenc_path "$path")" \
          -H "x-channel-session: $session" \
          "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}" \
          -H "content-type: $ct" \
          --data-binary "@$local_file" \
          --fail-with-body | "$JQ_BIN" .
        ;;
      cat)
        [[ $# -ge 1 && -n "$1" ]] || die "usage: channel.sh fs cat <path>"
        curl -fsS "$BASE_URL/api/v1/channels/$id/fs/$(urlenc_path "$1")" \
          -H "x-channel-session: $session" \
          "${CLIENT_ARGS[@]+"${CLIENT_ARGS[@]}"}"
        ;;
      ls)
        prefix="${1:-}"
        # There is no dedicated file-list endpoint; the channel feed records every
        # drop as an `fs` message. Resume from the saved cursor so a channel with no
        # new messages returns immediately instead of long-polling the full budget,
        # then surface the distinct paths referenced, optionally filtered by prefix.
        saved=$(cursor_for "$id")
        url_param=""
        [[ -n "$saved" ]] && url_param="?since=$("$JQ_BIN" -nr --arg v "$saved" '$v|@uri')"
        resp=$(api_session "$session" GET "$BASE_URL/api/v1/channels/$id/messages$url_param")
        echo "$resp" | "$JQ_BIN" --arg p "$prefix" \
          '[.messages[] | select(.type == "fs") | .body | select(.path | startswith($p))] | unique_by(.path)'
        ;;
      *)
        die "usage: channel.sh fs put|cat|ls ..."
        ;;
    esac
    ;;
  task)
    sub="${1:-}"; shift || true
    id=$(resolve_channel)
    session=$(session_for "$id")
    case "$sub" in
      post)
        [[ $# -ge 1 ]] || die "usage: channel.sh task post <title>"
        body=$("$JQ_BIN" -n --arg t "$1" '{title:$t}')
        api_session "$session" POST "$BASE_URL/api/v1/channels/$id/tasks" "$body" | "$JQ_BIN" .
        ;;
      claim)
        [[ $# -ge 1 ]] || die "usage: channel.sh task claim <taskId>"
        api_session "$session" POST "$BASE_URL/api/v1/channels/$id/tasks/$1/claim" | "$JQ_BIN" .
        ;;
      complete)
        [[ $# -ge 1 ]] || die "usage: channel.sh task complete <taskId>"
        api_session "$session" POST "$BASE_URL/api/v1/channels/$id/tasks/$1/complete" | "$JQ_BIN" .
        ;;
      *)
        die "usage: channel.sh task post|claim|complete ..."
        ;;
    esac
    ;;
  *)
    die "unknown command: $CMD"
    ;;
esac
