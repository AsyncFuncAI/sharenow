#!/usr/bin/env bash
set -euo pipefail

BASE_URL="https://sharenow.today"
MANIFEST_URL="$BASE_URL/.well-known/sharenow-skill.json"
OFFICIAL_SOURCE="AsyncFuncAI/sharenow"
SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_ROOT="${SHARENOW_STATE_DIR:-$HOME/.sharenow}"
CONFIG_FILE="$STATE_ROOT/config.json"
INSTALL_DIR="$HOME/.agents/skills/sharenow"

usage() {
  local code="${1:-1}"
  cat <<'USAGE'
Usage: version.sh <command> [args]

Commands:
  status [--force]
  consent status|on|off
  update [--yes]

Updates are accepted only from AsyncFuncAI/sharenow through the skills CLI.
The installed package is checked against the first-party release manifest. A
failed install or hash check restores the prior canonical installation.
USAGE
  exit "$code"
}

die() { echo "error: $1" >&2; exit 1; }

BUNDLED_JQ="$SKILL_ROOT/bin/jq"
if [[ -x "$BUNDLED_JQ" ]]; then JQ_BIN="$BUNDLED_JQ"
elif command -v jq >/dev/null 2>&1; then JQ_BIN="$(command -v jq)"
else die "requires jq. Install it with 'brew install jq' (macOS) or 'sudo apt-get install jq' (Debian/Ubuntu), then retry"; fi
command -v curl >/dev/null 2>&1 || die "requires curl"
command -v shasum >/dev/null 2>&1 || die "requires shasum"

current_version() {
  local value
  value=$(sed -n 's/^\*\*Skill version: \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\*\*$/\1/p' "$SKILL_ROOT/SKILL.md" | head -1)
  [[ -n "$value" ]] || die "could not read installed skill version"
  printf '%s\n' "$value"
}

valid_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

semver_cmp() {
  local a="$1" b="$2" a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<< "$a"
  IFS=. read -r b1 b2 b3 <<< "$b"
  if (( a1 < b1 )); then echo -1; return; elif (( a1 > b1 )); then echo 1; return; fi
  if (( a2 < b2 )); then echo -1; return; elif (( a2 > b2 )); then echo 1; return; fi
  if (( a3 < b3 )); then echo -1; else (( a3 > b3 )) && echo 1 || echo 0; fi
}

