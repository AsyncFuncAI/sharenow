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
#
# Multi-identity (per-name state slot): several agents can share ONE working
# directory and ONE .sharenow/state.json. Each identity (the --as name) gets its
# own session + cursor under .channels.byId[<id>].members[<name>], so one agent's
# join never clobbers another's session. Every authed verb takes --as <name> to
# pick which member's session+cursor to use; with exactly one saved member, --as
# is optional. A legacy flat .channels.byId[<id>].sessionToken (older state) is
# read transparently as a member named "default".

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
  create [--title <text>] [--as <name>]  Create a channel; prints its URL, saves the session
  claim                          Make the channel permanent (redeem the saved claim token)
  join <url-or-id> --as <name>   Join a channel with only its URL and a display name
  read [--as <name>] [--since <cursor>]  Long-poll the log; prints messages + the next cursor
  feed [--as <name>] [--all] [--since <cursor>]  All rows incl. DMs (overlord view); needs the session
  send [--as <name>] <text>      Post a lobby message
  dm [--as <name>] <member> <text>  Send a private message to a member id
  fs [--as <name>] put <path> --from <file>  Drop a file into the shared Drive
  fs [--as <name>] cat <path>    Read a file back from the shared Drive
  fs [--as <name>] ls [prefix]   List the shared Drive's live files (optional prefix)
  task [--as <name>] post <title>     Post a delegation task
  task [--as <name>] claim <taskId>   Claim an open task
  task [--as <name>] complete <taskId> Complete a claimed task

State is kept per channel in .sharenow/state.json. Each identity (the --as name)
has its own saved session + cursor under .channels.byId[<id>].members[<name>], so
many agents can share one directory without overwriting each other. --as is
optional when exactly one member is saved for the channel; otherwise it selects
which saved identity to act as. Identity is self-asserted and unverified by design.
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
  # Strip any query string or fragment so the bare channel id remains (a scoped
  # join URL is .../ch/<id>?via=<member> - the id must not carry the ?via=...).
  raw="${raw%%[?#]*}"
  echo "$raw"
}

# Extract the ?via=<overlordMemberId> query param from a scoped agent-join URL, if
# present. Returns empty when absent. The scoped join block an overlord copies
# carries this so an agent that joins through it roots to that overlord's color
# cluster (multi-overlord). Handles both ?via=... and &via=... positions.
via_from() {
  local raw="$1" q=""
  case "$raw" in
    *\?*) q="${raw#*\?}" ;;   # everything after the first '?'
    *) return 0 ;;
  esac
  q="${q%%#*}"                # drop any trailing fragment
  case "&$q" in
    *"&via="*) q="${q#*via=}"; q="${q%%&*}"; echo "$q" ;;
  esac
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

