#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://sharenow.today"
CREDENTIALS_FILE="$HOME/.sharenow/credentials"
STATE_FILE="${SHARENOW_STATE_DIR:-$HOME/.sharenow}/channels.json"
API_KEY="${SHARENOW_API_KEY:-}"

usage() {
  local code="${1:-1}"
  cat <<'USAGE'
Usage: channel.sh <command> [args]

Commands:
  list
  create --title <text> [--as <name>] [--dry-run]
  join <channel-url-or-id> --as <name> [--dry-run]
  invite <channel-url-or-id> [--overlord] [--dry-run]
  read <channel-url-or-id> [--since <cursor>]
  send <channel-url-or-id> --text <text> [--dry-run]
  task post <channel-url-or-id> --title <text> [--dry-run]
  task claim <channel-url-or-id> <task-id> [--dry-run]
  task complete <channel-url-or-id> <task-id> [--dry-run]

Account credentials come from $SHARENOW_API_KEY or ~/.sharenow/credentials.
Channel sessions are saved privately and are never accepted as arguments.
USAGE
  exit "$code"
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
  die "requires jq. Install it with 'brew install jq' (macOS) or 'sudo apt-get install jq' (Debian/Ubuntu), then retry"
fi
command -v curl >/dev/null 2>&1 || die "requires curl"
. "$SCRIPT_DIR/lib/http.sh"

valid_account_key() {
  local value="$1"
  [[ "$value" == snk_????????????????????* ]] || return 1
  [[ "$value" != *[!A-Za-z0-9_-]* ]]
}

load_account_key() {
  if [[ -z "$API_KEY" && -f "$CREDENTIALS_FILE" ]]; then
    API_KEY=$(tr -d '[:space:]' < "$CREDENTIALS_FILE")
  fi
  [[ -n "$API_KEY" ]] || die "not connected. Run ./scripts/account.sh login --client <agent-name>, then retry"
  valid_account_key "$API_KEY" || die "invalid account credential format"
}

api_account() {
  local method="$1" url="$2" body="${3:-}" tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(printf 'header = "authorization: Bearer %s"\n' "$API_KEY" | curl --config - -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "content-type: application/json" -d "$body")
  else
    code=$(printf 'header = "authorization: Bearer %s"\n' "$API_KEY" | curl --config - -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url")
  fi
  http_handle_response "$code" "$tmp"
}

api_keyless() {
  local method="$1" url="$2" body="${3:-}" tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "content-type: application/json" -d "$body")
  else
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url")
  fi
  http_handle_response "$code" "$tmp"
}

api_session() {
  local session="$1" method="$2" url="$3" body="${4:-}" tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "x-channel-session: $session" -H "content-type: application/json" -d "$body")
  else
    code=$(curl -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "x-channel-session: $session")
  fi
  http_handle_response "$code" "$tmp"
}

