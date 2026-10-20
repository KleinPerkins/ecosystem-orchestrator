#!/usr/bin/env bash
# tests/test_combined_pr.sh — ADR 0002 regression: one orchestrator run = ONE cpp PR.
#
# Reproduces the 2026-10-20 incidents in a hermetic sandbox (throwaway masters, fake cpp with a bare
# origin, stub gh):
#   * cross-capability dependency (cpp #1054/#1055: swarm landed before subagent-orchestration) —
#     two changed capabilities must ship in ONE commit / ONE PR;
#   * removal vs manifest (cpp #1061/#1062) — a payload removal and its manifest row ship together.
# Also proves: the cpp-sync preflight (lockkit + verify-skills + reconcile + flavor-2 digest) gates
# cpp-sync AND per-id vendor, one bad capability stops the whole PR, a RED integrity gate refuses the
# push, only one orchestrator PR may be in flight, and an in-sync run is a no-op. The execute path runs
# end to end against the sandbox only.
#
# The PR-verification sandbox (gVisor) caps the sandbox's HOST tasks at 64 and every short-lived
# process costs one for a while, so this test keeps full orchestrator runs to the six that prove
# end-to-end behavior and checks the shared PR guard at function level.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SKILLS="$TMP/skills"; GLOBAL="$SKILLS/global"; MCP="$TMP/mcp"; VERIFIER="$TMP/verifier"
CPP="$TMP/cpp"; ORIGIN="$TMP/origin.git"
CONFIG="$TMP/relationship.yml"; REGISTRY="$TMP/registry.yml"; LKCFG="$TMP/lockkit.yml"
VERIFY_MARK="$TMP/verify-skills.ran"; VERIFY_FAIL="$TMP/verify-skills.fail"
MANIFEST_REL="quiver/tooling/eco-capability-sync/eco-capability-manifest.yml"
export GHLOG="$TMP/gh.log" GHOPEN="$TMP/gh-open-prs" GHFAIL="$TMP/gh-list-fails"
# git's per-CPU pack/index worker threads and its maintenance/gc helpers each cost a sandbox task.
export GIT_CONFIG_COUNT=5 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=gc.auto GIT_CONFIG_VALUE_1=0 GIT_CONFIG_KEY_2=receive.autogc GIT_CONFIG_VALUE_2=false \
  GIT_CONFIG_KEY_3=pack.threads GIT_CONFIG_VALUE_3=1 GIT_CONFIG_KEY_4=index.threads GIT_CONFIG_VALUE_4=1
passes=0

pass() { printf '  PASS %s\n' "$1"; passes=$((passes+1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "${2:-assertion failed}" >&2; exit 1; }

# The sandbox has no `make` and mounts its writable space noexec, so the stub `gh` and the fixture
# cpp's `make verify` are exported functions (inherited by every child bash), not files.
gh() {
  { printf '%s' "$*" | tr '\n' ' '; printf '\n'; } >> "$GHLOG"
  case "${1:-} ${2:-}" in
    "pr list")   [ ! -f "$GHFAIL" ] || return 1; cat "$GHOPEN" ;;
    "pr create") echo "https://example.invalid/cpp/pull/$(grep -c '^pr create' "$GHLOG")" ;;
  esac
  return 0
}
make() { [ "${1:-}" = verify ] && [ ! -e RED ] || return 2; }   # fixture integrity: exits 2 like a failing make
export -f gh make
: > "$GHLOG"; : > "$GHOPEN"

# --- fixture masters (their real lock feeds reconcile) + the lockkit target ------------------------
# The lockkit target is a metadata-free dir carrying the real lock writer and a verify-skills stub:
# eco-lock's per-capability pipelines (covered by test_lockkit) would overflow the task cap here.
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
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/install.sh"
  printf '# %s\n\nFixture payload %s.\n' "$1" "$2" > "$d/SKILL.md"
}

mkdir -p "$MCP" "$SKILLS/.github/scripts" "$VERIFIER/.github/scripts"
for dir in "$SKILLS" "$VERIFIER"; do
  cp "$ROOT/templates/eco-lock/eco-lock.sh" "$dir/.github/scripts/eco-lock.sh"
  chmod +x "$dir/.github/scripts/eco-lock.sh"
done
printf '#!/usr/bin/env bash\n: > "%s"\n[ ! -e "%s" ]\n' "$VERIFY_MARK" "$VERIFY_FAIL" > "$VERIFIER/.github/scripts/verify-skills.sh"
( cd "$VERIFIER" && bash .github/scripts/eco-lock.sh write >/dev/null )
for id in alpha beta gamma; do emit_master "$id" v1; done
emit_master delta v1 2                     # brand-new (like save-game) and flavor-2; enrolled in section 5
( cd "$SKILLS" && bash .github/scripts/eco-lock.sh write >/dev/null )   # reconcile needs enrolled ids locked

