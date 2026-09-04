# source.sh: the local source stamp and the messages built on it.
#
# This file is SOURCED, not executed. Every sharenow script computes its own
# SCRIPT_DIR and sources this as "$SCRIPT_DIR/lib/source.sh" AFTER it has
# defined the two symbols this code depends on:
#   - JQ_BIN : path to the jq binary (bundled or system)
#   - die    : die() { echo "error: $1" >&2; exit 1; }
#
# What it holds: reading and writing `.sharenow/source.json`, and rendering the
# refusal an agent sees when its folder is behind the live version.
#
# The stamp is the whole freshness mechanism from the folder's side. It records
# which LIVE VERSION this folder was built from, never a commit id: the version
# is sharenow's own identity for "what is being served", so the check that reads
# it back never has to ask the git service and still answers while git is down.
# A commit id would have made every deploy depend on the recorder having caught
# up, which is the failure the 2026-09-03 prototype found.
#
# Shape (`v` is a real version number so a later change is detectable rather
# than silently misparsed):
#
#   {"v":1,"kind":"site","slug":"my-site","version":"dv_...","commit":"<40 hex>|null",
#    "pulledAt":"2026-09-03T00:00:00.000Z"}

# Where the stamp lives inside a pulled folder.
SOURCE_STAMP_REL=".sharenow/source.json"

# source_stamp_path <dir> -> the stamp's path (whether or not it exists).
source_stamp_path() { printf '%s/%s\n' "${1%/}" "$SOURCE_STAMP_REL"; }

# source_stamp_field <dir> <field> -> the field's value, or empty.
# Empty on a missing file, unreadable JSON, or a null: every caller treats
# "no answer" the same way, which is "make no freshness claim".
source_stamp_field() {
  local stamp
  stamp="$(source_stamp_path "$1")"
  [[ -f "$stamp" ]] || return 0
  "$JQ_BIN" -r --arg f "$2" '.[$f] // empty' "$stamp" 2>/dev/null || true
}

# source_stamp_version <dir> -> the live version this folder was built from.
source_stamp_version() { source_stamp_field "$1" version; }

# source_stamp_slug <dir> -> the resource the stamp belongs to.
source_stamp_slug() { source_stamp_field "$1" slug; }

# source_write_stamp <dir> <kind> <slug> <version> <commit>
#   Writes the stamp atomically. An empty commit is written as JSON null, which
#   is the honest answer while the recorder has not caught up: the folder is
#   still exactly the live version, and that is what the freshness check reads.
source_write_stamp() {
  local dir="${1%/}" kind="$2" slug="$3" version="$4" commit="${5:-}" stamp tmp
  stamp="$(source_stamp_path "$dir")"
  mkdir -p "$(dirname "$stamp")" || return 1
  tmp="$stamp.tmp.$$"
  if [[ -n "$commit" ]]; then
    "$JQ_BIN" -n --arg kind "$kind" --arg slug "$slug" --arg version "$version" --arg commit "$commit" \
      '{v:1,kind:$kind,slug:$slug,version:$version,commit:$commit,pulledAt:(now|todateiso8601)}' > "$tmp" || return 1
  else
    "$JQ_BIN" -n --arg kind "$kind" --arg slug "$slug" --arg version "$version" \
      '{v:1,kind:$kind,slug:$slug,version:$version,commit:null,pulledAt:(now|todateiso8601)}' > "$tmp" || return 1
  fi
  mv "$tmp" "$stamp"
}

# source_sibling_dir <dir>
#   The folder to pull the newer version into, next to <dir>: `<dir>-latest`,
#   then `<dir>-latest2`, `-latest3`, so a second refusal never suggests
#   `./work-latest-latest`. A `-latest<N>` suffix on <dir> is stripped first.
source_sibling_dir() {
  local dir="${1%/}" base n=1 candidate
  base="$(printf '%s' "$dir" | sed -E 's/-latest[0-9]*$//')"
  candidate="$base-latest"
  while [[ -e "$candidate" ]]; do
    n=$((n + 1)); candidate="$base-latest$n"
    [[ $n -lt 50 ]] || break
  done
  printf '%s\n' "$candidate"
}

# source_stale_message <slug> <dir> <your-version> <live-version>
#   The refusal, on stderr, in the words the three interviewed collaborator
#   personas asked for. Three things are load-bearing and must not be trimmed:
#   it names who moved (someone else, not you), it states plainly that nothing
#   was uploaded and nothing local changed, and it hands over the exact next
#   command instead of describing one.
source_stale_message() {
  local sibling; sibling="$(source_sibling_dir "$2")"
  local slug="$1" dir="$2" mine="${3:-unknown}" live="${4:-unknown}"
  cat >&2 <<EOF
Someone published a newer version of $slug since this folder was pulled.
Your local changes are safe: nothing was uploaded and nothing in $dir was changed.
  your folder is based on version: $mine
  live version now:                $live
Next: pull the newer version alongside: ./scripts/account.sh pull $slug $sibling, bring your changes over, then publish again.
      (diff -ru -x .sharenow $sibling $dir shows exactly what to carry across.)
EOF
}

# source_response_is_stale <body-file-or-json>
#   True when a response body is the stale_source refusal. Reads the `code`
#   field, never the prose, so the check survives any wording change.
source_response_is_stale() {
  local input="$1" code
  if [[ -f "$input" ]]; then
    code=$("$JQ_BIN" -r '.code // empty' "$input" 2>/dev/null || true)
  else
    code=$(printf '%s' "$input" | "$JQ_BIN" -r '.code // empty' 2>/dev/null || true)
  fi
  [[ "$code" == "stale_source" ]]
}

# source_stale_versions <body-file-or-json> -> "<yourVersion>\t<liveVersion>"
#   The server sends both in `details` so the refusal can be rendered whole
#   without a second round trip.
source_stale_versions() {
  local input="$1"
  if [[ -f "$input" ]]; then
    "$JQ_BIN" -r '[(.details.yourVersion // ""), (.details.liveVersion // "")] | @tsv' "$input" 2>/dev/null || true
  else
    printf '%s' "$input" | "$JQ_BIN" -r '[(.details.yourVersion // ""), (.details.liveVersion // "")] | @tsv' 2>/dev/null || true
  fi
}
