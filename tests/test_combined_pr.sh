#!/usr/bin/env bash
# tests/test_combined_pr.sh — ADR 0002 regression: one orchestrator run = ONE cpp PR.
#
# Reproduces the 2026-10-20 incidents in a hermetic sandbox (throwaway skills repo, fake cpp with a
# bare origin, stub `gh` on PATH):
#   * cross-capability dependency (cpp #1054/#1055: swarm landed before subagent-orchestration) —
#     two changed capabilities must ship in ONE commit / ONE PR;
#   * removal vs manifest (cpp #1061/#1062) — a payload removal and its manifest row ship together.
# Also proves the real cpp-sync preflight (lockkit + capability verifier + reconcile + flavor-2 digest)
# still gates cpp-sync AND per-id vendor, one bad capability stops the whole PR, a RED integrity gate
# refuses the push, an open orchestrator PR blocks a second one, and an in-sync run is a no-op. The
# execute path runs end to end against the sandbox only (push to the bare origin, stub gh).
set -euo pipefail
# A BASH_ENV startup file (e.g. a Homebrew PATH helper) would re-prepend the real `gh` ahead of the
# stub in every child bash.
unset BASH_ENV

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SKILLS="$TMP/skills"; GLOBAL="$SKILLS/global"; MCP="$TMP/mcp"
CPP="$TMP/cpp"; ORIGIN="$TMP/origin.git"
CONFIG="$TMP/relationship.yml"; REGISTRY="$TMP/registry.yml"; LKCFG="$TMP/lockkit.yml"
FAKEBIN="$TMP/bin"; GHLOG="$TMP/gh.log"; GHOPEN="$TMP/gh-open-prs"; GHFAIL="$TMP/gh-list-fails"
VERIFY_MARK="$TMP/verify-skills.ran"
MANIFEST_REL="quiver/tooling/eco-capability-sync/eco-capability-manifest.yml"
passes=0

pass() { printf '  PASS %s\n' "$1"; passes=$((passes+1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "${2:-assertion failed}" >&2; exit 1; }

# --- stub gh: logs one line per call; `pr list` prints $GHOPEN (or fails when $GHFAIL exists) -------
mkdir -p "$FAKEBIN" "$MCP"
cat > "$FAKEBIN/gh" <<EOF
#!/usr/bin/env bash
{ printf '%s' "\$*" | tr '\n' ' '; printf '\n'; } >> "$GHLOG"
case "\${1:-} \${2:-}" in
  "pr list")   [ -f "$GHFAIL" ] && exit 1; cat "$GHOPEN" 2>/dev/null; exit 0 ;;
  "pr create") echo "https://example.invalid/cpp/pull/\$(grep -c '^pr create' "$GHLOG")"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/gh"
: > "$GHLOG"; : > "$GHOPEN"

# --- skills master repo with the real eco-lock writer + a capability verifier that leaves a mark ---
emit_master() {   # emit_master <id> <payload-version> [flavor]
  local d="$GLOBAL/skills/$1"
  mkdir -p "$d"
  cat > "$d/meta.yml" <<EOF
schema: kp-capability/v1
id: $1
kind: skill
flavor: ${3:-1}
scope: global
owner: KleinPerkins
install: install.sh
post_mgmt: none
expose: [cursor]
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/install.sh"; chmod +x "$d/install.sh"
  printf '# %s\n\nFixture payload %s.\n' "$1" "$2" > "$d/SKILL.md"
}
relock() { ( cd "$SKILLS" && bash .github/scripts/eco-lock.sh write >/dev/null ); }

git init -q "$SKILLS"
git -C "$SKILLS" config user.name tester; git -C "$SKILLS" config user.email tester@example.invalid
mkdir -p "$SKILLS/.github/scripts"
cp "$ROOT/templates/eco-lock/eco-lock.sh" "$SKILLS/.github/scripts/eco-lock.sh"
chmod +x "$SKILLS/.github/scripts/eco-lock.sh"
printf '#!/usr/bin/env bash\n: > "%s"\nexit 0\n' "$VERIFY_MARK" > "$SKILLS/.github/scripts/verify-skills.sh"
chmod +x "$SKILLS/.github/scripts/verify-skills.sh"
for id in alpha beta gamma; do emit_master "$id" v1; done
relock
git -C "$SKILLS" add -A; git -C "$SKILLS" commit -qm "fixture skills"

