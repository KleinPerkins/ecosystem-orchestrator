#!/usr/bin/env bash
# tests/test_payload_evidence_exclusion.sh — regression for the cpp-vendor EVIDENCE.md exclusion.
#
# An `EVIDENCE.md` build/acceptance ledger (at any depth) is the master's OWN development provenance —
# how the capability was built and verified — not vendorable runtime payload. Like tests/, it
# legitimately embeds ld provenance (e.g. save-game/EVIDENCE.md names KleinPerkins/skills in its
# build-environment note) that would otherwise trip `orch_zero_link cpp` and ABORT the whole
# registry-wide cpp-sync. This locks in the payload_shared_list exclusion, the single point that
# payload_content_digest + consistency.sh (shared_list) + vendor emit (build_payload) all share.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# payload_shared_list has no orch_* dependency; source only the pure-function lib.
# shellcheck source=/dev/null
. "$ROOT/lib/payload.sh"

pass() { printf 'test_payload_evidence_exclusion: %s\n' "$1"; }
fail() { printf 'test_payload_evidence_exclusion: FAIL %s\n' "$1" >&2; exit 1; }

git_master() {   # git_master <dir>  — init a tracked git master so ls-files (not find) is exercised
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.email=t@t.invalid -c user.name=t commit -qm init
}

# --- Fixture 1: save-game-shaped master — clean SKILL.md + an EVIDENCE.md build ledger (top-level
# AND nested) whose body carries the exact ld tokens that trip zero-link. -------------------------
MASTER="$TMP/master"
mkdir -p "$MASTER/sub"
printf '# demo\nA generic, ld-agnostic capability.\n' > "$MASTER/SKILL.md"
printf 'kind: skill\nowner: KleinPerkins\n' > "$MASTER/meta.yml"
printf '# Evidence ledger\nBuilt from a worktree of `KleinPerkins/skills`.\n' > "$MASTER/EVIDENCE.md"
printf 'ref: https://github.com/KleinPerkins/skills/extra\n' > "$MASTER/sub/EVIDENCE.md"
git_master "$MASTER"

# 1a) payload_shared_list keeps SKILL.md and drops every EVIDENCE.md (any depth).
LIST="$(payload_shared_list "$MASTER")"
printf '%s\n' "$LIST" | grep -qx 'SKILL.md' || fail "SKILL.md should be listed"
if printf '%s\n' "$LIST" | grep -Eq '(^|/)EVIDENCE\.md$'; then
  fail "EVIDENCE.md files must be excluded (got: $(printf '%s' "$LIST" | tr '\n' ' '))"
fi
pass "payload_shared_list drops top-level and nested EVIDENCE.md but keeps SKILL.md"

# 1b) A payload built exactly how build_payload builds it (payload_shared_list | tar) is zero-link
# clean under cpp mode, even though the master's EVIDENCE.md carry ld tokens. This is save-game.
DST="$TMP/payload"; mkdir -p "$DST"
( cd "$MASTER" && payload_shared_list "$MASTER" | tar -cf - -T - ) | ( cd "$DST" && tar -xf - )
[ -f "$DST/SKILL.md" ] || fail "built payload should contain SKILL.md"
[ ! -e "$DST/EVIDENCE.md" ] || fail "built payload must not contain a top-level EVIDENCE.md"
[ ! -e "$DST/sub/EVIDENCE.md" ] || fail "built payload must not contain a nested EVIDENCE.md"
if bash "$ROOT/bin/orchestrator.sh" zero-link cpp "$DST" >/dev/null 2>&1; then
  pass "vendored payload (EVIDENCE.md excluded) passes zero-link cpp (save-game no longer trips)"
else
  fail "vendored payload should pass zero-link cpp after EVIDENCE.md exclusion"
fi

# 1c) The content digest now IGNORES EVIDENCE.md: a master's payload_content_digest is IDENTICAL
# whether or not it carries an EVIDENCE.md ledger (same non-ledger bytes -> same fingerprint).
MASTER_NOEV="$TMP/master_noev"; mkdir -p "$MASTER_NOEV"
printf '# demo\nA generic, ld-agnostic capability.\n' > "$MASTER_NOEV/SKILL.md"
printf 'kind: skill\nowner: KleinPerkins\n' > "$MASTER_NOEV/meta.yml"
git_master "$MASTER_NOEV"
[ "$(payload_content_digest "$MASTER")" = "$(payload_content_digest "$MASTER_NOEV")" ] \
  || fail "content digest must be identical with/without EVIDENCE.md (ledger excluded from fingerprint)"
pass "content digest ignores EVIDENCE.md (identical fingerprint with and without the ledger)"

# --- Fixture 2: look-alike guard — NON-ledger paths that merely contain the substring 'EVIDENCE'
# (EVIDENCE-notes.md, evidence/data.txt) must still be INCLUDED. -----------------------------------
MASTER2="$TMP/master2"; mkdir -p "$MASTER2/evidence"
printf '# m2\n' > "$MASTER2/SKILL.md"
printf 'keep me\n' > "$MASTER2/evidence/data.txt"
printf 'keep me too\n' > "$MASTER2/EVIDENCE-notes.md"
git_master "$MASTER2"
LIST2="$(payload_shared_list "$MASTER2")"
printf '%s\n' "$LIST2" | grep -qx 'evidence/data.txt' || fail "evidence/ dir must NOT be excluded"
printf '%s\n' "$LIST2" | grep -qx 'EVIDENCE-notes.md' || fail "EVIDENCE-notes.md must NOT be excluded"
pass "look-alike paths (evidence/, EVIDENCE-notes.md) are preserved"

echo "test_payload_evidence_exclusion: OK"