cat > "$LKCFG" <<EOF
schema: lockkit/v1
master: templates/eco-lock/eco-lock.sh
targets:
  - name: skills
    root: $VERIFIER
    script: .github/scripts/eco-lock.sh
    lock: .eco-registry.lock
    verify: .github/scripts/verify-skills.sh
EOF
cat > "$REGISTRY" <<'EOF'
schema: eco-registry/v1
items:
  - id: alpha
    state: enrolled
    reason: "fixture"
  - id: beta
    state: enrolled
    reason: "fixture"
  - id: gamma
    state: enrolled
    reason: "fixture"
EOF
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

export ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" LOCKKIT_CONFIG="$LKCFG"
orch() { bash "$ROOT/bin/orchestrator.sh" "$@"; }
# cap <cmd...> — run a script as a direct child with its output in a file, then set $out (no capture
# subshell idles around the writer's pipelines).
cap() { "$@" >"$TMP/cmd.out" 2>&1; local rc=$?; out="$(cat "$TMP/cmd.out")"; return "$rc"; }
writer() { cap bash "$ROOT/lib/vendor.sh" --cpp-dir "$CPP" "$@"; }
verb() { cap bash "$ROOT/lib/selfmanage.sh" "$@"; }
guard() { cap bash -c '. "$1/lib/common.sh"; orch_refuse_if_orchestrator_pr_open fixture/cpp orchestrator/vendor' _ "$ROOT"; }
branch_now() { git -C "$CPP" branch --show-current; }
ahead() { git -C "$CPP" rev-list --count main..HEAD; }
changes() { git -C "$CPP" diff --name-status main HEAD; }
manifest_at() { git -C "$CPP" show "$1:$MANIFEST_REL"; }
items_of() { awk '/^items:/ {f=1; next} f && /^[[:space:]]*-[[:space:]]*id:/ {sub(/.*id:[[:space:]]*/, ""); print}'; }
owns() { awk -v want="$1" '/^owned_ids:/ {sub(/^owned_ids:[[:space:]]*\[/, ""); sub(/\].*$/, ""); gsub(/[[:space:]]/, ""); n=split($0, a, ","); for (i=1; i<=n; i++) if (a[i] == want) found=1} END {exit found ? 0 : 1}'; }
row_of() { awk -v want="$1" '/^[[:space:]]*-[[:space:]]*id:/ {cur=$0; sub(/.*id:[[:space:]]*/, "", cur)} cur == want {print}'; }
pushed_branches() { git -C "$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads/orchestrator; }
pr_creates() { grep -c '^pr create' "$GHLOG" || true; }
nothing_shipped() { [ "$(pr_creates)" = 0 ] && [ -z "$(pushed_branches)" ]; }
has_change() { printf '%s\n' "$1" | grep -qxF "$(printf '%s\t%s' "$2" "$3")"; }
land() {   # simulate cpp squash-merging the pending branch: fast-forward main, drop the branch
  local b r; b="$(branch_now)"
  git -C "$CPP" branch -f main HEAD >/dev/null; git -C "$CPP" checkout -q main
  [ "$b" = main ] || git -C "$CPP" branch -qD "$b"
  for r in $(pushed_branches); do git -C "$ORIGIN" update-ref -d "refs/heads/$r"; done
}
discard() {   # drop a dry-run / refused branch and any staged leftovers
  local b; b="$(branch_now)"
  git -C "$CPP" checkout -q -f main; git -C "$CPP" clean -qfd
  [ "$b" = main ] || git -C "$CPP" branch -qD "$b"
}
pushed_diff() { git -C "$ORIGIN" diff --name-status "$(git -C "$CPP" rev-parse main)" "$1"; }

# --- 1. Dry-run: three new payloads + the manifest are ONE local commit; no push, no gh call ------
writer --sync alpha beta gamma || fail "dry-run" "$out"
case "$(branch_now)" in orchestrator/vendor/sync-*) ;; *) fail "dry-run branch name" "$(branch_now)" ;; esac
[ "$(ahead)" = 1 ] || fail "dry-run" "expected one commit, got $(ahead)"
c="$(changes)"
for id in alpha beta gamma; do has_change "$c" A "quiver/skills/$id/SKILL.md" || fail "dry-run" "$id missing: $c"; done
has_change "$c" A "$MANIFEST_REL" || fail "dry-run" "manifest missing from the same commit: $c"
grep -q 'ONE combined cpp PR planned' <<<"$out" || fail "dry-run" "plan line missing"
[ ! -s "$GHLOG" ] && nothing_shipped || fail "dry-run" "dry-run called gh or pushed"
land
pass "dry-run: every payload and the manifest are ONE local commit; nothing pushed, no gh call"

