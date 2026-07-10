#!/usr/bin/env bash
# Hermetic orchestrator lifecycle regression for manifest ownership and downstream prune.
#
# Always exercises real enroll/vendor/exclude/demote/delete/manifest/rollback/quarantine code against
# throwaway git fixtures. Set ORCH_TEST_CPP_DIR to a clean cpp checkout to additionally run cpp's real
# merged eco-capability reconciler against every active/removal transition.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SRC="$TMP/global"
REGISTRY="$TMP/registry.yml"
CONFIG="$TMP/relationship.yml"
CPP="$TMP/cpp"
SBOX="$TMP/home"
MANIFEST="$CPP/quiver/tooling/eco-capability-sync/eco-capability-manifest.yml"
ID="ownership-demo"
FIXED="eco-capability-sync"
passes=0

pass() { printf '  PASS %s\n' "$1"; passes=$((passes+1)); }
fail() { printf '  FAIL %s: %s\n' "$1" "${2:-assertion failed}" >&2; exit 1; }

write_master() {
  mkdir -p "$SRC/skills/$ID"
  cat > "$SRC/skills/$ID/meta.yml" <<EOF
schema: kp-capability/v1
id: $ID
kind: skill
flavor: 1
scope: global
owner: KleinPerkins
install: install.sh
post_mgmt: none
expose: [cursor]
EOF
  printf '# %s\n\nFixture payload.\n' "$ID" > "$SRC/skills/$ID/SKILL.md"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SRC/skills/$ID/install.sh"
  chmod +x "$SRC/skills/$ID/install.sh"
}

cat > "$REGISTRY" <<'EOF'
schema: eco-registry/v1
items:
EOF

mkdir -p "$SRC" "$TMP/mcp" "$CPP"
write_master
cat > "$CONFIG" <<EOF
schema: orchestrator-relationship/v1
source_skills_local: $TMP/skills-root
source_skills_global: $SRC
source_skills_repo: fixture
source_mcp_local: $TMP/mcp
source_mcp_repo: fixture
cpp_repo: fixture/cpp
cpp_clone_url: $CPP
cpp_default_branch: main
cpp_quiver_path: quiver
cpp_pr_branch_prefix: orchestrator/vendor
cpp_merge_mode: auto-squash
cpp_forbidden_paths: _ops/ .github/
enabled_kinds: skill mcp rule sub-agent tool
cpp_sync_denylist: $FIXED
ld_cpp_worktree: $CPP
work_clone_dir: $TMP/work
backup_dir: $TMP/backups
EOF

git -C "$CPP" init -q
git -C "$CPP" checkout -q -b main
git -C "$CPP" config user.name tester
git -C "$CPP" config user.email tester@example.invalid
printf 'verify:\n\t@true\n' > "$CPP/Makefile"
mkdir -p "$CPP/quiver/tooling/$FIXED" "$CPP/quiver/skills/cpp-native"
printf '# cpp native\n' > "$CPP/quiver/skills/cpp-native/SKILL.md"
git -C "$CPP" add .
git -C "$CPP" commit -qm "fixture base"

run_orch() {
  ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" bash "$ROOT/bin/orchestrator.sh" "$@"
}

run_vendor() {
  ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" bash "$ROOT/lib/vendor.sh" --cpp-dir "$CPP" "$@"
}

run_manifest() {
  ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" bash "$ROOT/lib/manifest.sh" --cpp-dir "$CPP" "$@"
}

land_current() {
  local branch
  branch="$(git -C "$CPP" branch --show-current)"
  git -C "$CPP" branch -f main HEAD >/dev/null
  git -C "$CPP" checkout -q main
  [ "$branch" = "main" ] || git -C "$CPP" branch -qD "$branch"
}

manifest_has_item() {
  local want="$1"
  awk -v want="$want" '
    /^items:[[:space:]]*$/ { in_items=1; next }
    in_items && /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
      v=$0
      sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", v)
      gsub(/[[:space:]]/, "", v)
      if (v == want) found=1
    }
    END { exit found ? 0 : 1 }
  ' "$MANIFEST"
}