cat > "$LKCFG" <<EOF
schema: lockkit/v1
master: templates/eco-lock/eco-lock.sh
targets:
  - name: skills
    root: $SKILLS
    script: .github/scripts/eco-lock.sh
    lock: .eco-registry.lock
    verify: .github/scripts/verify-skills.sh
EOF
printf 'schema: eco-registry/v1\nitems:\n' > "$REGISTRY"
cat > "$CONFIG" <<EOF
schema: orchestrator-relationship/v1
source_skills_local: $SKILLS
source_skills_global: $GLOBAL
source_skills_repo: fixture
source_mcp_local: $MCP
source_mcp_repo: fixture
cpp_repo: fixture/cpp
cpp_clone_url: $ORIGIN
cpp_default_branch: main
cpp_quiver_path: quiver
cpp_pr_branch_prefix: orchestrator/vendor
cpp_merge_mode: auto-squash
cpp_forbidden_paths: _ops/ .github/
enabled_kinds: skill mcp rule sub-agent tool
cpp_sync_denylist: eco-capability-sync
ld_cpp_worktree: $CPP
work_clone_dir: $TMP/work
backup_dir: $TMP/backups
EOF

# --- fake cpp: main with a cpp-native skill, pushed to a bare origin ----------------------------
git init -q --bare "$ORIGIN"
git init -q "$CPP"
git -C "$CPP" checkout -q -b main
git -C "$CPP" config user.name tester; git -C "$CPP" config user.email tester@example.invalid
printf 'verify:\n\t@true\n' > "$CPP/Makefile"
mkdir -p "$CPP/quiver/skills/cpp-native"
printf '# cpp native\n' > "$CPP/quiver/skills/cpp-native/SKILL.md"
git -C "$CPP" add -A; git -C "$CPP" commit -qm "fixture cpp base"
git -C "$CPP" remote add origin "$ORIGIN"
git -C "$CPP" push -q origin main

orch() {
  ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" LOCKKIT_CONFIG="$LKCFG" PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/orchestrator.sh" "$@"
}
branch_now() { git -C "$CPP" branch --show-current; }
ahead() { git -C "$CPP" rev-list --count main..HEAD; }
changes() { git -C "$CPP" diff --name-status main HEAD; }
manifest_at() { git -C "$CPP" show "$1:$MANIFEST_REL"; }
items_of() { awk '/^items:/ {f=1; next} f && /^[[:space:]]*-[[:space:]]*id:/ {sub(/.*id:[[:space:]]*/, ""); print}'; }
owns() { awk -v want="$1" '/^owned_ids:/ {sub(/^owned_ids:[[:space:]]*\[/, ""); sub(/\].*$/, ""); gsub(/[[:space:]]/, ""); n=split($0, a, ","); for (i=1; i<=n; i++) if (a[i] == want) found=1} END {exit found ? 0 : 1}'; }
row_of() { awk -v want="$1" '/^[[:space:]]*-[[:space:]]*id:/ {cur=$0; sub(/.*id:[[:space:]]*/, "", cur)} cur == want {print}'; }
pushed_branches() { git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/orchestrator; }
pr_creates() { grep -c '^pr create' "$GHLOG" || true; }
land() {   # simulate cpp squash-merging the pending branch: fast-forward main (+ origin), drop the branch
  local b; b="$(branch_now)"
  git -C "$CPP" branch -f main HEAD >/dev/null; git -C "$CPP" checkout -q main
  [ "$b" = main ] || git -C "$CPP" branch -qD "$b"
  git -C "$CPP" push -q origin main
  local r; for r in $(pushed_branches); do git -C "$ORIGIN" update-ref -d "refs/heads/$r"; done
}
discard() {   # drop a dry-run / refused branch and any staged leftovers
  local b; b="$(branch_now)"
  git -C "$CPP" checkout -q -f main; git -C "$CPP" clean -qfd
  [ "$b" = main ] || git -C "$CPP" branch -qD "$b"
}
has_change() { printf '%s\n' "$1" | grep -qxF "$(printf '%s\t%s' "$2" "$3")"; }

