#!/usr/bin/env bash
# tests/test_zero_link.sh — INV-zero-link scanner regression.
# Guards the bare-"cpp" token in config/forbidden-cpp.txt: an ordinary dot-prefixed
# file-extension literal (".cpp") must NOT false-positive, while real CPP-revealing
# tokens must still be caught. Mirrors the dot-extension exclusion already shipped in
# Skills .github/scripts/verify-skills.sh and ~/dev/_ops/eco/verify-zero-link.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ZL=(bash "$ROOT/bin/orchestrator.sh" zero-link)

pass() { printf 'test_zero_link: %s\n' "$1"; }
fail() { printf 'test_zero_link: FAIL %s\n' "$1" >&2; exit 1; }

# Asserts `zero-link <mode> <dir>` exits 0 (clean).
expect_clean() {
  local mode="$1" dir="$2" label="$3"
  if "${ZL[@]}" "$mode" "$dir" >/dev/null 2>&1; then pass "$label"; else fail "$label (expected clean, got violation)"; fi
}

# Asserts `zero-link <mode> <dir>` exits non-zero (violation).
expect_violation() {
  local mode="$1" dir="$2" label="$3"
  if "${ZL[@]}" "$mode" "$dir" >/dev/null 2>&1; then fail "$label (expected violation, got clean)"; else pass "$label"; fi
}

# 1) The fix: a .cpp / .hpp file-extension literal in an ld/global payload is NOT a leak.
D="$TMP/dotext"; mkdir -p "$D"
printf 'ext = ".cpp"\nheader = ".hpp"\nprint("review", ext, header)\n' > "$D/generate_review.py"
printf '# handles foo.cpp and bar.hpp fixtures\n' > "$D/README.md"
expect_clean global "$D" "dot-prefixed .cpp/.hpp extension literals do not false-positive (global)"

# 2) Real CPP-revealing tokens are still caught in a global payload.
for tok in "card-platform-product" "cpp-stuff" "affirm/src"; do
  D="$TMP/leak_$RANDOM"; mkdir -p "$D"; printf 'ref: %s\n' "$tok" > "$D/note.txt"
  expect_violation global "$D" "global still catches real token: $tok"
done

# bare "cpp" as a whole word (space/paren/hyphen delimited) is still caught.
D="$TMP/bareword"; mkdir -p "$D"; printf 'the cpp team owns this\nsee (cpp) and affirm-cpp\n' > "$D/note.txt"
expect_violation global "$D" "global still catches bare 'cpp' word"

# 3) Defense in depth: cpp-mode (ld tokens in a cpp payload) unchanged.
D="$TMP/ldleak"; mkdir -p "$D"; printf 'from KleinPerkins/skills import x\n# ecosystem-orchestrator\n' > "$D/x.py"
expect_violation cpp "$D" "cpp mode still catches ld tokens"

D="$TMP/cleanpay"; mkdir -p "$D"; printf 'name: foo\ndescription: a generic capability\n' > "$D/SKILL.md"
expect_clean cpp "$D" "cpp mode passes a clean ld-agnostic payload"

echo "test_zero_link: OK"