manifest_owns() {
  local want="$1"
  awk -v want="$want" '
    /^owned_ids:[[:space:]]*\[/ {
      v=$0
      sub(/^owned_ids:[[:space:]]*\[/, "", v)
      sub(/\].*$/, "", v)
      n=split(v, ids, ",")
      for (i=1; i<=n; i++) {
        gsub(/[[:space:]]/, "", ids[i])
        if (ids[i] == want) found=1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$MANIFEST"
}

set_journal_sha() {
  local sha="$1"
  ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" bash -c \
    '. "$1/lib/registry.sh"; reg_journal_set "$2" last_synced_cpp_sha "$3"' \
    _ "$ROOT" "$ID" "$sha"
}

CPP_SOURCE="${ORCH_TEST_CPP_DIR:-}"
RECONCILER=""
if [ -n "$CPP_SOURCE" ]; then
  [ -f "$CPP_SOURCE/_ops/bin/eco-capability-reconcile.sh" ] \
    || fail "cpp reconciler fixture" "missing $CPP_SOURCE/_ops/bin/eco-capability-reconcile.sh"
  mkdir -p "$CPP/_ops/bin"
  cp "$CPP_SOURCE/_ops/bin/eco-capability-reconcile.sh" "$CPP/_ops/bin/"
  cp "$CPP_SOURCE/_ops/bin/cpp-lib.sh" "$CPP/_ops/bin/"
  cp "$CPP_SOURCE/_ops/POLICY.md" "$CPP/_ops/"
  chmod +x "$CPP/_ops/bin/eco-capability-reconcile.sh"
  RECONCILER="$CPP/_ops/bin/eco-capability-reconcile.sh"
  for tool in cursor claude codex; do
    mkdir -p "$SBOX/.$tool/skills" "$SBOX/.$tool/agents" "$SBOX/.$tool/rules"
  done
  mkdir -p "$TMP/foreign/quiver/skills/foreign-capability"
  printf '# foreign\n' > "$TMP/foreign/quiver/skills/foreign-capability/SKILL.md"
  ln -s "$CPP/quiver/skills/cpp-native" "$SBOX/.cursor/skills/cpp-native"
  ln -s "$TMP/foreign/quiver/skills/foreign-capability" "$SBOX/.cursor/skills/foreign-capability"
fi

reconcile() {
  [ -n "$RECONCILER" ] || return 0
  (cd "$CPP" && HOME="$SBOX" bash "$RECONCILER") >/dev/null
}

assert_protected_links() {
  [ -n "$RECONCILER" ] || return 0
  [ -L "$SBOX/.cursor/skills/cpp-native" ] \
    || fail "cpp-native protection" "cpp-native link was removed"
  [ -L "$SBOX/.cursor/skills/foreign-capability" ] \
    || fail "foreign-quiver protection" "foreign link was removed"
}

# Migrate the production defect shape: prior manifests listed active items but only fixed tooling in
# owned_ids. Even with the payload already absent, the prior active row must seed a retained tombstone.
mkdir -p "$(dirname "$MANIFEST")"
cat > "$MANIFEST" <<EOF
schema: eco-manifest/v1
generated_at: "2026-07-10T00:00:00Z"
owned_ids: [$FIXED]
items:
  - id: legacy-removed
    category: skills
    scope: global
    expose: [cursor]
EOF
git -C "$CPP" add "${MANIFEST#"$CPP"/}"
git -C "$CPP" commit -qm "fixture legacy manifest"
run_manifest >/dev/null
land_current
manifest_has_item legacy-removed && fail "legacy migration active cleanup" "removed id remained active"
manifest_owns legacy-removed || fail "legacy migration tombstone" "prior active id was not retained"
manifest_owns cpp-native && fail "legacy migration native ownership" "cpp-native id was claimed"
pass "legacy active-only manifest migrates removed ids into bounded ownership"

# Enroll -> vendor -> active manifest -> downstream link.
run_orch enroll "$ID" -- "fixture enroll" >/dev/null
[ "$(ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" bash -c '. "$1/lib/registry.sh"; reg_state "$2"' _ "$ROOT" "$ID")" = enrolled ] \
  || fail "enroll" "registry state is not enrolled"
run_vendor "$ID" >/dev/null
land_current
run_manifest "$ID" >/dev/null
land_current
manifest_has_item "$ID" || fail "active manifest" "$ID missing from items"
manifest_owns "$ID" || fail "active ownership" "$ID missing from owned_ids"
manifest_owns "$FIXED" || fail "fixed ownership" "$FIXED missing from owned_ids"
manifest_owns cpp-native && fail "cpp-native non-ownership" "cpp-native id was claimed"
manifest_owns foreign-capability && fail "foreign non-ownership" "foreign id was claimed"
pass "active items and ownership are emitted separately without native/foreign claims"

reconcile
if [ -n "$RECONCILER" ]; then
  [ -L "$SBOX/.cursor/skills/$ID" ] || fail "active downstream link" "link was not installed"
  assert_protected_links
  pass "clean cpp reconciler installs active link and preserves protected links"
fi

# Exclude -> delete -> inactive historical tombstone -> immediate and arbitrarily late prune.
run_orch exclude "$ID" -- "fixture exclude" >/dev/null
run_vendor --delete "$ID" >/dev/null
land_current
run_manifest >/dev/null
land_current
manifest_has_item "$ID" && fail "exclude active cleanup" "$ID remained active"
manifest_owns "$ID" || fail "exclude tombstone" "$ID was not retained in owned_ids"
pass "exclude/delete emits an inactive ownership tombstone"

reconcile
if [ -n "$RECONCILER" ]; then
  [ ! -L "$SBOX/.cursor/skills/$ID" ] || fail "exclude downstream prune" "stale link remains"
  assert_protected_links
  pass "clean cpp reconciler prunes only the owned stale link"
fi

run_manifest >/dev/null
land_current
manifest_owns "$ID" || fail "tombstone retention" "$ID ownership expired without downstream acknowledgements"
before="$(git -C "$CPP" hash-object "$MANIFEST")"
run_manifest >/dev/null
land_current
after="$(git -C "$CPP" hash-object "$MANIFEST")"
[ "$before" = "$after" ] || fail "repeated manifest determinism" "$before != $after"
pass "historical ownership tombstone and repeated sync are byte-stable"
if [ -n "$RECONCILER" ]; then
  CPP_P="$(cd -P "$CPP" && pwd -P)"
  ln -sfn "$CPP_P/quiver/skills/$ID" "$SBOX/.cursor/skills/$ID"
  reconcile
  [ ! -L "$SBOX/.cursor/skills/$ID" ] || fail "late downstream prune" "late stale link remains"
  assert_protected_links
  pass "retained tombstone prunes a client that missed the removal generation"
fi

# Re-enroll -> demote after deleting the master -> delete still retains the prior active ownership.
write_master
run_orch enroll "$ID" -- "fixture re-enroll" >/dev/null
run_vendor "$ID" >/dev/null
land_current
run_manifest "$ID" >/dev/null
land_current
ROLLBACK_SHA="$(git -C "$CPP" rev-parse HEAD)"
set_journal_sha "$ROLLBACK_SHA"
reconcile

run_orch demote "$ID" -- "fixture demote" >/dev/null
rm -rf "$SRC/skills/$ID"
run_vendor --delete "$ID" >/dev/null
land_current
run_manifest >/dev/null
land_current
manifest_has_item "$ID" && fail "demote active cleanup" "$ID remained active"
manifest_owns "$ID" || fail "demote tombstone" "$ID was not retained after master deletion"
reconcile
if [ -n "$RECONCILER" ]; then
  [ ! -L "$SBOX/.cursor/skills/$ID" ] || fail "demote downstream prune" "stale link remains"
  assert_protected_links
fi
pass "demote/delete-after-master-gone retains deterministic prune ownership"

# Repeat the inactive manifest, then rollback the old marked payload. Historical ownership remains
# stable without making the demoted item active; deleting it again is deterministic.
run_manifest >/dev/null
land_current
manifest_owns "$ID" || fail "pre-rollback ownership" "$ID tombstone was lost"
ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" \
  bash "$ROOT/lib/recovery.sh" rollback --cpp-dir "$CPP" "$ID" >/dev/null
land_current
[ -f "$CPP/quiver/skills/$ID/VENDORED.md" ] || fail "rollback restore" "marked payload was not restored"
run_manifest >/dev/null
land_current
manifest_has_item "$ID" && fail "rollback activation" "demoted rollback became active"
manifest_owns "$ID" || fail "rollback ownership" "restored marked payload was not owned"
run_vendor --delete "$ID" >/dev/null
land_current
run_manifest >/dev/null
land_current
pass "rollback preserves ownership without reactivating a demoted item"

# Quarantine drives the same local fixture path: registry exclusion, payload deletion, manifest
# tombstone, and downstream prune. --dry-run prevents network writes while --cpp-dir exercises the
# real local governed-PR preparation code.
write_master
run_orch enroll "$ID" -- "fixture quarantine setup" >/dev/null
run_vendor "$ID" >/dev/null
land_current
run_manifest "$ID" >/dev/null
land_current
reconcile
ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" ORCH_SKIP_GH_PR_CLOSE=1 \
  bash "$ROOT/lib/recovery.sh" quarantine --dry-run --cpp-dir "$CPP" "$ID" -- "fixture incident" >/dev/null
land_current
[ "$(ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" bash -c '. "$1/lib/registry.sh"; reg_state "$2"' _ "$ROOT" "$ID")" = excluded ] \
  || fail "quarantine registry" "state is not excluded"
manifest_has_item "$ID" && fail "quarantine active cleanup" "$ID remained active"
manifest_owns "$ID" || fail "quarantine tombstone" "$ID missing from owned_ids"
reconcile
if [ -n "$RECONCILER" ]; then
  [ ! -L "$SBOX/.cursor/skills/$ID" ] || fail "quarantine downstream prune" "stale link remains"
  assert_protected_links
fi
pass "quarantine reuses bounded delete ownership and downstream prune"

if [ -z "$RECONCILER" ]; then
  printf '  SKIP real cpp downstream reconcile (set ORCH_TEST_CPP_DIR to a clean cpp main checkout)\n'
fi
printf 'test_delete_propagation.sh: %d passed\n' "$passes"