# --- 0. Bootstrap: first sync vendors alpha, beta, gamma + manifest as one change ------------------
for id in alpha beta gamma; do orch enroll "$id" -- "fixture enroll" >/dev/null 2>&1; done
orch cpp-sync --cpp-dir "$CPP" >/dev/null 2>&1 || fail "bootstrap sync" "dry-run failed"
[ "$(ahead)" = 1 ] || fail "bootstrap sync" "expected one commit"
land
[ "$(manifest_at main | items_of | paste -sd' ' -)" = "alpha beta gamma" ] || fail "bootstrap manifest" "items mismatch"
pass "bootstrap: first sync lands three payloads and the manifest in one commit"

# --- 1. Incident regression (dry-run): two dependent updates + a removal = ONE commit on ONE branch -
emit_master alpha v2                      # like swarm ...
emit_master beta v2                       # ... and the subagent-orchestration change it depends on
orch exclude gamma -- "fixture retire (like algorithmic-art)" >/dev/null 2>&1
rm -f "$VERIFY_MARK"; : > "$GHLOG"
out="$(orch cpp-sync --cpp-dir "$CPP" 2>&1)" || fail "sync dry-run" "$out"
[ -f "$VERIFY_MARK" ] || fail "verify-skills gate" "cpp-sync did not run the capability verifier"
case "$(branch_now)" in orchestrator/vendor/sync-*) ;; *) fail "sync branch name" "$(branch_now)" ;; esac
[ "$(ahead)" = 1 ] || fail "sync dry-run" "expected exactly one commit, got $(ahead)"
c="$(changes)"
has_change "$c" M quiver/skills/alpha/SKILL.md || fail "sync dry-run" "alpha update missing: $c"
has_change "$c" M quiver/skills/beta/SKILL.md  || fail "sync dry-run" "beta update missing: $c"
has_change "$c" D quiver/skills/gamma/SKILL.md || fail "sync dry-run" "gamma removal missing: $c"
has_change "$c" M "$MANIFEST_REL"              || fail "sync dry-run" "manifest update missing: $c"
[ "$(manifest_at HEAD | items_of | paste -sd' ' -)" = "alpha beta" ] || fail "sync manifest" "items should be alpha beta"
manifest_at HEAD | owns gamma || fail "sync manifest" "removed gamma lost its ownership tombstone"
manifest_at HEAD | owns cpp-native && fail "sync manifest" "cpp-native id was claimed"
[ -f "$CPP/quiver/skills/cpp-native/SKILL.md" ] || fail "sync dry-run" "cpp-native payload was touched"
grep -q 'ONE combined cpp PR planned' <<<"$out" || fail "sync dry-run" "plan line missing"
[ ! -s "$GHLOG" ] || fail "sync dry-run" "dry-run called gh: $(cat "$GHLOG")"
[ -z "$(pushed_branches)" ] || fail "sync dry-run" "dry-run pushed a branch"
discard
pass "dry-run: both updates, the removal, and the manifest are ONE commit; nothing pushed"

# --- 2. Execute path (sandbox only): exactly one PR, one auto-merge request, one pushed branch ------
: > "$GHLOG"; : > "$GHOPEN"
out="$(orch cpp-sync --execute --cpp-dir "$CPP" 2>&1)" || fail "sync execute" "$out"
[ "$(pr_creates)" = 1 ] || fail "sync execute" "expected one 'gh pr create', got $(pr_creates)"
[ "$(grep -c '^pr merge' "$GHLOG")" = 1 ] || fail "sync execute" "expected one 'gh pr merge'"
grep -q '^pr merge .*--auto --squash' "$GHLOG" || fail "sync execute" "auto-merge was not requested"
grep '^pr create' "$GHLOG" | grep -qF 'orchestrator sync (vendor: alpha, beta; remove: gamma)' \
  || fail "sync execute" "PR title does not name every change: $(grep '^pr create' "$GHLOG")"
pb="$(pushed_branches)"
[ "$(printf '%s\n' "$pb" | grep -c .)" = 1 ] || fail "sync execute" "expected one pushed branch, got: $pb"
[ "$(git -C "$ORIGIN" rev-list --count "main..$pb")" = 1 ] || fail "sync execute" "pushed branch is not one commit"
[ "$(git -C "$ORIGIN" diff --name-only main "$pb" | grep -c .)" = "$(changes | grep -c .)" ] \
  || fail "sync execute" "pushed commit differs from the local change"
land
pass "execute (sandbox): one 'gh pr create', one auto-merge request, one pushed single-commit branch"

