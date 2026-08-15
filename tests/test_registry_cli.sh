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

printf 'test_registry_cli: OK\n'