# --- 2. The incidents via the real verb: two dependent updates + a removal = ONE PR ---------------
emit_master alpha v2                       # like swarm ...
emit_master beta v2                        # ... and the subagent-orchestration change it depends on
orch exclude gamma -- "fixture retire (like algorithmic-art)" >/dev/null 2>&1
rm -rf "$GLOBAL/skills/gamma"             # a retired capability's master may be gone too
touch "$VERIFY_FAIL"
if verb cpp-sync --execute --cpp-dir "$CPP"; then fail "verify-skills gate" "a failing verifier should stop cpp-sync"; fi
[ "$(branch_now)" = main ] && nothing_shipped || fail "verify-skills gate" "built or shipped despite a failing verifier"
rm -f "$VERIFY_FAIL" "$VERIFY_MARK"
pass "a failing verify-skills stops cpp-sync before anything is built"

verb cpp-sync --execute --cpp-dir "$CPP" || fail "sync execute" "$out"
[ -f "$VERIFY_MARK" ] || fail "verify-skills gate" "cpp-sync did not run the capability verifier"
[ "$(pr_creates)" = 1 ] || fail "sync execute" "expected one 'gh pr create', got $(pr_creates)"
[ "$(grep -c '^pr merge .*--auto --squash' "$GHLOG")" = 1 ] || fail "sync execute" "expected one auto-merge request"
grep '^pr create' "$GHLOG" | grep -qF 'orchestrator sync (vendor: alpha, beta; remove: gamma)' \
  || fail "sync execute" "PR title does not name every change: $(grep '^pr create' "$GHLOG")"
pb="$(pushed_branches)"
case "$pb" in orchestrator/vendor/sync-*) ;; *) fail "sync execute" "pushed: $pb" ;; esac
[ "$(git -C "$ORIGIN" rev-list --count "$(git -C "$CPP" rev-parse main)..$pb")" = 1 ] || fail "sync execute" "pushed branch is not one commit"
c="$(pushed_diff "$pb")"
has_change "$c" M quiver/skills/alpha/SKILL.md || fail "sync execute" "alpha update missing: $c"
has_change "$c" M quiver/skills/beta/SKILL.md  || fail "sync execute" "beta update missing: $c"
has_change "$c" D quiver/skills/gamma/SKILL.md || fail "sync execute" "gamma removal missing: $c"
has_change "$c" M "$MANIFEST_REL"              || fail "sync execute" "manifest update missing: $c"
[ "$(git -C "$ORIGIN" show "$pb:$MANIFEST_REL" | items_of | paste -sd' ' -)" = "alpha beta" ] || fail "sync execute" "items should be alpha beta"
git -C "$ORIGIN" show "$pb:$MANIFEST_REL" | owns gamma || fail "sync execute" "removed gamma lost its ownership tombstone"
printf '%s\n' "$c" | grep -q 'cpp-native' && fail "sync execute" "cpp-native payload was touched"
land
pass "cpp-sync --execute: both updates, the removal, and the manifest ship as ONE PR (auto-merge requested once)"

# --- 3. Idempotency + one orchestrator PR in flight --------------------------------------------------
: > "$GHLOG"
writer --execute beta || fail "in-sync" "$out"
grep -q 'no changes — already in sync' <<<"$out" || fail "in-sync" "no-op message missing"
[ "$(ahead)" = 0 ] && [ ! -s "$GHLOG" ] || fail "in-sync" "created a commit or called gh"
discard
pass "in-sync run is a no-op: no commit, no gh call, no PR"

guard || fail "open-PR guard" "refused with no open PR: $out"
printf '#77 orchestrator/vendor/sync-20261020-000000 https://example.invalid/cpp/pull/77\n' > "$GHOPEN"
if guard; then fail "open-PR guard" "should refuse while an orchestrator PR is open"; fi
grep -q 'already has an open orchestrator PR' <<<"$out" || fail "open-PR guard" "$out"
: > "$GHOPEN"; touch "$GHFAIL"
if guard; then fail "open-PR guard" "an unreadable PR list should refuse"; fi
grep -q 'could not list open cpp PRs' <<<"$out" || fail "open-PR guard" "$out"
rm -f "$GHFAIL"
for f in lib/vendor.sh lib/recovery.sh; do
  awk '/orch_refuse_if_orchestrator_pr_open/ {g=NR} /git -C "\$WORK" push/ {p=NR} END {exit (g && p && g < p) ? 0 : 1}' "$ROOT/$f" \
    || fail "open-PR guard" "$f must refuse an open orchestrator PR before pushing"