# --- 3. Idempotency: an in-sync run is a no-op — no commit, no gh call, no PR ----------------------
: > "$GHLOG"
out="$(orch cpp-sync --execute --cpp-dir "$CPP" 2>&1)" || fail "in-sync execute" "$out"
grep -q 'no changes — already in sync' <<<"$out" || fail "in-sync execute" "no-op message missing"
[ "$(ahead)" = 0 ] || fail "in-sync execute" "created a commit"
[ ! -s "$GHLOG" ] || fail "in-sync execute" "called gh: $(cat "$GHLOG")"
discard
pass "in-sync run is a no-op: no commit, no gh call, no PR"

# --- 4. One orchestrator PR in flight: an open one blocks a second; unreadable PR list fails closed -
emit_master alpha v3
printf '#77 orchestrator/vendor/sync-20261020-000000 https://example.invalid/cpp/pull/77\n' > "$GHOPEN"
if out="$(orch cpp-sync --execute --cpp-dir "$CPP" 2>&1)"; then fail "open-PR guard" "execute should refuse"; fi
grep -q 'already has an open orchestrator PR' <<<"$out" || fail "open-PR guard" "$out"
[ "$(pr_creates)" = 0 ] || fail "open-PR guard" "opened a PR anyway"
[ -z "$(pushed_branches)" ] || fail "open-PR guard" "pushed a branch anyway"
discard
: > "$GHOPEN"; touch "$GHFAIL"
if out="$(orch cpp-sync --execute --cpp-dir "$CPP" 2>&1)"; then fail "open-PR guard" "unreadable PR list should refuse"; fi
grep -q 'could not list open cpp PRs' <<<"$out" || fail "open-PR guard" "$out"
[ "$(pr_creates)" = 0 ] && [ -z "$(pushed_branches)" ] || fail "open-PR guard" "pushed despite unreadable PR list"
rm -f "$GHFAIL"; discard
pass "an open orchestrator PR blocks a second one; an unreadable PR list fails closed"

# --- 5. Fail closed: one bad capability or a RED gate stops the WHOLE PR --------------------------
printf '\nSource: KleinPerkins/skills\n' >> "$GLOBAL/skills/beta/SKILL.md"     # zero-link violation
if out="$(orch cpp-sync --execute --cpp-dir "$CPP" 2>&1)"; then fail "fail closed" "zero-link violation should abort"; fi
grep -q 'beta: payload tripped zero-link' <<<"$out" || fail "fail closed" "$out"
[ "$(pr_creates)" = 0 ] && [ -z "$(pushed_branches)" ] || fail "fail closed" "alpha shipped without beta"
[ "$(ahead)" = 0 ] || fail "fail closed" "a partial change was committed"
emit_master beta v2; discard
pass "one capability tripping zero-link stops the whole PR (the other change does not ship alone)"

printf 'verify:\n\t@exit 1\n' > "$CPP/Makefile"; git -C "$CPP" commit -qam "fixture: red integrity"
if out="$(orch cpp-sync --execute --cpp-dir "$CPP" 2>&1)"; then fail "red gate" "RED integrity should refuse"; fi
grep -q 'gate RED' <<<"$out" || fail "red gate" "$out"
[ "$(pr_creates)" = 0 ] && [ -z "$(pushed_branches)" ] || fail "red gate" "pushed despite RED integrity"
discard
printf 'verify:\n\t@true\n' > "$CPP/Makefile"; git -C "$CPP" commit -qam "fixture: green integrity"
git -C "$CPP" push -q origin main
pass "a RED cpp integrity gate on the combined tree refuses the push"

emit_master epsilon v1 2; relock
orch enroll epsilon -- "fixture flavor-2" >/dev/null 2>&1
if out="$(orch cpp-sync --cpp-dir "$CPP" 2>&1)"; then fail "supply-chain" "unapproved flavor-2 should abort cpp-sync"; fi
grep -q 'epsilon(supply-chain)' <<<"$out" || fail "supply-chain" "$out"
[ "$(branch_now)" = main ] || fail "supply-chain" "cpp-sync built a change before the gate"
if out="$(orch vendor --cpp-dir "$CPP" epsilon 2>&1)"; then fail "supply-chain" "per-id vendor bypassed the digest gate"; fi
grep -q 'preflight refused epsilon' <<<"$out" || fail "supply-chain" "$out"
[ "$(branch_now)" = main ] || fail "supply-chain" "per-id vendor built a change before the gate"
orch approve epsilon >/dev/null 2>&1
pass "flavor-2 digest gate still blocks cpp-sync and now also blocks per-id vendor"

