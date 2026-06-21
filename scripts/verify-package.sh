#!/usr/bin/env bash
set -euo pipefail

# verify-package.sh: the full correctness gate for the sharenow skill repository.
# Proves every documented path resolves, all layouts are in sync with canonical,
# no brand violations exist anywhere, scripts lint clean and are executable, and
# the install command is consistent across the README and SKILL.md.
#
# Exit 0 = PASS (ready to ship). Exit 1 = at least one check failed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FAILURES=0
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ok: $1"; }

INSTALL_CMD="npx skills add AsyncFuncAI/sharenow --skill sharenow"

# --- 1. Required paths exist ------------------------------------------------
echo "[1] required paths"
REQUIRED_PATHS=(
  "README.md"
  "AGENTS.md"
  "LICENSE"
  ".gitignore"
  "sharenow/SKILL.md"
  "sharenow/AGENTS.md"
  "sharenow/assets/logo.svg"
  "sharenow/scripts/publish.sh"
  "sharenow/scripts/drive.sh"
  "sharenow/scripts/account.sh"
  "skills/sharenow/SKILL.md"
  "skills/sharenow/AGENTS.md"
  "skills/sharenow/scripts/publish.sh"
  "hermes/productivity/sharenow/SKILL.md"
  "hermes/productivity/sharenow/AGENTS.md"
  "hermes/productivity/sharenow/scripts/publish.sh"
  ".codex-plugin/plugin.json"
  ".cursor-plugin/plugin.json"
  "scripts/build-layouts.sh"
  "scripts/verify-package.sh"
)
for p in "${REQUIRED_PATHS[@]+"${REQUIRED_PATHS[@]}"}"; do
  if [[ -e "$p" ]]; then pass "$p"; else fail "missing $p"; fi
done

# --- 2. Layouts in sync with canonical --------------------------------------
echo "[2] layout sync"
if scripts/build-layouts.sh --check >/dev/null 2>&1; then
  pass "all layouts match canonical (build-layouts.sh --check)"
else
  fail "layouts drifted from canonical; run scripts/build-layouts.sh"
fi

# --- 3. Scripts parse (bash -n) ---------------------------------------------
echo "[3] script syntax"
while IFS= read -r -d '' sh; do
  if bash -n "$sh" 2>/dev/null; then pass "bash -n ${sh#./}"; else fail "bash -n failed: ${sh#./}"; fi
done < <(find . -path ./.git -prune -o -name '*.sh' -type f -print0)

# --- 4. Executable bits on skill scripts ------------------------------------
echo "[4] executable bits"
while IFS= read -r -d '' sh; do
  if [[ -x "$sh" ]]; then pass "+x ${sh#./}"; else fail "not executable: ${sh#./}"; fi
done < <(find . -path ./.git -prune -o -path '*/scripts/*.sh' -type f -print0)

# --- 5. Brand sweep: no em-dash, the other product's name, or dev placeholders
echo "[5] brand compliance (whole tree)"
# Patterns are assembled from fragments so this verifier never contains the
# literal forbidden strings (otherwise the sweep would flag itself).
OTHER="here""dot""now"                                   # the other product's name family
PAT_OTHER="${OTHER/dot/\\.}|${OTHER/dot/}"               # case-insensitive grep below covers all casings
EX="example"; ORG="sharenow-""org"; BASE="your-""sharenow-""base-url"
PAT_PLACEHOLDER="sharenow\\.${EX}|<${ORG}>|${BASE}"

# Shared excludes: never scan .git or build cruft / dependency trees.
EXCL=(--exclude-dir=.git --exclude-dir=node_modules --exclude=.DS_Store)

if grep -RIl $'\xe2\x80\x94' . "${EXCL[@]}" >/dev/null 2>&1; then
  fail "em-dash (U+2014) found in: $(grep -RIl $'\xe2\x80\x94' . "${EXCL[@]}" | tr '\n' ' ')"
else
  pass "no em-dash (U+2014)"
fi
# Case-insensitive so every casing of the other-product name family matches.
if grep -RIliE "$PAT_OTHER" . "${EXCL[@]}" >/dev/null 2>&1; then
  fail "other-product reference found in: $(grep -RIliE "$PAT_OTHER" . "${EXCL[@]}" | tr '\n' ' ')"
else
  pass "no other-product name references"
fi
if grep -RIlE "$PAT_PLACEHOLDER" . "${EXCL[@]}" >/dev/null 2>&1; then
  fail "dev placeholder found in: $(grep -RIlE "$PAT_PLACEHOLDER" . "${EXCL[@]}" | tr '\n' ' ')"
else
  pass "no dev placeholders"
fi

# --- 6. Plugin manifests are valid JSON -------------------------------------
echo "[6] manifest JSON"
for m in .codex-plugin/plugin.json .cursor-plugin/plugin.json; do
  if jq . "$m" >/dev/null 2>&1; then pass "valid JSON: $m"; else fail "invalid JSON: $m"; fi
done

# --- 7. Install command consistency -----------------------------------------
echo "[7] install command consistency"
for f in README.md sharenow/SKILL.md; do
  if grep -qF "$INSTALL_CMD" "$f"; then pass "install command present in $f"; else fail "install command missing in $f"; fi
done

# --- 8. Cross-manifest metadata consistency ---------------------------------
# Descriptions may differ by design (Codex carries detail in interface.longDescription),
# but identity fields must agree between the two manifests.
echo "[8] cross-manifest consistency"
for field in name version homepage repository license; do
  cv=$(jq -r --arg f "$field" '.[$f] // empty' .codex-plugin/plugin.json)
  uv=$(jq -r --arg f "$field" '.[$f] // empty' .cursor-plugin/plugin.json)
  if [[ -n "$cv" && "$cv" == "$uv" ]]; then
    pass "$field matches across manifests ($cv)"
  else
    fail "$field differs across manifests (codex='$cv' cursor='$uv')"
  fi
done

# --- Summary ----------------------------------------------------------------
echo ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo "PASS: sharenow skill repository is consistent and ready."
  exit 0
fi
echo "FAILED: $FAILURES check(s) did not pass."
exit 1