fetch_manifest() {
  local tmp code manifest
  tmp=$(mktemp)
  code=$(curl -sS -o "$tmp" -w "%{http_code}" "$MANIFEST_URL")
  [[ "$code" == 200 ]] || { rm -f "$tmp"; die "could not fetch the first-party skill manifest (HTTP $code)"; }
  manifest=$(cat "$tmp"); rm -f "$tmp"
  printf '%s' "$manifest" | "$JQ_BIN" -e \
    --arg source "$OFFICIAL_SOURCE" '
      .name == "sharenow"
      and .source == $source
      and (.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      and (.latestVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      and (.minimumVersion | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
      and (.files | type == "array")
      and all(.files[];
        (.path | type) == "string"
        and (.path | length) > 0
        and (.path | startswith("/") | not)
        and (.path | contains("..") | not)
        and (.sha256 | type == "string" and test("^[a-f0-9]{64}$")))
    ' >/dev/null 2>&1 || die "first-party skill manifest failed validation"
  printf '%s\n' "$manifest"
}

config_value() {
  local field="$1"
  [[ -f "$CONFIG_FILE" ]] || return 0
  "$JQ_BIN" -r --arg field "$field" '.[$field] // empty' "$CONFIG_FILE" 2>/dev/null || true
}

write_config() {
  local json="$1" dir tmp
  dir=$(dirname "$CONFIG_FILE"); mkdir -p "$dir"; umask 077
  tmp=$(mktemp "$dir/.config.XXXXXX") || die "could not write version configuration"
  if printf '%s' "$json" | "$JQ_BIN" -e . > "$tmp"; then chmod 600 "$tmp"; mv "$tmp" "$CONFIG_FILE"
  else rm -f "$tmp"; die "could not write version configuration"; fi
}

update_config_field() {
  local field="$1" value="$2" current='{}'
  [[ -f "$CONFIG_FILE" ]] && current=$(cat "$CONFIG_FILE")
  write_config "$(printf '%s' "$current" | "$JQ_BIN" --arg field "$field" --argjson value "$value" '.[$field]=$value')"
}

verify_dir() {
  local root="$1" manifest="$2" expected_version actual_version path expected actual
  expected_version=$(printf '%s' "$manifest" | "$JQ_BIN" -r '.version')
  [[ -f "$root/SKILL.md" ]] || return 1
  actual_version=$(sed -n 's/^\*\*Skill version: \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)\*\*$/\1/p' "$root/SKILL.md" | head -1)
  [[ "$actual_version" == "$expected_version" ]] || return 1
  while IFS=$'\t' read -r path expected; do
    [[ -n "$path" && -f "$root/$path" ]] || return 1
    actual=$(shasum -a 256 "$root/$path" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || return 1
  done < <(printf '%s' "$manifest" | "$JQ_BIN" -r '.files[] | [.path,.sha256] | @tsv')
}

status_json() {
  local manifest="$1" current latest minimum released state integrity
  current=$(current_version)
  released=$(printf '%s' "$manifest" | "$JQ_BIN" -r '.version')
  latest=$(printf '%s' "$manifest" | "$JQ_BIN" -r '.latestVersion')
  minimum=$(printf '%s' "$manifest" | "$JQ_BIN" -r '.minimumVersion')
  valid_semver "$current" && valid_semver "$released" && valid_semver "$latest" && valid_semver "$minimum" || die "invalid version in release data"
  integrity="unverified"
  if [[ "$(semver_cmp "$current" "$minimum")" -lt 0 ]]; then state="update_required"
  elif [[ "$(semver_cmp "$current" "$latest")" -lt 0 ]]; then state="update_available"
  elif [[ "$current" == "$released" ]]; then
    if verify_dir "$SKILL_ROOT" "$manifest"; then state="current"; integrity="verified"
    else state="update_required"; integrity="drifted"; fi
  else state="current"; fi
  "$JQ_BIN" -n --arg state "$state" --arg integrity "$integrity" --arg currentVersion "$current" --arg latestVersion "$latest" --arg minimumVersion "$minimum" --arg source "$OFFICIAL_SOURCE" \
    '{state:$state,integrity:$integrity,currentVersion:$currentVersion,latestVersion:$latestVersion,minimumVersion:$minimumVersion,source:$source}'
}

restore_install() {
  local backup_root="$1" reason="$2"
  if [[ -e "$INSTALL_DIR" ]]; then mv "$INSTALL_DIR" "$backup_root/failed-install" 2>/dev/null || true; fi
  if [[ -d "$backup_root/sharenow" ]]; then mkdir -p "$(dirname "$INSTALL_DIR")"; mv "$backup_root/sharenow" "$INSTALL_DIR"; fi
  echo "error: skill update failed ($reason); the previous installation was restored" >&2
  exit 1
}

verify_install() {
  verify_dir "$INSTALL_DIR" "$1"
}

CMD="${1:-}"
case "$CMD" in --help|-h) usage 0 ;; "") usage ;; esac
shift

case "$CMD" in
  status)
    force=0
    while [[ $# -gt 0 ]]; do case "$1" in --force) force=1; shift ;; *) die "unexpected status argument: $1" ;; esac; done
    manifest=$(fetch_manifest)
    status_json "$manifest"
    ;;
  consent)
    [[ $# -eq 1 ]] || die "usage: version.sh consent status|on|off"
    case "$1" in
      status) value=$(config_value managedUpdates); [[ -n "$value" ]] || value=false; "$JQ_BIN" -n --argjson managedUpdates "$value" '{managedUpdates:$managedUpdates}' ;;
      on) update_config_field managedUpdates true; "$JQ_BIN" -n '{managedUpdates:true}' ;;
      off) update_config_field managedUpdates false; "$JQ_BIN" -n '{managedUpdates:false}' ;;
      *) die "usage: version.sh consent status|on|off" ;;
    esac
    ;;
  update)
    yes=0
    while [[ $# -gt 0 ]]; do case "$1" in --yes) yes=1; shift ;; *) die "unexpected update argument: $1" ;; esac; done
    consent=$(config_value managedUpdates); [[ "$consent" == true ]] || consent=false
    [[ "$yes" -eq 1 || "$consent" == true ]] || die "update requires --yes or prior consent via version.sh consent on"
    manifest=$(fetch_manifest)
    [[ "$(printf '%s' "$manifest" | "$JQ_BIN" '.files | length')" -gt 0 ]] || die "release manifest contains no files"
    mkdir -p "$STATE_ROOT"; umask 077; backup_root=$(mktemp -d "$STATE_ROOT/update-backup.XXXXXX") || die "could not create update backup"
    if [[ -d "$INSTALL_DIR" ]]; then mv "$INSTALL_DIR" "$backup_root/sharenow"; fi
    mkdir -p "$(dirname "$INSTALL_DIR")"
    npx_bin="${SHARENOW_NPX_BIN:-npx}"
    if ! "$npx_bin" -y skills add "$OFFICIAL_SOURCE" --skill sharenow -g -y >/dev/null 2>&1; then restore_install "$backup_root" "installer error"; fi
    if ! verify_install "$manifest"; then restore_install "$backup_root" "release verification error"; fi
    if [[ -d "$backup_root/sharenow" ]]; then mv "$backup_root/sharenow" "$STATE_ROOT/previous-skill" 2>/dev/null || true; fi
    rmdir "$backup_root" 2>/dev/null || true
    status_json "$manifest"
    ;;
  *) die "unknown command: $CMD" ;;
esac
