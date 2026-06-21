#!/usr/bin/env bash
set -euo pipefail

# build-layouts.sh: generate every per-agent skill layout from the single
# canonical source at sharenow/. This keeps the duplicated copies byte-identical
# so they cannot drift.
#
# Usage:
#   scripts/build-layouts.sh            generate all layouts from canonical
#   scripts/build-layouts.sh --check    verify layouts match canonical (exit 1 on drift)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="$REPO_ROOT/sharenow"

# Generated full-skill layouts: each is a complete copy of the canonical skill dir.
SKILL_LAYOUTS=(
  "$REPO_ROOT/skills/sharenow"
  "$REPO_ROOT/hermes/productivity/sharenow"
)

# Plugin-manifest dirs that reference assets/logo.svg relative to themselves.
# The manifest JSON is authored directly (not generated); only the logo asset
# is synced here so the manifest's logo path resolves.
MANIFEST_DIRS=(
  "$REPO_ROOT/.codex-plugin"
  "$REPO_ROOT/.cursor-plugin"
)

die() { echo "error: $1" >&2; exit 1; }

[[ -d "$CANONICAL" ]] || die "canonical source not found: $CANONICAL"
[[ -f "$CANONICAL/SKILL.md" ]] || die "canonical SKILL.md missing: $CANONICAL/SKILL.md"

MODE="build"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ $# -gt 0 ]]; then
  die "unknown argument: $1 (use --check or no argument)"
fi

# Copy the canonical skill tree into a target dir, preserving executable bits.
sync_skill_layout() {
  local target="$1"
  rm -rf "$target"
  mkdir -p "$target"
  # -R preserves the tree; -p preserves mode bits. Portable across macOS/Linux.
  cp -Rp "$CANONICAL/." "$target/"
}

# Copy only the logo asset next to a manifest so its assets/logo.svg resolves.
sync_manifest_logo() {
  local dir="$1"
  mkdir -p "$dir/assets"
  cp -p "$CANONICAL/assets/logo.svg" "$dir/assets/logo.svg"
}

if [[ "$MODE" == "build" ]]; then
  for target in "${SKILL_LAYOUTS[@]+"${SKILL_LAYOUTS[@]}"}"; do
    sync_skill_layout "$target"
    echo "built: ${target#"$REPO_ROOT/"}"
  done
  for dir in "${MANIFEST_DIRS[@]+"${MANIFEST_DIRS[@]}"}"; do
    sync_manifest_logo "$dir"
    echo "logo:  ${dir#"$REPO_ROOT/"}/assets/logo.svg"
  done
  echo "ok: all layouts generated from canonical sharenow/"
  exit 0
fi

# --check mode: diff each generated layout against canonical; report all drift.
drift=0

for target in "${SKILL_LAYOUTS[@]+"${SKILL_LAYOUTS[@]}"}"; do
  rel="${target#"$REPO_ROOT/"}"
  if [[ ! -d "$target" ]]; then
    echo "drift: missing layout $rel (run scripts/build-layouts.sh)" >&2
    drift=1
    continue
  fi
  # Content drift. Exclude on-disk cruft so a stray .DS_Store does not read as drift.
  if ! diff -r -x '.DS_Store' "$CANONICAL" "$target" >/dev/null 2>&1; then
    echo "drift: $rel differs from canonical sharenow/" >&2
    diff -r -x '.DS_Store' "$CANONICAL" "$target" >&2 || true
    drift=1
  fi
  # Mode drift. diff -r compares content only, so check the executable bit on every
  # canonical script has the same state in the generated copy.
  while IFS= read -r -d '' src; do
    rel_file="${src#"$CANONICAL/"}"
    gen="$target/$rel_file"
    src_x=no; gen_x=no
    [[ -x "$src" ]] && src_x=yes
    [[ -x "$gen" ]] && gen_x=yes
    if [[ "$src_x" != "$gen_x" ]]; then
      echo "drift: $rel/$rel_file exec bit ($gen_x) differs from canonical ($src_x)" >&2
      drift=1
    fi
  done < <(find "$CANONICAL" -type f -name '*.sh' -print0)
done

for dir in "${MANIFEST_DIRS[@]+"${MANIFEST_DIRS[@]}"}"; do
  rel="${dir#"$REPO_ROOT/"}"
  if [[ ! -f "$dir/assets/logo.svg" ]]; then
    echo "drift: missing logo $rel/assets/logo.svg (run scripts/build-layouts.sh)" >&2
    drift=1
    continue
  fi
  if ! cmp -s "$CANONICAL/assets/logo.svg" "$dir/assets/logo.svg"; then
    echo "drift: $rel/assets/logo.svg differs from canonical logo" >&2
    drift=1
  fi
done

if [[ "$drift" -ne 0 ]]; then
  echo "FAIL: layouts are out of sync with canonical. Run scripts/build-layouts.sh" >&2
  exit 1
fi

echo "ok: all layouts in sync with canonical sharenow/"
exit 0
