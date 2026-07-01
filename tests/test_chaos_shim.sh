#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/relationship.yml" <<EOF
schema: orchestrator-relationship/v1
chaos_labs_root: $TMP/chaos
chaos_labs_shim_path: scripts/setup/google-kit-shim.sh
chaos_labs_env_path: config/google-kit.env.example
EOF

mkdir -p "$TMP/chaos"
ORCH_CONFIG="$TMP/relationship.yml" bash "$ROOT/lib/chaos_shim.sh"
ORCH_CONFIG="$TMP/relationship.yml" bash "$ROOT/lib/chaos_shim.sh" --execute

SHIM="$TMP/chaos/scripts/setup/google-kit-shim.sh"
ENVFILE="$TMP/chaos/config/google-kit.env.example"
[ -x "$SHIM" ] || { echo "chaos shim missing or not executable"; exit 1; }
[ -f "$ENVFILE" ] || { echo "chaos env example missing"; exit 1; }
grep -q 'GOOGLE_KIT_CONFIG_DIR' "$SHIM" || { echo "shim missing GOOGLE_KIT_CONFIG_DIR"; exit 1; }
grep -q 'GOOGLE_KIT_DOC_STYLES_SEED_DIR' "$SHIM" || { echo "shim missing seed-dir hook"; exit 1; }

if grep -REnI 'Laurence|profiles/laurence|/Users/laurence\.duggan|KleinPerkins/[A-Za-z0-9_.-]+|kp-mcp' "$TMP/chaos"; then
  echo "personal or ld source token leaked into chaos shim"
  exit 1
fi

echo "test_chaos_shim: OK"
