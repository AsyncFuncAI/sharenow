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
  init loop-crm <empty-folder>
  prepare <project-folder> [--dry-run]
  plan --contract <yaml-file> --drive <drive-id> --manifest <json-file>
  validate <plan-id>
  approve <plan-id> [--for-app <app-id>]
  deploy <plan-id> [--secrets-from <mode-600-json-file>] [--dry-run]
  update <app-id> <plan-id> [--secrets-from <mode-600-json-file>] [--dry-run]
  ship <project-folder> [--app <app-id>] [--secrets-from <mode-600-json-file>]
  status <app-id>
  sql <app-id> <select-statement> [--binding <name>]
  logs <app-id> [--seconds <5-60>]
  rename <app-id> <new-slug>
  delete <app-id> --confirm <app-id> [--dry-run]

Prepare scans one explicit project folder. Its dry-run is local. The live path
stages accepted files in one private Drive and validates the exact remote bytes
without provisioning. Deploy requires a separate approve command and repeats
remote validation. Ship chains prepare + approve + deploy (or update with
--app) in one command - run it only when your user has already approved
shipping this exact project. Secret values are accepted only from a mode-600
JSON file, never from command-line values, and are never printed.

sql runs one read-only SELECT against the app's D1 (no app route needed).
logs captures LIVE Worker events for a bounded window: start it (in the
background), then exercise the app, then read the result.
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
command -v file >/dev/null 2>&1 || die "requires file"
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