done
grep -q 'orch_open_orchestrator_prs' "$ROOT/lib/status.sh" || fail "status" "status must use the guard's PR lister"
pass "one orchestrator PR in flight: the guard refuses an open or unreadable PR list before every push; status shares it"

# --- 4. Fail closed: one bad capability or a RED gate stops the WHOLE PR --------------------------
emit_master alpha v3
printf '\nSource: KleinPerkins/skills\n' >> "$GLOBAL/skills/beta/SKILL.md"     # zero-link violation
if writer --sync --execute alpha beta; then fail "fail closed" "zero-link violation should abort"; fi
grep -q 'beta: payload tripped zero-link' <<<"$out" || fail "fail closed" "$out"
nothing_shipped && [ "$(ahead)" = 0 ] || fail "fail closed" "alpha shipped or committed without beta"
emit_master beta v2; discard
pass "one capability tripping zero-link stops the whole PR (the other change does not ship alone)"

: > "$CPP/RED"; git -C "$CPP" add RED; git -C "$CPP" commit -qm "fixture: red integrity"
if writer --execute alpha; then fail "red gate" "RED integrity should refuse"; fi
grep -q 'gate RED' <<<"$out" || fail "red gate" "a check exiting 2 must read as RED: $out"
nothing_shipped || fail "red gate" "pushed despite RED integrity"
[ "$(changes)" = "$(printf 'M\tquiver/skills/alpha/SKILL.md')" ] \
  || fail "per-id refresh" "an existing capability's refresh should touch only its payload: $(changes)"
discard; git -C "$CPP" rm -q RED; git -C "$CPP" commit -qm "fixture: green integrity"
pass "a RED integrity gate (even a check exiting 2) refuses the push; a per-id refresh has no manifest churn"

# --- 5. Per-id vendor: same gates as cpp-sync; a brand-new capability ships with its manifest row --
printf '  - id: delta\n    state: enrolled\n    reason: "fixture"\n' >> "$REGISTRY"
if verb vendor --cpp-dir "$CPP" delta; then fail "per-id gate" "unapproved flavor-2 should be refused"; fi
grep -q 'preflight refused delta:.*supply-chain' <<<"$out" || fail "per-id gate" "$out"
if verb vendor --cpp-dir "$CPP" gamma; then fail "per-id gate" "excluded id should be refused"; fi
grep -q 'gamma is not enrolled' <<<"$out" || fail "per-id gate" "$out"
if writer --delete cpp-native; then fail "native delete" "cpp-native removal should be refused"; fi
grep -q 'cpp-native; never removed' <<<"$out" || fail "native delete" "$out"
[ "$(branch_now)" = main ] && [ -f "$CPP/quiver/skills/cpp-native/SKILL.md" ] || fail "per-id gate" "built or touched something"
pass "per-id vendor refuses unapproved flavor-2 and non-enrolled ids; cpp-native items are never removed"

orch approve delta >/dev/null 2>&1
verb vendor --execute --cpp-dir "$CPP" delta || fail "per-id new" "$out"
[ "$(pr_creates)" = 1 ] && [ "$(grep -c '^pr merge .*--auto --squash' "$GHLOG")" = 1 ] || fail "per-id new" "$(cat "$GHLOG")"
pb="$(pushed_branches)"
case "$pb" in orchestrator/vendor/delta-*) ;; *) fail "per-id new" "pushed: $pb" ;; esac
c="$(pushed_diff "$pb")"
has_change "$c" A quiver/skills/delta/SKILL.md || fail "per-id new" "payload missing: $c"
has_change "$c" M "$MANIFEST_REL"              || fail "per-id new" "manifest row missing: $c"
printf '%s\n' "$c" | grep -q 'quiver/skills/alpha/' && fail "per-id new" "pending alpha change leaked into a per-id PR"
for id in alpha beta; do
  [ "$(git -C "$ORIGIN" show "$pb:$MANIFEST_REL" | row_of "$id")" = "$(manifest_at main | row_of "$id")" ] || fail "per-id new" "$id row changed"
done
pass "per-id vendor of a brand-new capability: ONE PR with its payload and only its manifest row"

printf 'test_combined_pr.sh: %d passed\n' "$passes"