# --- 6. Per-id vendor: a brand-new capability ships its payload AND its manifest row together -----
emit_master delta v1; relock
orch enroll delta -- "fixture brand-new (like save-game)" >/dev/null 2>&1
out="$(orch vendor --cpp-dir "$CPP" delta 2>&1)" || fail "per-id new" "$out"
case "$(branch_now)" in orchestrator/vendor/delta-*) ;; *) fail "per-id branch name" "$(branch_now)" ;; esac
[ "$(ahead)" = 1 ] || fail "per-id new" "expected one commit"
c="$(changes)"
has_change "$c" A quiver/skills/delta/SKILL.md || fail "per-id new" "payload missing: $c"
has_change "$c" M "$MANIFEST_REL"              || fail "per-id new" "manifest row missing: $c"
printf '%s\n' "$c" | grep -q 'quiver/skills/alpha/' && fail "per-id new" "pending alpha change leaked into a per-id PR"
[ "$(manifest_at HEAD | items_of | paste -sd' ' -)" = "alpha beta delta" ] || fail "per-id new" "items mismatch"
for id in alpha beta; do
  [ "$(manifest_at HEAD | row_of "$id")" = "$(manifest_at main | row_of "$id")" ] || fail "per-id new" "$id row changed"
done
grep -q 'ONE combined cpp PR planned' <<<"$out" || fail "per-id new" "plan line missing"
discard
: > "$GHLOG"
out="$(orch vendor --execute --cpp-dir "$CPP" delta 2>&1)" || fail "per-id execute" "$out"
[ "$(pr_creates)" = 1 ] && [ "$(grep -c '^pr merge .*--auto --squash' "$GHLOG")" = 1 ] || fail "per-id execute" "$(cat "$GHLOG")"
case "$(pushed_branches)" in orchestrator/vendor/delta-*) ;; *) fail "per-id execute" "pushed: $(pushed_branches)" ;; esac
land
pass "per-id vendor of a brand-new capability: ONE PR with its payload and its manifest row"

out="$(orch vendor --cpp-dir "$CPP" alpha 2>&1)" || fail "per-id refresh" "$out"
[ "$(changes)" = "$(printf 'M\tquiver/skills/alpha/SKILL.md')" ] || fail "per-id refresh" "unexpected paths: $(changes)"
discard
pass "per-id refresh of an existing capability touches only its payload (no manifest churn)"

if out="$(orch vendor --cpp-dir "$CPP" gamma 2>&1)"; then fail "per-id gate" "excluded id should be refused"; fi
grep -q 'gamma is not enrolled' <<<"$out" || fail "per-id gate" "$out"
[ "$(branch_now)" = main ] || fail "per-id gate" "built a change for an excluded id"
pass "per-id vendor refuses a capability that is not enrolled"

# --- 7. Per-id delete: payload removal + manifest row together; cpp-native is never touched --------
out="$(orch delete --cpp-dir "$CPP" delta 2>&1)" || fail "per-id delete" "$out"
case "$(branch_now)" in orchestrator/vendor/rm-delta-*) ;; *) fail "per-id delete branch" "$(branch_now)" ;; esac
c="$(changes)"
has_change "$c" D quiver/skills/delta/SKILL.md || fail "per-id delete" "removal missing: $c"
has_change "$c" M "$MANIFEST_REL"              || fail "per-id delete" "manifest row removal missing: $c"
manifest_at HEAD | items_of | grep -qx delta && fail "per-id delete" "delta still active"
manifest_at HEAD | owns delta || fail "per-id delete" "delta lost its ownership tombstone"
discard
if out="$(orch delete --cpp-dir "$CPP" cpp-native 2>&1)"; then fail "native delete" "cpp-native removal should be refused"; fi
grep -q 'cpp-native; never removed' <<<"$out" || fail "native delete" "$out"
[ "$(branch_now)" = main ] && [ -f "$CPP/quiver/skills/cpp-native/SKILL.md" ] || fail "native delete" "cpp-native touched"
pass "per-id delete ships the removal with its manifest row; cpp-native items are refused"

printf 'test_combined_pr.sh: %d passed\n' "$passes"