absolute_dir() {
  local input="$1"
  [[ -d "$input" ]] || die "folder not found: $input"
  (cd "$input" && pwd)
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

declared_triggers() {
  awk '
    /^triggers:[[:space:]]*$/ { in_triggers=1; next }
    in_triggers && /^[^[:space:]]/ { in_triggers=0 }
    in_triggers && /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      if (name != "") print name "\t" type "\t" cron
      line=$0; sub(/^.*name:[[:space:]]*/, "", line); gsub(/"/, "", line)
      name=line; type=""; cron=""; next
    }
    in_triggers && /^[[:space:]]*type:[[:space:]]*/ {
      line=$0; sub(/^.*type:[[:space:]]*/, "", line); gsub(/"/, "", line); type=line; next
    }
    in_triggers && /^[[:space:]]*cron:[[:space:]]*/ {
      line=$0; sub(/^.*cron:[[:space:]]*/, "", line); gsub(/^"|"$/, "", line); cron=line; next
    }
    END { if (name != "") print name "\t" type "\t" cron }
  ' "$1" | "$JQ_BIN" -Rsc '
    split("\n") | map(select(length > 0) | split("\t") | {name:.[0],type:.[1],cron:.[2]})
  '
}

is_sensitive_path() {
  local path="$1" base lower
  base="${path##*/}"
  lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.jks|id_rsa|id_ed25519|credentials|credentials.json|service-account*.json|.npmrc|.netrc|.pypirc)
      return 0 ;;
  esac
  case "$path" in
    .sharenow/*|*/.sharenow/*|.aws/*|*/.aws/*|.ssh/*|*/.ssh/*) return 0 ;;
  esac
  return 1
}

project_manifest() {
  local root="$1" manifest='[]' count=0 total=0 file_path rel size sha
  if find "$root" -type l -print -quit | grep -q .; then
    die "project contains a symbolic link; copy the intended file into the folder instead"
  fi
  while IFS= read -r -d '' file_path; do
    rel="${file_path#"$root"/}"
    case "$rel" in .git/*|node_modules/*|.DS_Store|*/.DS_Store) continue ;; esac
    [[ "$rel" != *$'\n'* && "$rel" != /* && "$rel" != *../* && "$rel" != ../* ]] || die "unsafe project path: $rel"
    is_sensitive_path "$rel" && die "sensitive file refused: $rel"
    size=$(wc -c < "$file_path" | tr -d '[:space:]')
    [[ "$size" -le 20971520 ]] || die "project file exceeds 20 MiB: $rel"
    count=$((count + 1)); total=$((total + size))
    [[ "$count" -le 500 ]] || die "project exceeds 500 files"
    [[ "$total" -le 52428800 ]] || die "project exceeds 50 MiB"
    sha=$(file_sha "$file_path")
    manifest=$(printf '%s' "$manifest" | "$JQ_BIN" -c --arg path "$rel" --arg sha "$sha" --argjson size "$size" '. + [{path:$path,sha256:$sha,size:$size}]')
  done < <(find "$root" -type f -print0 | sort -z)
  [[ "$count" -gt 0 ]] || die "project folder contains no accepted files"
  printf '%s' "$manifest" | "$JQ_BIN" -c 'sort_by(.path)'
}

stage_project_file() {
  local drive_id="$1" root="$2" entry="$3" rel size sha content_type metadata started upload_url upload_id code
  rel=$(printf '%s' "$entry" | "$JQ_BIN" -r '.path')
  size=$(printf '%s' "$entry" | "$JQ_BIN" -r '.size')
  sha=$(printf '%s' "$entry" | "$JQ_BIN" -r '.sha256')
  content_type=$(file --brief --mime-type "$root/$rel" 2>/dev/null || printf '%s' application/octet-stream)
  metadata=$("$JQ_BIN" -n --arg path "$rel" --argjson size "$size" --arg type "$content_type" --arg sha "$sha" \
    '{path:$path,size:$size,contentType:$type,sha256:$sha,ifNoneMatch:"*"}')
  started=$(api_account POST "$BASE_URL/api/v1/drives/$drive_id/files/uploads" "$metadata")
  upload_url=$(printf '%s' "$started" | "$JQ_BIN" -r '.uploadUrl // empty')
  upload_id=$(printf '%s' "$started" | "$JQ_BIN" -r '.uploadId // empty')
  [[ "$upload_url" == https://* && -n "$upload_id" ]] || die "invalid Drive upload response"
  code=$(curl -sS -o /dev/null -w "%{http_code}" -X PUT "$upload_url" -H "content-type: $content_type" --data-binary "@$root/$rel")
  [[ "$code" -ge 200 && "$code" -lt 300 ]] || die "Drive upload failed for $rel (HTTP $code)"
  api_account POST "$BASE_URL/api/v1/drives/$drive_id/files/finalize" "$("$JQ_BIN" -n --arg uploadId "$upload_id" '{uploadId:$uploadId}')" >/dev/null
}

remote_validate() {
  local receipt="$1" env_json="${2:-}" contract_path yaml body result
  [[ -n "$env_json" ]] || env_json='{}'
  contract_path=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
  yaml=$(cat "$contract_path")
  body=$("$JQ_BIN" -n --arg yaml "$yaml" \
    --arg driveId "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')" \
    --argjson manifest "$(printf '%s' "$receipt" | "$JQ_BIN" -c '.manifest')" \
    --argjson env "$env_json" '{yaml:$yaml,driveId:$driveId,manifest:$manifest,env:$env}')
  result=$(api_account POST "$BASE_URL/api/v1/fullstack/validate" "$body")
  unset body yaml
  [[ "$(printf '%s' "$result" | "$JQ_BIN" -r '.valid // false')" == true ]] || die "remote Fullstack validation did not return a valid receipt"
  printf '%s' "$result"
}

verify_receipt_content() {
  local receipt="$1" contract manifest contract_sha manifest_sha normalized source_type project_root
  contract=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
  source_type=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')
  if [[ "$source_type" == project ]]; then
    project_root=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.projectRoot')
    [[ -f "$contract" && -d "$project_root" ]] || die "planned project no longer exists; create a new plan"
    normalized=$(project_manifest "$project_root")
  else
    manifest=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.manifestPath')
    [[ -f "$contract" && -f "$manifest" ]] || die "planned contract or manifest no longer exists; create a new plan"
    normalized=$(normalize_manifest "$manifest")
  fi
  contract_sha=$(file_sha "$contract")
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
  init)
    [[ $# -eq 2 ]] || die "usage: fullstack.sh init loop-crm <empty-folder>"
    [[ "$1" == loop-crm ]] || die "unknown Fullstack starter: $1"
    destination="$2"
    if [[ -e "$destination" ]]; then
      [[ -d "$destination" && -z "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "destination must be empty"
    else
      mkdir -p "$destination"
    fi
    template_dir="$SKILL_DIR/templates/loop-crm"
    [[ -d "$template_dir" ]] || die "loop-crm starter is missing from this skill installation"
    cp -Rp "$template_dir/." "$destination/"
    destination=$(absolute_dir "$destination")
    "$JQ_BIN" -n --arg destination "$destination" '{template:"loop-crm",destination:$destination,next:("Review " + $destination + ", then run fullstack.sh prepare " + $destination + " --dry-run.")}'
    ;;
  prepare)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh prepare <project-folder> [--dry-run]"
    project="$1"; shift; dry=0
    while [[ $# -gt 0 ]]; do
      case "$1" in --dry-run) dry=1; shift ;; *) die "unexpected prepare argument: $1" ;; esac
    done
    project=$(absolute_dir "$project")
    contract="$project/fullstack.yaml"
    [[ -f "$contract" ]] || die "project must contain fullstack.yaml at its root"
    manifest=$(project_manifest "$project")
    file_count=$(printf '%s' "$manifest" | "$JQ_BIN" 'length')
    byte_count=$(printf '%s' "$manifest" | "$JQ_BIN" '[.[].size] | add // 0')
    env_names=$(declared_env "$contract")
    triggers=$(declared_triggers "$contract")
    if [[ "$dry" -eq 1 ]]; then
      "$JQ_BIN" -n --arg project "$project" --argjson files "$file_count" --argjson bytes "$byte_count" \
        --argjson requiredSecrets "$env_names" --argjson triggers "$triggers" \
        '{dryRun:true,networkRequests:0,project:$project,contract:"fullstack.yaml",files:$files,bytes:$bytes,requiredSecrets:$requiredSecrets,triggers:$triggers,next:"Run prepare again without --dry-run to stage and remotely validate these exact files."}'
      exit 0
    fi
    load_account_key
    contract_sha=$(file_sha "$contract")
    manifest_sha=$(printf '%s' "$manifest" | text_sha)
    bundle_hash=$(printf '%s\n%s\n' "$contract_sha" "$manifest_sha" | text_sha)
    drive_response=$(api_account POST "$BASE_URL/api/v1/drives" "$("$JQ_BIN" -n --arg name "Fullstack staging ${bundle_hash:0:8}" '{name:$name,isDefault:false}')")
    drive_id=$(printf '%s' "$drive_response" | "$JQ_BIN" -r '.drive.id // .id // empty')
    [[ "$drive_id" == drv_* && "$drive_id" != *[!A-Za-z0-9_-]* ]] || die "invalid Drive create response"
    while IFS= read -r entry; do stage_project_file "$drive_id" "$project" "$entry"; done < <(printf '%s' "$manifest" | "$JQ_BIN" -c '.[]')
    plan_hash=$(printf '%s\n%s\n%s\n' "$drive_id" "$contract_sha" "$manifest_sha" | text_sha)
    plan_id="fsp_${plan_hash:0:24}"
    receipt=$("$JQ_BIN" -n --arg planId "$plan_id" --arg driveId "$drive_id" \
      --arg projectRoot "$project" --arg contractPath "$contract" \
      --arg contractSha256 "$contract_sha" --arg manifestSha256 "$manifest_sha" \
      --argjson manifest "$manifest" --argjson declaredEnv "$env_names" \
      '{planId:$planId,sourceType:"project",projectRoot:$projectRoot,driveId:$driveId,contractPath:$contractPath,contractSha256:$contractSha256,manifestSha256:$manifestSha256,manifest:$manifest,declaredEnv:$declaredEnv,approved:false,approvedAt:null}')
    validation=$(remote_validate "$receipt")
    receipt=$("$JQ_BIN" -n --argjson receipt "$receipt" --argjson validation "$validation" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '$receipt + {remoteValidation:$validation,validatedAt:$at}')
    write_receipt "$(receipt_path "$plan_id")" "$receipt"
    "$JQ_BIN" -n --arg planId "$plan_id" --arg driveId "$drive_id" --argjson validation "$validation" \
      '$validation + {planId:$planId,state:"validated",driveId:$driveId,approved:false,next:("Review this exact validated plan, then run fullstack.sh approve " + $planId + ".")}'
    ;;
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
      '{planId:$planId,sourceType:"legacy",driveId:$driveId,contractPath:$contractPath,manifestPath:$manifestPath,contractSha256:$contractSha256,manifestSha256:$manifestSha256,manifest:$manifest,declaredEnv:$declaredEnv,approved:false,approvedAt:null}')
    write_receipt "$(receipt_path "$plan_id")" "$receipt"
    "$JQ_BIN" -n --arg planId "$plan_id" --arg driveId "$drive" --argjson files "$(printf '%s' "$normalized" | $JQ_BIN 'length')" --argjson declaredEnv "$env_names" \
      '{planId:$planId,state:"planned",driveId:$driveId,fileCount:$files,requiredSecrets:$declaredEnv,next:"Review the plan, then run fullstack.sh approve <plan-id>."}'
    ;;
  validate)
    [[ $# -eq 1 ]] || die "usage: fullstack.sh validate <plan-id>"
    plan_id="$1"; receipt=$(read_receipt "$plan_id"); verify_receipt_content "$receipt"
    load_account_key
    validation=$(remote_validate "$receipt")
    receipt=$("$JQ_BIN" -n --argjson receipt "$receipt" --argjson validation "$validation" --arg at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '$receipt + {remoteValidation:$validation,validatedAt:$at}')
    write_receipt "$(receipt_path "$plan_id")" "$receipt"
    "$JQ_BIN" -n --arg planId "$plan_id" --argjson validation "$validation" '$validation + {planId:$planId,state:"validated",provisioned:false}'
    ;;
  approve)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh approve <plan-id> [--for-app <app-id>]"
    plan_id="$1"; shift; target_app=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --for-app) [[ $# -ge 2 ]] || die "--for-app requires an app id"; target_app="$2"; shift 2 ;;
        *) die "unexpected approve argument: $1" ;;
      esac
    done
    [[ -z "$target_app" ]] || valid_app_id "$target_app"
    receipt=$(read_receipt "$plan_id"); verify_receipt_content "$receipt"
    approved=$($JQ_BIN -n --argjson receipt "$receipt" --arg approvedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg targetAppId "$target_app" \
      '$receipt + {approved:true,approvedAt:$approvedAt,targetAppId:(if $targetAppId == "" then null else $targetAppId end)}')
    write_receipt "$(receipt_path "$plan_id")" "$approved"
    "$JQ_BIN" -n --arg planId "$plan_id" --arg targetAppId "$target_app" \
      '{planId:$planId,approved:true,targetAppId:(if $targetAppId == "" then null else $targetAppId end),next:(if $targetAppId == "" then ("Deploy this exact plan with fullstack.sh deploy " + $planId + ".") else ("Update " + $targetAppId + " with fullstack.sh update " + $targetAppId + " " + $planId + ".") end)}'
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
    target_app=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.targetAppId // empty')
    [[ -z "$target_app" ]] || die "plan is approved for updating $target_app; use fullstack.sh update $target_app $plan_id"
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
      "$JQ_BIN" -n --arg planId "$plan_id" '{dryRun:true,planId:$planId,approved:true,localContentVerified:true,remoteValidated:false,networkRequests:0,next:"Run deploy again without --dry-run to repeat remote validation and provision this exact plan."}'
      exit 0
    fi
    load_account_key
    validation=$(remote_validate "$receipt" "$env_json")
    contract_path=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
    yaml=$(cat "$contract_path")
    body=$($JQ_BIN -n --arg yaml "$yaml" --arg driveId "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')" --argjson manifest "$(printf '%s' "$receipt" | "$JQ_BIN" -c '.manifest')" --argjson env "$env_json" '{yaml:$yaml,driveId:$driveId,manifest:$manifest,env:$env}')
    idem=$(make_idempotency_key)
    created=$(api_account POST "$BASE_URL/api/v1/fullstack" "$body" "$idem")
    unset body env_json yaml validation
    app_id=$(printf '%s' "$created" | "$JQ_BIN" -r '.appId // empty')
    claim_token=$(printf '%s' "$created" | "$JQ_BIN" -r '.claimToken // empty')
    valid_app_id "$app_id"; [[ "$claim_token" == clm_* ]] || die "invalid Fullstack create response"
    state="provisioning"; waited=0; status='{}'
    while [[ "$state" == provisioning && "$waited" -lt 180 ]]; do
      sleep 2; waited=$((waited + 2)); status=$(api_account GET "$BASE_URL/api/v1/fullstack/$app_id/status"); state=$(printf '%s' "$status" | "$JQ_BIN" -r '.state // empty')
    done
    [[ "$state" == live || "$state" == failed ]] || die "Fullstack app did not reach a final state (state: ${state:-unknown})"
    if [[ "$state" == failed ]]; then
      failure_code=$(printf '%s' "$status" | "$JQ_BIN" -r '.failureCode // "provision_unknown"')
      cleanup_body=$("$JQ_BIN" -n --arg token "$claim_token" '{token:$token}')
      api_account DELETE "$BASE_URL/api/v1/fullstack/$app_id" "$cleanup_body" >/dev/null || true
      unset claim_token created cleanup_body
      die "Fullstack provisioning failed at $failure_code. Cleanup of the disposable app was requested; the validated staging Drive remains available for a corrected plan"
    fi
    url=$(printf '%s' "$status" | "$JQ_BIN" -r '.url // empty')
    [[ -n "$url" ]] && valid_branded_url "$url" || die "invalid Fullstack live URL"
    api_account POST "$BASE_URL/api/v1/fullstack/$app_id/claim" "$($JQ_BIN -n --arg token "$claim_token" '{token:$token}')" >/dev/null
    unset claim_token created
    staging_drive="not_applicable"
    if [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')" == project ]]; then
      drive_id=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')
      if api_account DELETE "$BASE_URL/api/v1/drives/$drive_id" >/dev/null; then
        staging_drive="removed"
      else
        staging_drive="retained"
      fi
    fi
    address_state="unavailable"
    if wait_for_branded_url "$url"; then address_state="ready"; else address_state="propagating"; fi
    "$JQ_BIN" -n --arg appId "$app_id" --arg state "$state" --arg url "$url" --arg addressState "$address_state" --arg stagingDrive "$staging_drive" \
      '{appId:$appId,state:$state,persistence:"permanent",addressState:$addressState,stagingDrive:$stagingDrive}
      + (if $addressState == "ready" then {url:$url}
         elif $addressState == "propagating" then {next:("The app is permanent. Its address is still finishing. Run fullstack.sh status " + $appId + " in a few seconds.")}
         else {} end)'
    ;;
  update)
    [[ $# -ge 2 ]] || die "usage: fullstack.sh update <app-id> <plan-id> [--secrets-from <mode-600-json-file>] [--dry-run]"
    app_id="$1"; plan_id="$2"; shift 2; secrets_file=""; dry=0
    valid_app_id "$app_id"; valid_plan_id "$plan_id"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --secrets-from) [[ $# -ge 2 ]] || die "--secrets-from requires a file"; secrets_file="$2"; shift 2 ;;
        --dry-run) dry=1; shift ;;
        *) die "unexpected update argument: $1" ;;
      esac
    done
    receipt=$(read_receipt "$plan_id")
    [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.approved')" == true ]] || die "Fullstack plan is not approved; review it and run fullstack.sh approve $plan_id"
    target_app=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.targetAppId // empty')
    [[ -n "$target_app" ]] || die "plan approval is not bound to an app; run fullstack.sh approve $plan_id --for-app $app_id"
    [[ "$target_app" == "$app_id" ]] || die "plan is approved for a different Fullstack app: $target_app"
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
      "$JQ_BIN" -n --arg appId "$app_id" --arg planId "$plan_id" '{dryRun:true,action:"update",appId:$appId,planId:$planId,approved:true,localContentVerified:true,remoteValidated:false,networkRequests:0,next:"Run update again without --dry-run to revalidate and update this existing app in place."}'
      exit 0
    fi
    load_account_key
    validation=$(remote_validate "$receipt" "$env_json")
    contract_path=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.contractPath')
    yaml=$(cat "$contract_path")
    body=$($JQ_BIN -n --arg yaml "$yaml" --arg driveId "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')" --argjson manifest "$(printf '%s' "$receipt" | "$JQ_BIN" -c '.manifest')" --argjson env "$env_json" '{yaml:$yaml,driveId:$driveId,manifest:$manifest,env:$env}')
    updated=$(api_account PUT "$BASE_URL/api/v1/fullstack/$app_id" "$body")
    unset body env_json yaml validation
    [[ "$(printf '%s' "$updated" | "$JQ_BIN" -r '.appId // empty')" == "$app_id" ]] || die "Fullstack update response changed the app id"
    [[ "$(printf '%s' "$updated" | "$JQ_BIN" -r '.updated // false')" == true ]] || die "Fullstack update did not confirm success"
    staging_drive="not_applicable"
    if [[ "$(printf '%s' "$receipt" | "$JQ_BIN" -r '.sourceType // "legacy"')" == project ]]; then
      drive_id=$(printf '%s' "$receipt" | "$JQ_BIN" -r '.driveId')
      if api_account DELETE "$BASE_URL/api/v1/drives/$drive_id" >/dev/null; then
        staging_drive="removed"
      else
        staging_drive="retained"
      fi
    fi
    printf '%s' "$updated" | "$JQ_BIN" --arg stagingDrive "$staging_drive" '. + {stagingDrive:$stagingDrive}'
    ;;
  ship)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh ship <project-folder> [--app <app-id>] [--secrets-from <mode-600-json-file>]"
    project="$1"; shift; target_app=""; secrets_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --app) [[ $# -ge 2 ]] || die "--app requires an app id"; target_app="$2"; shift 2 ;;
        --secrets-from) [[ $# -ge 2 ]] || die "--secrets-from requires a file"; secrets_file="$2"; shift 2 ;;
        *) die "unexpected ship argument: $1" ;;
      esac
    done
    [[ -z "$target_app" ]] || valid_app_id "$target_app"
    project=$(absolute_dir "$project")
    prepared=$("$0" prepare "$project") || die "ship failed at prepare"
    ship_plan_id=$(printf '%s' "$prepared" | "$JQ_BIN" -r '.planId // empty')
    valid_plan_id "$ship_plan_id"
    if [[ -n "$target_app" ]]; then
      "$0" approve "$ship_plan_id" --for-app "$target_app" >/dev/null || die "ship failed at approve"
    else
      "$0" approve "$ship_plan_id" >/dev/null || die "ship failed at approve"
    fi
    ship_args=()
    [[ -z "$secrets_file" ]] || ship_args=(--secrets-from "$secrets_file")
    if [[ -n "$target_app" ]]; then
      "$0" update "$target_app" "$ship_plan_id" ${ship_args[@]+"${ship_args[@]}"}
    else
      "$0" deploy "$ship_plan_id" ${ship_args[@]+"${ship_args[@]}"}
    fi
    ;;
  status)
    [[ $# -eq 1 ]] || die "usage: fullstack.sh status <app-id>"
    valid_app_id "$1"; load_account_key; api_account GET "$BASE_URL/api/v1/fullstack/$1/status" | "$JQ_BIN" .
    ;;
  sql)
    [[ $# -ge 2 ]] || die "usage: fullstack.sh sql <app-id> <select-statement> [--binding <name>]"
    app_id="$1"; sql_text="$2"; shift 2; binding=""
    valid_app_id "$app_id"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --binding) [[ $# -ge 2 ]] || die "--binding requires a name"; binding="$2"; shift 2 ;;
        *) die "unexpected sql argument: $1" ;;
      esac
    done
    load_account_key
    if [[ -n "$binding" ]]; then
      body=$("$JQ_BIN" -cn --arg sql "$sql_text" --arg binding "$binding" '{sql:$sql,binding:$binding}')
    else
      body=$("$JQ_BIN" -cn --arg sql "$sql_text" '{sql:$sql}')
    fi
    api_account POST "$BASE_URL/api/v1/fullstack/$app_id/sql" "$body" | "$JQ_BIN" .
    ;;
  logs)
    [[ $# -ge 1 ]] || die "usage: fullstack.sh logs <app-id> [--seconds <5-60>]"
    app_id="$1"; shift; seconds=""
    valid_app_id "$app_id"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --seconds) [[ $# -ge 2 ]] || die "--seconds requires a number"; seconds="$2"; shift 2 ;;
        *) die "unexpected logs argument: $1" ;;
      esac
    done
    load_account_key
    if [[ -n "$seconds" ]]; then
      [[ "$seconds" != *[!0-9]* && -n "$seconds" ]] || die "--seconds must be a whole number between 5 and 60"
      body=$("$JQ_BIN" -cn --argjson seconds "$seconds" '{seconds:$seconds}')
    else
      body='{}'
    fi
    echo "capturing live Worker events (exercise the app now)..." >&2
    api_account POST "$BASE_URL/api/v1/fullstack/$app_id/logs" "$body" | "$JQ_BIN" .
    ;;
  rename)
    [[ $# -eq 2 ]] || die "usage: fullstack.sh rename <app-id> <new-slug>"
    valid_app_id "$1"; load_account_key
    api_account POST "$BASE_URL/api/v1/fullstack/$1/rename" "$("$JQ_BIN" -cn --arg s "$2" '{slug:$s}')" | "$JQ_BIN" .
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