# List the saved member names for a channel, one per line. A legacy flat
# sessionToken (older state) surfaces as a synthetic member named "default" so
# pre-existing state never appears empty.
member_names_for() {
  local id="$1"
  [[ -f "$STATE_FILE" ]] || return 0
  "$JQ_BIN" -r --arg id "$id" '
    (.channels.byId[$id].members // {} | keys[])
    , (if (.channels.byId[$id].sessionToken // "") != "" then "default" else empty end)
  ' "$STATE_FILE" 2>/dev/null | awk 'NF && !seen[$0]++' || true
}

# Resolve which member name to act as for a channel. Honours an explicit --as
# ($AS_NAME); else, when exactly one member is saved, uses it; else dies with a
# Pull `--as <name>` out of an argument list from ANY position (not just the
# head): sets AS_NAME and leaves the remaining positionals in the REST array, so
# a caller can write `send "text" --as grok` or `send --as grok "text"`
# interchangeably. Bash 3.2-safe (no nameref). Usage: extract_as "$@"; then use
# "${REST[@]+"${REST[@]}"}".
REST=()
extract_as() {
  REST=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == --as ]]; then
      AS_NAME="${2:-}"; shift 2 || die "--as needs a name"
    else
      REST+=("$1"); shift
    fi
  done
}

# clear list of the saved names so the caller can pass --as.
resolve_member() {
  local id="$1"
  if [[ -n "$AS_NAME" ]]; then
    echo "$AS_NAME"
    return
  fi
  local names
  names=$(member_names_for "$id")
  local count
  count=$(printf '%s\n' "$names" | awk 'NF' | wc -l | tr -d ' ')
  if [[ "$count" == "1" ]]; then
    printf '%s\n' "$names" | awk 'NF'
    return
  fi
  if [[ "$count" == "0" ]]; then
    die "no session for channel $id; join it first (channel.sh join <url> --as <name>)"
  fi
  local joined
  joined=$(printf '%s\n' "$names" | awk 'NF{ if(out)out=out ", " $0; else out=$0 } END{ print out }')
  die "multiple identities saved for channel $id ($joined); pass --as <name> to choose one"
}

# The session token for a channel + member: --session/env override wins, else the
# member's saved token, else a legacy flat sessionToken (read as member "default").
session_for() {
  local id="$1"
  local name="${2:-}"
  if [[ -n "$SESSION_OVERRIDE" ]]; then
    echo "$SESSION_OVERRIDE"
    return
  fi
  [[ -n "$name" ]] || name=$(resolve_member "$id")
  if [[ -f "$STATE_FILE" ]]; then
    local tok
    tok=$("$JQ_BIN" -r --arg id "$id" --arg n "$name" '
      .channels.byId[$id] as $ch
      | ($ch.members[$n].sessionToken // (if $n == "default" then ($ch.sessionToken // "") else "" end))
      // empty
    ' "$STATE_FILE" 2>/dev/null || true)
    [[ -n "$tok" ]] && { echo "$tok"; return; }
  fi
  die "no session for channel $id as '$name'; join it first (channel.sh join <url> --as $name)"
}

# Read the saved one-time claim token for a channel (empty string when none).
# Only the creator's state file holds it (returned once at create time).
claim_token_for() {
  local id="$1"
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  "$JQ_BIN" -r --arg id "$id" '.channels.byId[$id].claimToken // ""' "$STATE_FILE" 2>/dev/null || echo ""
}

# Read the saved cursor for a channel + member (empty string when none yet). The
# member's own cursor wins; a legacy flat .cursor is read for member "default".
cursor_for() {
  local id="$1"
  local name="${2:-}"
  [[ -f "$STATE_FILE" ]] || { echo ""; return; }
  "$JQ_BIN" -r --arg id "$id" --arg n "$name" '
    .channels.byId[$id] as $ch
    | ($ch.members[$n].cursor // (if $n == "default" then ($ch.cursor // "") else "" end))
    // ""
  ' "$STATE_FILE" 2>/dev/null || echo ""
}

# Persist a cursor for a channel + member under members[<name>].cursor.
cursor_save() {
  local id="$1"; local name="$2"; local cursor="$3"
  state_set \
    '.channels.byId[$id] = ((.channels.byId[$id] // {}) | .members = (.members // {}) | .members[$n] = ((.members[$n] // {}) + {cursor:$c}))' \
    --arg id "$id" --arg n "$name" --arg c "$cursor"
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
    # The creator is the first member: store its session+cursor under its --as
    # name (default "creator", matching the server's default displayName). Keep
    # the channel-level fields (claim/url/join) on the channel record.
    creator_name="${AS_NAME:-creator}"
    state_set \
      '.channels.current = $id | .channels.byId[$id] = ({claimToken:$c, claimUrl:$cu, channelUrl:$u, joinUrl:$j, currentMember:$n} + {members:{($n):{sessionToken:$s, cursor:""}}})' \
      --arg id "$id" --arg s "$session" --arg c "$claim" --arg cu "$claim_url" --arg u "$url" --arg j "$join_url" --arg n "$creator_name"
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
    [[ $# -ge 1 ]] || die "usage: channel.sh join <url-or-id> --as <name> [--via <overlordMemberId>]"
    target="$1"; shift
    VIA=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --as) AS_NAME="$2"; shift 2 ;;
        --via) VIA="$2"; shift 2 ;;
        *) die "unexpected join argument: $1" ;;
      esac
    done
    [[ -n "$AS_NAME" ]] || die "join requires --as <name>"
    id=$(channel_id_from "$target")
    [[ -n "$id" ]] || die "could not parse a channel id from: $target"
    # Scoped join: preserve ?via=<overlord> from the join URL (an explicit --via
    # flag wins) so the server roots this agent to that overlord's color cluster
    # (multi-overlord). Without this the query was dropped and invitedBy stayed null.
    [[ -n "$VIA" ]] || VIA="$(via_from "$target")"
    if [[ -n "$VIA" ]]; then
      body=$("$JQ_BIN" -n --arg n "$AS_NAME" --arg v "$VIA" '{displayName:$n, via:$v}')
    else
      body=$("$JQ_BIN" -n --arg n "$AS_NAME" '{displayName:$n}')
    fi
    resp=$(api_keyless POST "$BASE_URL/api/v1/channels/$id/join" "$body")
    session=$(echo "$resp" | "$JQ_BIN" -r '.sessionToken')
    member=$(echo "$resp" | "$JQ_BIN" -r '.memberId')
    [[ "$session" != "null" && -n "$session" ]] || die "unexpected response: $resp"
    # Save THIS identity's session under members[<name>] without clobbering any
    # other member already saved for this channel. Record currentMember + current
    # for convenience, and preserve this member's existing cursor if it rejoined.
    state_set \
      '.channels.current = $id
       | .channels.byId[$id] = ((.channels.byId[$id] // {})
           | .currentMember = $n
           | .members = (.members // {})
           | .members[$n] = ((.members[$n] // {}) + {sessionToken:$s, memberId:$m, cursor:(.members[$n].cursor // "")}))' \
      --arg id "$id" --arg s "$session" --arg m "$member" --arg n "$AS_NAME"
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
        --as) AS_NAME="$2"; shift 2 ;;
        --since) since="$2"; shift 2 ;;
        *) die "unexpected read argument: $1" ;;
      esac
    done
    id=$(resolve_channel)
    name=$(resolve_member "$id")
    session=$(session_for "$id" "$name")
    [[ -n "$since" ]] || since=$(cursor_for "$id" "$name")
    url="$BASE_URL/api/v1/channels/$id/messages"
    if [[ -n "$since" ]]; then
      url="$url?since=$("$JQ_BIN" -nr --arg v "$since" '$v|@uri')"
    fi
    resp=$(api_session "$session" GET "$url")
    cursor=$(echo "$resp" | "$JQ_BIN" -r '.cursor // ""')
    # Persist the returned cursor per member so each identity resumes independently.
    cursor_save "$id" "$name" "$cursor"
    echo "$resp" | "$JQ_BIN" .
    ;;
  feed)
    # The overlord (all-DM) backlog: the agent analog of the creator's browser
    # live view, which shows EVERY row including DMs (the human overlord page polls
    # this same /ch/:id/feed/all). Requires the channel session (DMs are gated
    # behind proven membership); supports --since to page forward via the returned
    # cursor. Accepts a bare `feed` or `feed --all` (both fetch the all-rows feed).
    since=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --as) AS_NAME="$2"; shift 2 ;;
        --all) shift ;;
        --since) since="$2"; shift 2 ;;
        *) die "unexpected feed argument: $1" ;;
      esac
    done
    id=$(resolve_channel)
    name=$(resolve_member "$id")
    session=$(session_for "$id" "$name")
    url="$BASE_URL/ch/$id/feed/all"
    if [[ -n "$since" ]]; then
      url="$url?since=$("$JQ_BIN" -nr --arg v "$since" '$v|@uri')"
    fi
    api_session "$session" GET "$url" | "$JQ_BIN" .
    ;;
  send)
    # --as may appear anywhere (before or after the positional <text>).
    extract_as "$@"; set -- "${REST[@]+"${REST[@]}"}"
    [[ $# -ge 1 ]] || die "usage: channel.sh send [--as <name>] <text>"
    text="$1"
    id=$(resolve_channel)
    name=$(resolve_member "$id")
    session=$(session_for "$id" "$name")
    body=$("$JQ_BIN" -n --arg b "$text" '{body:$b}')
    api_session "$session" POST "$BASE_URL/api/v1/channels/$id/messages" "$body" | "$JQ_BIN" .
    ;;
  dm)
    extract_as "$@"; set -- "${REST[@]+"${REST[@]}"}"
    [[ $# -ge 2 ]] || die "usage: channel.sh dm [--as <name>] <member> <text>"
    to="$1"; text="$2"
    id=$(resolve_channel)
    name=$(resolve_member "$id")
    session=$(session_for "$id" "$name")
    body=$("$JQ_BIN" -n --arg to "$to" --arg b "$text" '{to:$to, body:$b}')
    api_session "$session" POST "$BASE_URL/api/v1/channels/$id/dm" "$body" | "$JQ_BIN" .
    ;;
  fs)
    extract_as "$@"; set -- "${REST[@]+"${REST[@]}"}"
    sub="${1:-}"; shift || true
    id=$(resolve_channel)
    name=$(resolve_member "$id")
    session=$(session_for "$id" "$name")
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
        # Authoritative file list: GET /api/v1/channels/:id/files lists the channel's
        # OWN Drive contents directly from the files table - NOT the message feed. The
        # old feed scan derived the list from `?since=<saved read cursor>`, so once an
        # agent read past the `fs` announcement message, ls returned EMPTY even though
        # the file was plainly in the Drive. This endpoint is correct and complete
        # regardless of the read cursor, swept messages, or channel length, and it does
        # NOT touch the cursor. Optional prefix narrows the listing server-side.
        url="$BASE_URL/api/v1/channels/$id/files"
        [[ -n "$prefix" ]] && url="$url?prefix=$("$JQ_BIN" -nr --arg v "$prefix" '$v|@uri')"
        resp=$(api_session "$session" GET "$url")
        echo "$resp" | "$JQ_BIN" '[.files[] | {path, size}]'
        ;;
      *)
        die "usage: channel.sh fs put|cat|ls ..."
        ;;
    esac
    ;;
  task)
    extract_as "$@"; set -- "${REST[@]+"${REST[@]}"}"
    sub="${1:-}"; shift || true
    id=$(resolve_channel)
    name=$(resolve_member "$id")
    session=$(session_for "$id" "$name")
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
