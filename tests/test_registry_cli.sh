#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REGISTRY="$TMP/registry.yml"
printf '%s\n' \
  'schema: eco-registry/v1' \
  'items:' > "$REGISTRY"

ORCH_REGISTRY="$REGISTRY" \
  bash "$ROOT/bin/orchestrator.sh" enroll demo -- "documented reason" >/dev/null

reason="$(
  ORCH_REGISTRY="$REGISTRY" bash -c \
    '. "$1/lib/registry.sh"; reg_field demo reason' _ "$ROOT"
)"
[ "$reason" = "documented reason" ] || {
  printf 'FAIL documented -- separator leaked into reason: %s\n' "$reason" >&2
  exit 1
}

# Relationship identity is independent of mutable names. Check through the existing flat-YAML
# reader, including its deferred post-cutover state; never contact or mutate real sources.
identity_fields() {
  ORCH_CONFIG="$1" bash -c '
    . "$1/lib/common.sh"
    for source in skills mcp; do
      for suffix in local repo repo_id retained_repo; do
        orch_cfg_get "source_${source}_${suffix}"
      done
    done
  ' _ "$ROOT"
}
identity_fields "$ROOT/config/relationship.yml" > "$TMP/current-identities"
cat > "$TMP/expected-identities" <<'EOF'
~/dev/capabilities/skills
git@github.com:KleinPerkins/skills.git
1275604090
git@github.com:KleinPerkins/skills-private-original.git
~/dev/capabilities/mcp
git@github.com:KleinPerkins/kp-mcp.git
1271164179
git@github.com:KleinPerkins/kp-mcp-private-original.git
EOF
cmp "$TMP/expected-identities" "$TMP/current-identities"
# The staged rename changes only active endpoints. Roots and IDs stay fixed.
sed -e 's|^source_skills_repo: .*|source_skills_repo: git@github.com:KleinPerkins/skills-private-original.git|' \
    -e 's|^source_mcp_repo: .*|source_mcp_repo: git@github.com:KleinPerkins/kp-mcp-private-original.git|' \
    "$ROOT/config/relationship.yml" > "$TMP/retained-relationship.yml"
identity_fields "$TMP/retained-relationship.yml" > "$TMP/retained-identities"
sed -e 's|^git@github.com:KleinPerkins/skills.git$|git@github.com:KleinPerkins/skills-private-original.git|' \
    -e 's|^git@github.com:KleinPerkins/kp-mcp.git$|git@github.com:KleinPerkins/kp-mcp-private-original.git|' \
    "$TMP/expected-identities" > "$TMP/expected-retained"
cmp "$TMP/expected-retained" "$TMP/retained-identities"
printf 'test_registry_cli: OK\n'
