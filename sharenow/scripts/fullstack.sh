#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://sharenow.today"
CREDENTIALS_FILE="$HOME/.sharenow/credentials"
STATE_DIR="${SHARENOW_STATE_DIR:-$HOME/.sharenow}/fullstack"
PLANS_DIR="$STATE_DIR/plans"
API_KEY="${SHARENOW_API_KEY:-}"

usage() {
  local code="${1:-1}"
  cat <<'USAGE'
Usage: fullstack.sh <command> [args]

Commands:
  list
  plan --contract <yaml-file> --drive <drive-id> --manifest <json-file>
  approve <plan-id>
  deploy <plan-id> [--secrets-from <mode-600-json-file>] [--dry-run]
  status <app-id>
  delete <app-id> --confirm <app-id> [--dry-run]

Planning is local and makes no network request. A plan is bound to the exact
contract and manifest bytes. Deploy requires a separate approve command and
revalidates both files. Secret values are accepted only from a mode-600 JSON
file, never from command-line values, and are never printed.
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
command -v shasum >/dev/null 2>&1 || die "requires shasum"
. "$SCRIPT_DIR/lib/http.sh"

valid_account_key() { [[ "$1" == snk_????????????????????* && "$1" != *[!A-Za-z0-9_-]* ]]; }
load_account_key() {
  if [[ -z "$API_KEY" && -f "$CREDENTIALS_FILE" ]]; then API_KEY=$(tr -d '[:space:]' < "$CREDENTIALS_FILE"); fi
  [[ -n "$API_KEY" ]] || die "not connected. Run ./scripts/account.sh login --client <agent-name>, then retry"
  valid_account_key "$API_KEY" || die "invalid account credential format"
}

api_account() {
  local method="$1" url="$2" body="${3:-}" idempotency="${4:-}" tmp code
  tmp=$(mktemp)
  if [[ -n "$body" ]]; then
    if [[ -n "$idempotency" ]]; then
      code=$(printf '%s' "$body" | curl --config <(printf 'header = "authorization: Bearer %s"\n' "$API_KEY") -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "content-type: application/json" -H "idempotency-key: $idempotency" --data-binary @-)
    else
      code=$(printf '%s' "$body" | curl --config <(printf 'header = "authorization: Bearer %s"\n' "$API_KEY") -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url" -H "content-type: application/json" --data-binary @-)
    fi
  else
    code=$(printf 'header = "authorization: Bearer %s"\n' "$API_KEY" | curl --config - -sS -o "$tmp" -w "%{http_code}" -X "$method" "$url")
  fi
  http_handle_response "$code" "$tmp"
}

absolute_file() {
  local input="$1" dir base
  [[ -f "$input" ]] || die "file not found: $input"
  dir=$(cd "$(dirname "$input")" && pwd)
  base=$(basename "$input")
  printf '%s/%s\n' "$dir" "$base"
}

file_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
text_sha() { shasum -a 256 | awk '{print $1}'; }
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
valid_plan_id() { [[ "$1" == fsp_* && "$1" != *[!A-Za-z0-9_-]* ]] || die "invalid Fullstack plan id"; }
valid_app_id() { [[ "$1" == fsa_* && "$1" != *[!A-Za-z0-9_-]* ]] || die "invalid Fullstack app id"; }

valid_branded_url() {
  local value="$1" host label
  case "$value" in
    https://*.sharenow.today|https://*.sharenow.today/) ;;
    *) return 1 ;;
  esac
  host="${value#https://}"; host="${host%/}"
  [[ "$host" != */* && "$host" != *@* && "$host" != *:* ]] || return 1
  label="${host%.sharenow.today}"
  [[ -n "$label" && "$label" != "$host" && "$label" != *.* ]] || return 1
  [[ "$label" != *[!a-z0-9-]* && "$label" != -* && "$label" != *- ]] || return 1
}

wait_for_branded_url() {
  local url="$1" attempt=0 code delay
  valid_branded_url "$url" || die "invalid Fullstack live URL"
  while [[ "$attempt" -lt 6 ]]; do
    code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "$url" || true)
    case "$code" in
      [12345][0-9][0-9]) [[ "$code" != 404 ]] && return 0 ;;
    esac
    attempt=$((attempt + 1))
    [[ "$attempt" -lt 6 ]] || break
    if [[ "$attempt" -le 2 ]]; then delay=1
    elif [[ "$attempt" -le 4 ]]; then delay=2
    else delay=3; fi
    sleep "$delay"
  done
  return 1
}

receipt_path() {
  valid_plan_id "$1"
  printf '%s/%s.json\n' "$PLANS_DIR" "$1"
}

write_receipt() {
  local path="$1" json="$2" dir tmp
  dir=$(dirname "$path"); mkdir -p "$dir"; umask 077
  tmp=$(mktemp "$dir/.receipt.XXXXXX") || die "could not create Fullstack receipt"
  if printf '%s' "$json" | "$JQ_BIN" -e . > "$tmp"; then
    chmod 600 "$tmp"; mv "$tmp" "$path"
  else
    rm -f "$tmp"; die "could not write Fullstack receipt"
  fi
}

read_receipt() {
  local path
  path=$(receipt_path "$1")
  [[ -f "$path" ]] || die "Fullstack plan not found: $1"
  "$JQ_BIN" -e . "$path" || die "invalid Fullstack receipt"
}

normalize_manifest() {
  "$JQ_BIN" -ce '
    if type != "array" then error("manifest must be an array") else . end
    | if all(.[]; type == "object"
        and (.path | type == "string" and length > 0 and startswith("/") | not)
        and (.path | contains("..") | not)
        and (.sha256 | type == "string" and test("^[a-fA-F0-9]{64}$"))
        and (.size | type == "number" and . >= 0 and floor == .))
      then . else error("invalid manifest entry") end
    | sort_by(.path)
    | if ([.[].path] | unique | length) == length then . else error("duplicate manifest path") end
  ' "$1" 2>/dev/null || die "manifest must contain unique {path, sha256, size} entries"
}

declared_env() {
  awk '
    /^env:[[:space:]]*$/ { in_env=1; next }
    in_env && /^[^[:space:]]/ { in_env=0 }
    in_env && /^[[:space:]]*-[[:space:]]*[A-Z_][A-Z0-9_]*[[:space:]]*$/ {
      value=$0
      sub(/^[[:space:]]*-[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
    }
  ' "$1" | "$JQ_BIN" -Rsc 'split("\n") | map(select(length > 0)) | unique | sort'
}

verify_receipt_content() {
  local receipt="$1" contract manifest contract_sha manifest_sha normalized
  contract=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
  manifest=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.manifestPath')
  [[ -f "$contract" && -f "$manifest" ]] || die "planned contract or manifest no longer exists; create a new plan"
  contract_sha=$(file_sha "$contract")
  normalized=$(normalize_manifest "$manifest")
  manifest_sha=$(printf '%s' "$normalized" | text_sha)
  [[ "$contract_sha" == "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractSha256')" ]] || die "contract changed after approval; create and approve a new plan"
  [[ "$manifest_sha" == "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.manifestSha256')" ]] || die "manifest changed after approval; create and approve a new plan"
}

make_idempotency_key() {
  if command -v openssl >/dev/null 2>&1; then openssl rand -hex 24
  elif command -v node >/dev/null 2>&1; then node -e 'process.stdout.write(require("crypto").randomBytes(24).toString("hex"))'
  else die "deploy requires openssl or node for a high-entropy idempotency key"; fi
}

CMD="${1:-}"
case "$CMD" in --help|-h) usage 0 ;; "") usage ;; esac
shift

case "$CMD" in
  list)
    [[ $# -eq 0 ]] || die "usage: fullstack.sh list"
    load_account_key; api_account GET "$BASE_URL/api/v1/fullstack" | "$JQ_BIN" .
    ;;
  plan)
    contract=""; drive=""; manifest=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --contract) [[ $# -ge 2 ]] || die "--contract requires a file"; contract="$2"; shift 2 ;;
        --drive) [[ $# -ge 2 ]] || die "--drive requires an id"; drive="$2"; shift 2 ;;
        --manifest) [[ $# -ge 2 ]] || die "--manifest requires a file"; manifest="$2"; shift 2 ;;
        *) die "unexpected plan argument: $1" ;;
      esac
    done
    [[ -n "$contract" && -n "$drive" && -n "$manifest" ]] || die "plan requires --contract, --drive, and --manifest"
    [[ "$drive" == drv_* && "$drive" != *[!A-Za-z0-9_-]* ]] || die "invalid Drive id"
    contract=$(absolute_file "$contract"); manifest=$(absolute_file "$manifest")
    [[ "$(wc -c < "$contract" | tr -d '[:space:]')" -le 65536 ]] || die "contract exceeds 64 KiB"
    normalized=$(normalize_manifest "$manifest")
    contract_sha=$(file_sha "$contract"); manifest_sha=$(printf '%s' "$normalized" | text_sha)
    plan_hash=$(printf '%s\n%s\n%s\n' "$drive" "$contract_sha" "$manifest_sha" | text_sha)
    plan_id="fsp_${plan_hash:0:24}"
    env_names=$(declared_env "$contract")
    receipt=$($JQ_BIN -n --arg planId "$plan_id" --arg driveId "$drive" \
      --arg contractPath "$contract" --arg manifestPath "$manifest" \
      --arg contractSha256 "$contract_sha" --arg manifestSha256 "$manifest_sha" \
      --argjson manifest "$normalized" --argjson declaredEnv "$env_names" \
      '{planId:$planId,driveId:$driveId,contractPath:$contractPath,manifestPath:$manifestPath,contractSha256:$contractSha256,manifestSha256:$manifestSha256,manifest:$manifest,declaredEnv:$declaredEnv,approved:false,approvedAt:null}')
    write_receipt "$(receipt_path "$plan_id")" "$receipt"
    "$JQ_BIN" -n --arg planId "$plan_id" --arg driveId "$drive" --argjson files "$(printf '%s' "$normalized" | $JQ_BIN 'length')" --argjson declaredEnv "$env_names" \
      '{planId:$planId,state:"planned",driveId:$driveId,fileCount:$files,requiredSecrets:$declaredEnv,next:"Review the plan, then run fullstack.sh approve <plan-id>."}'
    ;;
  approve)
    [[ $# -eq 1 ]] || die "usage: fullstack.sh approve <plan-id>"
    plan_id="$1"; receipt=$(read_receipt "$plan_id"); verify_receipt_content "$receipt"
    approved=$($JQ_BIN -n --argjson receipt "$receipt" --arg approvedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '$receipt + {approved:true,approvedAt:$approvedAt}')
    write_receipt "$(receipt_path "$plan_id")" "$approved"
    "$JQ_BIN" -n --arg planId "$plan_id" '{planId:$planId,approved:true,next:"Deploy this exact plan with fullstack.sh deploy <plan-id>."}'
    ;;
  deploy)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh deploy <plan-id> [--secrets-from <mode-600-json-file>] [--dry-run]"
    plan_id="$1"; shift; secrets_file=""; dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --secrets-from) [[ $# -ge 2 ]] || die "--secrets-from requires a file"; secrets_file="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) die "unexpected deploy argument: $1" ;;
      esac
    done
    receipt=$(read_receipt "$plan_id")
    [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.approved')" == true ]] || die "Fullstack plan is not approved; review it and run fullstack.sh approve $plan_id"
    verify_receipt_content "$receipt"
    env_json='{}'
    if [[ -n "$secrets_file" ]]; then
      secrets_file=$(absolute_file "$secrets_file")
      [[ "$(file_mode "$secrets_file")" == 600 ]] || die "secret file must have mode 600"
      env_json=$($JQ_BIN -ce 'if type == "object" and all(to_entries[]; (.key|test("^[A-Z_][A-Z0-9_]*$")) and (.value|type=="string")) then . else error("invalid secret map") end' "$secrets_file" 2>/dev/null) || die "secret file must be a JSON object of string values"
      declared=$(printf '%s' "$receipt" | "$JQ_BIN" -c '.declaredEnv')
      provided=$(printf '%s' "$env_json" | "$JQ_BIN" -c 'keys | sort')
      [[ "$provided" == "$declared" ]] || die "secret file keys must exactly match the contract env list"
    else
      [[ "$(printf '%s' "$receipt" | "$JQ_BIN" '.declaredEnv | length')" -eq 0 ]] || die "this contract requires --secrets-from with a mode-600 JSON file"
    fi
    if [[ "$dry" -eq 1 ]]; then
      "$JQ_BIN" -n --arg planId "$plan_id" '{dryRun:true,planId:$planId,approved:true,validated:true,networkRequests:0}'
      exit 0
    fi
    load_account_key
    contract_path=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
    yaml=$(cat "$contract_path")
    body=$($JQ_BIN -n --arg yaml "$yaml" --arg driveId "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')" --argjson manifest "$(printf '%s' "$receipt" | "$JQ_BIN" -c '.manifest')" --argjson env "$env_json" '{yaml:$yaml,driveId:$driveId,manifest:$manifest,env:$env}')
    idem=$(make_idempotency_key)
    created=$(api_account POST "$BASE_URL/api/v1/fullstack" "$body" "$idem")
    unset body env_json yaml
    app_id=$(printf '%s' "$created" | "$JQ_BIN" -r '.appId // empty')
    claim_token=$(printf '%s' "$created" | "$JQ_BIN" -r '.claimToken // empty')
    valid_app_id "$app_id"; [[ "$claim_token" == clm_* ]] || die "invalid Fullstack create response"
    state="provisioning"; waited=0; status='{}'
    while [[ "$state" == provisioning && "$waited" -lt 180 ]]; do
      sleep 2; waited=$((waited + 2)); status=$(api_account GET "$BASE_URL/api/v1/fullstack/$app_id/status"); state=$(printf '%s' "$status" | "$JQ_BIN" -r '.state // empty')
    done
    [[ "$state" == live || "$state" == failed ]] || die "Fullstack app did not reach a claimable state (state: ${state:-unknown})"
    url=$(printf '%s' "$status" | "$JQ_BIN" -r '.url // empty')
    [[ -z "$url" ]] || valid_branded_url "$url" || die "invalid Fullstack live URL"
    api_account POST "$BASE_URL/api/v1/fullstack/$app_id/claim" "$($JQ_BIN -n --arg token "$claim_token" '{token:$token}')" >/dev/null
    unset claim_token created
    address_state="unavailable"
    if [[ "$state" == live && -n "$url" ]]; then
      if wait_for_branded_url "$url"; then address_state="ready"; else address_state="propagating"; fi
    fi
    "$JQ_BIN" -n --arg appId "$app_id" --arg state "$state" --arg url "$url" --arg addressState "$address_state" \
      '{appId:$appId,state:$state,persistence:"permanent",addressState:$addressState}
      + (if $addressState == "ready" then {url:$url}
         elif $addressState == "propagating" then {next:("The app is permanent. Its address is still finishing. Run fullstack.sh status " + $appId + " in a few seconds.")}
         else {} end)'
    ;;
  status)
    [[ $# -eq 1 ]] || die "usage: fullstack.sh status <app-id>"
    valid_app_id "$1"; load_account_key; api_account GET "$BASE_URL/api/v1/fullstack/$1/status" | "$JQ_BIN" .
    ;;
  delete)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh delete <app-id> --confirm <app-id> [--dry-run]"
    app_id="$1"; shift; confirm=""; dry=0; valid_app_id "$app_id"
    while [[ $# -gt 0 ]]; do case "$1" in --confirm) confirm="$2"; shift 2 ;; --dry-run) dry=1; shift ;; *) die "unexpected delete argument: $1" ;; esac; done
    [[ "$confirm" == "$app_id" ]] || die "delete requires --confirm $app_id"
    if [[ "$dry" -eq 1 ]]; then "$JQ_BIN" -n --arg appId "$app_id" '{dryRun:true,action:"delete",appId:$appId}'; exit 0; fi
    load_account_key; api_account DELETE "$BASE_URL/api/v1/fullstack/$app_id" | "$JQ_BIN" .
    ;;
  *) die "unknown command: $CMD" ;;
esac
