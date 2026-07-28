#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SKILLS="$TMP/skills"
GLOBAL="$SKILLS/global"
LOCAL="$SKILLS/local"
MCP="$TMP/mcp"
CPP="$TMP/cpp"
CONFIG="$TMP/relationship.yml"
REGISTRY="$TMP/registry.yml"

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

emit_meta() {
  local dir="$1" id="$2" kind="$3" scope="$4"
  mkdir -p "$dir"
  cat > "$dir/meta.yml" <<EOF
schema: kp-capability/v1
id: $id
kind: $kind
flavor: 1
scope: $scope
owner: KleinPerkins
install: install.sh
post_mgmt: none
EOF
}

write_registry() {
  local include_plugin="$1"
  cat > "$REGISTRY" <<'EOF'
schema: eco-registry/v1
items:
  - id: synced-skill
    state: enrolled
    reason: "fixture enrolled item"
EOF
  if [ "$include_plugin" = 1 ]; then
    cat >> "$REGISTRY" <<'EOF'
  - id: keep-awake
    state: excluded
    reason: "fixture global plugin intentionally excluded"
EOF
  fi
}

emit_meta "$GLOBAL/skills/synced-skill" synced-skill skill global
printf '# synced-skill\n' > "$GLOBAL/skills/synced-skill/SKILL.md"
mkdir -p "$CPP/quiver/skills/synced-skill" "$MCP"
cp "$GLOBAL/skills/synced-skill/SKILL.md" "$CPP/quiver/skills/synced-skill/SKILL.md"

emit_meta "$GLOBAL/plugins/keep-awake" keep-awake plugin global
emit_meta "$LOCAL/plugins/continual-learning" continual-learning plugin local

cat > "$CONFIG" <<EOF
schema: orchestrator-relationship/v1
source_skills_global: $GLOBAL
source_mcp_local: $MCP
cpp_quiver_path: quiver
ld_cpp_worktree: $CPP
EOF

ORCH_CONFIG="$CONFIG"
. "$ROOT/lib/common.sh"

[ "$(orch_skill_shelf_for_kind plugin)" = plugins ] \
  || fail "plugin kind did not route to the plugins shelf"

resolved="$(orch_resolve_skill_master "$GLOBAL" keep-awake || true)"
[ "$resolved" = "$GLOBAL/plugins/keep-awake" ] \
  || fail "global plugin master was not resolved"

discovered="$(orch_each_skill_meta "$GLOBAL")"
printf '%s\n' "$discovered" | grep -Fxq "$GLOBAL/plugins/keep-awake/meta.yml" \
  || fail "global plugin metadata was not discovered"
if printf '%s\n' "$discovered" | grep -Fq continual-learning; then
  fail "local continual-learning leaked into global discovery"
fi

write_registry 1
if ! clean_output="$(
  ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" \
    bash "$ROOT/lib/consistency.sh" --cpp-dir "$CPP" 2>&1
)"; then
  printf '%s\n' "$clean_output" >&2
  fail "excluded global plugin or local plugin caused enrollment drift"
fi
printf '%s\n' "$clean_output" \
  | grep -Fq 'registry.yml matches the on-disk scope:global set (exclusions/demotions honored)' \
  || fail "consistency did not confirm excluded-record coverage"
if printf '%s\n' "$clean_output" | grep -Fq continual-learning; then
  fail "local continual-learning appeared in the global drift result"
fi

write_registry 0
if missing_output="$(
  ORCH_CONFIG="$CONFIG" ORCH_REGISTRY="$REGISTRY" \
    bash "$ROOT/lib/consistency.sh" --cpp-dir "$CPP" 2>&1
)"; then
  fail "unrecorded global plugin did not cause enrollment drift"
fi
printf '%s\n' "$missing_output" \
  | grep -Fq 'keep-awake: scope:global on disk but absent from registry.yml' \
  || fail "global plugin drift did not identify keep-awake"
if printf '%s\n' "$missing_output" | grep -Fq continual-learning; then
  fail "local continual-learning was incorrectly reported as global drift"
fi

printf 'test_plugin_discovery: OK\n'
