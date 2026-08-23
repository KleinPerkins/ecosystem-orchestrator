#!/usr/bin/env bash
# tests/test_payload_tests_exclusion.sh — regression for the cpp-vendor tests/ exclusion.
#
# A master's OWN `tests/` harness (at any depth) must NOT be vendored into a cpp payload: such
# fixtures routinely embed ld provenance (e.g. swarm/tests/test_bootstrap.sh's literal
# KleinPerkins/skills git URLs) that would otherwise trip `orch_zero_link cpp` and ABORT the whole
# registry-wide cpp-sync. This locks in the payload_shared_list exclusion, which is the single point
# that payload_content_digest + consistency.sh (shared_list) + vendor emit (build_payload) all share.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# payload_shared_list has no orch_* dependency; source only the pure-function lib.
# shellcheck source=/dev/null
. "$ROOT/lib/payload.sh"

pass() { printf 'test_payload_tests_exclusion: %s\n' "$1"; }
fail() { printf 'test_payload_tests_exclusion: FAIL %s\n' "$1" >&2; exit 1; }

git_master() {   # git_master <dir>  — init a tracked git master so ls-files (not find) is exercised
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.email=t@t.invalid -c user.name=t commit -qm init
}

# --- Fixture 1: swarm-shaped master — clean SKILL.md + a tests/ harness (top-level AND nested)
# whose fixtures carry the exact ld tokens that trip zero-link. ------------------------------------
MASTER="$TMP/master"
mkdir -p "$MASTER/tests" "$MASTER/sub/tests"
printf '# demo\nA generic, ld-agnostic capability.\n' > "$MASTER/SKILL.md"
printf 'kind: skill\nowner: KleinPerkins\n' > "$MASTER/meta.yml"
printf 'remote="git@github.com:KleinPerkins/skills"\n' > "$MASTER/tests/test_bootstrap.sh"
printf 'ref: https://github.com/KleinPerkins/skills/extra\n' > "$MASTER/sub/tests/fixture.txt"
git_master "$MASTER"

# 1a) payload_shared_list keeps SKILL.md and drops every tests/ path (any depth).
LIST="$(payload_shared_list "$MASTER")"
printf '%s\n' "$LIST" | grep -qx 'SKILL.md' || fail "SKILL.md should be listed"
if printf '%s\n' "$LIST" | grep -Eq '(^|/)tests/'; then
  fail "tests/ files must be excluded (got: $(printf '%s' "$LIST" | tr '\n' ' '))"
fi
pass "payload_shared_list drops top-level and nested tests/ but keeps SKILL.md"

# 1b) A payload built exactly how build_payload builds it (payload_shared_list | tar) is zero-link
# clean under cpp mode, even though the master's tests/ carry ld tokens. This is the swarm scenario.
DST="$TMP/payload"; mkdir -p "$DST"
( cd "$MASTER" && payload_shared_list "$MASTER" | tar -cf - -T - ) | ( cd "$DST" && tar -xf - )
[ -f "$DST/SKILL.md" ] || fail "built payload should contain SKILL.md"
[ ! -e "$DST/tests" ] || fail "built payload must not contain a top-level tests/ dir"
[ ! -e "$DST/sub/tests" ] || fail "built payload must not contain a nested tests/ dir"
if bash "$ROOT/bin/orchestrator.sh" zero-link cpp "$DST" >/dev/null 2>&1; then
  pass "vendored payload (tests/ excluded) passes zero-link cpp (swarm no longer trips)"
else
  fail "vendored payload should pass zero-link cpp after tests/ exclusion"
fi

# 1c) The content digest now IGNORES tests/: a master's payload_content_digest is IDENTICAL whether
# or not it carries a tests/ harness (same non-tests bytes -> same fingerprint). This is exactly why
# a tests-carrying skill's approved_digest legitimately moves ONCE when this ships — the fingerprint
# stops counting the tests/ bytes it used to include. (Harmless for flavor-1: no approved_digest gate.)
MASTER_NOTESTS="$TMP/master_notests"; mkdir -p "$MASTER_NOTESTS"
printf '# demo\nA generic, ld-agnostic capability.\n' > "$MASTER_NOTESTS/SKILL.md"
printf 'kind: skill\nowner: KleinPerkins\n' > "$MASTER_NOTESTS/meta.yml"
git_master "$MASTER_NOTESTS"
[ "$(payload_content_digest "$MASTER")" = "$(payload_content_digest "$MASTER_NOTESTS")" ] \
  || fail "content digest must be identical with/without tests/ (tests/ excluded from the fingerprint)"
pass "content digest ignores tests/ (identical fingerprint with and without the harness)"

# --- Fixture 2: look-alike guard — a NON-tests path that merely contains the substring 'tests'
# (contests/, tests-helper.md) must still be INCLUDED. --------------------------------------------
MASTER2="$TMP/master2"; mkdir -p "$MASTER2/contests"
printf '# m2\n' > "$MASTER2/SKILL.md"
printf 'keep me\n' > "$MASTER2/contests/data.txt"
printf 'keep me too\n' > "$MASTER2/tests-helper.md"
git_master "$MASTER2"
LIST2="$(payload_shared_list "$MASTER2")"
printf '%s\n' "$LIST2" | grep -qx 'contests/data.txt' || fail "contests/ must NOT be excluded"
printf '%s\n' "$LIST2" | grep -qx 'tests-helper.md' || fail "tests-helper.md must NOT be excluded"
pass "look-alike paths (contests/, tests-helper.md) are preserved"

echo "test_payload_tests_exclusion: OK"