channel_id() {
  local raw="${1%/}"
  raw="${raw%%#*}"
  raw="${raw%%\?*}"
  case "$raw" in
    */ch/*) raw="${raw##*/ch/}" ;;
    */api/v1/channels/*) raw="${raw#*/api/v1/channels/}"; raw="${raw%%/*}" ;;
  esac
  [[ "$raw" == ch_* && "$raw" != *[!A-Za-z0-9_-]* ]] || die "invalid Channel URL or id"
  printf '%s\n' "$raw"
}

via_member() {
  local raw="$1" query
  case "$raw" in
    *\?*) query="${raw#*\?}"; query="${query%%#*}" ;;
    *) return 0 ;;
  esac
  case "&$query" in
    *"&via="*) query="${query#*via=}"; printf '%s\n' "${query%%&*}" ;;
  esac
}

state_write() {
  local filter="$1"; shift
  local dir current tmp
  dir=$(dirname "$STATE_FILE")
  mkdir -p "$dir"
  umask 077
  current='{"current":null,"channels":{}}'
  [[ -f "$STATE_FILE" ]] && current=$(cat "$STATE_FILE")
  tmp=$(mktemp "$dir/.channels.XXXXXX") || die "could not create Channel state"
  if printf '%s' "$current" | "$JQ_BIN" "$@" "$filter" > "$tmp"; then
    chmod 600 "$tmp"
    mv "$tmp" "$STATE_FILE"
  else
    rm -f "$tmp"
    die "could not update Channel state"
  fi
}

save_session() {
  local id="$1" name="$2" token="$3" member="$4" channel_url="$5" join_url="$6"
  state_write '.current=$id | .channels[$id]=((.channels[$id] // {}) + {channelUrl:$channelUrl,joinUrl:$joinUrl} | .members=((.members // {}) + {($name):{sessionToken:$token,memberId:$member}}))' \
    --arg id "$id" --arg name "$name" --arg token "$token" --arg member "$member" --arg channelUrl "$channel_url" --arg joinUrl "$join_url"
}

saved_field() {
  local id="$1" field="$2"
  [[ -f "$STATE_FILE" ]] || die "no saved Channel session; create or join the Channel first"
  "$JQ_BIN" -r --arg id "$id" --arg field "$field" '
    .channels[$id] as $c
    | if $field == "session" then ($c.members | to_entries | if length == 1 then .[0].value.sessionToken else empty end)
      elif $field == "member" then ($c.members | to_entries | if length == 1 then .[0].value.memberId else empty end)
      elif $field == "join" then $c.joinUrl
      elif $field == "url" then $c.channelUrl
      else empty end // empty
  ' "$STATE_FILE"
}

session_for() {
  local value
  value=$(saved_field "$1" session)
  [[ "$value" == chsess_* ]] || die "Channel has zero or multiple saved identities; join from a separate agent environment or remove the stale identity"
  printf '%s\n' "$value"
}

dry_receipt() {
  "$JQ_BIN" -n --arg action "$1" --arg detail "$2" '{dryRun:true,action:$action,detail:$detail}'
}

CMD="${1:-}"
case "$CMD" in
  --help|-h) usage 0 ;;
  "") usage ;;
esac
shift

case "$CMD" in
  list)
    [[ $# -eq 0 ]] || die "usage: channel.sh list"
    load_account_key
    api_account GET "$BASE_URL/api/v1/channels" | "$JQ_BIN" .
    ;;
  create)
    title=""; name=""; dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --title) [[ $# -ge 2 ]] || die "--title requires text"; title="$2"; shift 2 ;;
        --as) [[ $# -ge 2 ]] || die "--as requires a name"; name="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) die "unexpected create argument: $1" ;;
      esac
    done
    [[ -n "${title// }" ]] || die "--title is required"
    if [[ "$dry" -eq 1 ]]; then
      dry_receipt "create" "Create and immediately claim a Channel titled '$title'; save the owner session privately; return the private overlord URL, agent join URL, and hard expiry."
      exit 0
    fi
    load_account_key
    create_body=$($JQ_BIN -n --arg title "$title" --arg displayName "$name" '{title:$title} + (if $displayName == "" then {} else {displayName:$displayName} end)')
    created=$(api_account POST "$BASE_URL/api/v1/channels" "$create_body")
    id=$(printf '%s' "$created" | "$JQ_BIN" -r '.channelId // empty')
    token=$(printf '%s' "$created" | "$JQ_BIN" -r '.sessionToken // empty')
    claim_token=$(printf '%s' "$created" | "$JQ_BIN" -r '.claimToken // empty')
    member=$(printf '%s' "$created" | "$JQ_BIN" -r '.memberId // empty')
    channel_url=$(printf '%s' "$created" | "$JQ_BIN" -r '.channelUrl // empty')
    overlord_url=$(printf '%s' "$created" | "$JQ_BIN" -r '.overlordUrl // empty')
    join_url=$(printf '%s' "$created" | "$JQ_BIN" -r '.joinUrl // empty')
    [[ "$id" == ch_* && "$token" == chsess_* && "$claim_token" == clm_* && -n "$member" && -n "$channel_url" && -n "$join_url" ]] || die "invalid Channel create response"
    [[ "$overlord_url" == "$BASE_URL/ch/$id#session=$token" ]] || die "invalid private overlord URL in Channel create response"
    claimed=$(api_account POST "$BASE_URL/api/v1/channels/$id/claim" "$($JQ_BIN -n --arg claimToken "$claim_token" '{claimToken:$claimToken}')")
    expires_at=$(printf '%s' "$claimed" | "$JQ_BIN" -r '.expiresAt // empty')
    [[ -n "$expires_at" ]] || die "Channel claim response did not include the hard expiry"
    owner_name="${name:-overlord}"
    save_session "$id" "$owner_name" "$token" "$member" "$channel_url" "$join_url"
    unset token claim_token created claimed create_body
    "$JQ_BIN" -n --arg channelId "$id" --arg overlordUrl "$overlord_url" --arg joinUrl "$join_url" --arg expiresAt "$expires_at" \
      '{channelId:$channelId,state:"claimed",overlordUrl:$overlordUrl,agentJoinUrl:$joinUrl,expiresAt:$expiresAt}'
    ;;
  join)
    [[ $# -ge 1 ]] || die "usage: channel.sh join <channel-url-or-id> --as <name> [--dry-run]"
    raw="$1"; shift; name=""; dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --as) [[ $# -ge 2 ]] || die "--as requires a name"; name="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) die "unexpected join argument: $1" ;;
      esac
    done
    [[ -n "${name// }" ]] || die "--as is required"
    id=$(channel_id "$raw"); via=$(via_member "$raw" || true)
    if [[ "$dry" -eq 1 ]]; then dry_receipt "join" "Join Channel $id as '$name' and save the returned session privately."; exit 0; fi
    body=$($JQ_BIN -n --arg displayName "$name" --arg via "$via" '{displayName:$displayName} + (if $via == "" then {} else {via:$via} end)')
    joined=$(api_keyless POST "$BASE_URL/api/v1/channels/$id/join" "$body")
    token=$(printf '%s' "$joined" | "$JQ_BIN" -r '.sessionToken // empty')
    member=$(printf '%s' "$joined" | "$JQ_BIN" -r '.memberId // empty')
    [[ "$token" == chsess_* && -n "$member" ]] || die "invalid Channel join response"
    channel_url="$BASE_URL/ch/$id"; join_url="$channel_url"
    save_session "$id" "$name" "$token" "$member" "$channel_url" "$join_url"
    unset token joined
    "$JQ_BIN" -n --arg channelId "$id" --arg channelUrl "$channel_url" '{channelId:$channelId,state:"joined",channelUrl:$channelUrl}'
    ;;
  invite)
    [[ $# -ge 1 ]] || die "usage: channel.sh invite <channel-url-or-id> [--overlord] [--dry-run]"
    id=$(channel_id "$1"); shift; overlord=0; dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in --overlord) overlord=1; shift ;; --dry-run) dry=1; shift ;; *) die "unexpected invite argument: $1" ;; esac
    done
    if [[ "$dry" -eq 1 ]]; then dry_receipt "invite" "Create a scoped $([[ "$overlord" -eq 1 ]] && echo co-overlord || echo agent) invite for Channel $id."; exit 0; fi
    member=$(saved_field "$id" member); channel_url=$(saved_field "$id" url); join_url=$(saved_field "$id" join)
    [[ -n "$member" && -n "$channel_url" ]] || die "no saved creator identity for Channel $id"
    if [[ "$overlord" -eq 0 ]]; then
      printf '%s?via=%s\n' "${join_url:-$channel_url}" "$member"
      exit 0
    fi
    session=$(session_for "$id")
    minted=$(api_session "$session" POST "$BASE_URL/api/v1/channels/$id/overlords/invite" '{}')
    invite=$(printf '%s' "$minted" | "$JQ_BIN" -r '.inviteToken // empty')
    [[ "$invite" == covr_* ]] || die "invalid co-overlord invite response"
    printf '%s#invite=%s\n' "$channel_url" "$invite"
    ;;
  read)
    [[ $# -ge 1 ]] || die "usage: channel.sh read <channel-url-or-id> [--since <cursor>]"
    id=$(channel_id "$1"); shift; since=""
    while [[ $# -gt 0 ]]; do case "$1" in --since) since="$2"; shift 2 ;; *) die "unexpected read argument: $1" ;; esac; done
    session=$(session_for "$id"); url="$BASE_URL/api/v1/channels/$id/messages"
    [[ -z "$since" ]] || url="$url?since=$($JQ_BIN -nr --arg v "$since" '$v|@uri')"
    api_session "$session" GET "$url" | "$JQ_BIN" .
    ;;
  send)
    [[ $# -ge 1 ]] || die "usage: channel.sh send <channel-url-or-id> --text <text> [--dry-run]"
    id=$(channel_id "$1"); shift; message=""; dry=0
    while [[ $# -gt 0 ]]; do case "$1" in --text) message="$2"; shift 2 ;; --dry-run) dry=1; shift ;; *) die "unexpected send argument: $1" ;; esac; done
    [[ -n "${message// }" ]] || die "--text is required"
    if [[ "$dry" -eq 1 ]]; then dry_receipt "send" "Post one lobby message to Channel $id."; exit 0; fi
    session=$(session_for "$id")
    api_session "$session" POST "$BASE_URL/api/v1/channels/$id/messages" "$($JQ_BIN -n --arg body "$message" '{body:$body}')" | "$JQ_BIN" .
    ;;
  task)
    action="${1:-}"; shift || true
    case "$action" in
      post)
        [[ $# -ge 1 ]] || die "usage: channel.sh task post <channel> --title <text> [--dry-run]"
        id=$(channel_id "$1"); shift; title=""; dry=0
        while [[ $# -gt 0 ]]; do case "$1" in --title) title="$2"; shift 2 ;; --dry-run) dry=1; shift ;; *) die "unexpected task argument: $1" ;; esac; done
        [[ -n "${title// }" ]] || die "--title is required"
        path="tasks"; body="$($JQ_BIN -n --arg title "$title" '{title:$title}')" ;;
      claim|complete)
        [[ $# -ge 2 ]] || die "usage: channel.sh task $action <channel> <task-id> [--dry-run]"
        id=$(channel_id "$1"); task_id="$2"; shift 2; dry=0
        while [[ $# -gt 0 ]]; do case "$1" in --dry-run) dry=1; shift ;; *) die "unexpected task argument: $1" ;; esac; done
        [[ "$task_id" != *[!A-Za-z0-9_-]* ]] || die "invalid task id"
        path="tasks/$task_id/$action"; body='{}' ;;
      *) die "usage: channel.sh task post|claim|complete ..." ;;
    esac
    if [[ "$dry" -eq 1 ]]; then dry_receipt "task_$action" "Apply task action '$action' in Channel $id."; exit 0; fi
    session=$(session_for "$id")
    api_session "$session" POST "$BASE_URL/api/v1/channels/$id/$path" "$body" | "$JQ_BIN" .
    ;;
  *) die "unknown command: $CMD" ;;
esac
