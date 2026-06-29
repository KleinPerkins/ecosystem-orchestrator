#!/usr/bin/env bash
# lib/reconcile.sh — WF1/B2 AUTHORITY. The ONLY component that sees BOTH the registry SoT
# (config/registry.yml) and a capability repo's committed .eco-registry.lock (eco-lock/v1). On a
# conflict the REGISTRY wins — the lock is fast-feedback only. Read-only; never mutates either side.
#
# Exit 0 = registry and locks agree; 1 = divergence; 2 = could not run (no lock found / bad schema).
# Wired fail-open into the launchd --periodic body (B3): a non-zero here reports, it never blocks.
set -uo pipefail
R_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$R_LIB_DIR/common.sh"
. "$R_LIB_DIR/registry.sh"

SRC_SKILLS_LOCAL="$(orch_expand "$(orch_cfg_get source_skills_local)")"
SRC_MCP_LOCAL="$(orch_expand "$(orch_cfg_get source_mcp_local)")"

reg_assert_schema || exit 2

# Collect locked ids across managed roots (each repo commits its own .eco-registry.lock).
locked_ids=""; roots_seen=0
for root in "$SRC_SKILLS_LOCAL" "$SRC_MCP_LOCAL"; do
  [ -n "$root" ] || continue
  lock="$root/.eco-registry.lock"
  [ -f "$lock" ] || continue
  roots_seen=1
  orch_schema_assert "$lock" "eco-lock/v1" || orch_warn "reconcile: $lock declares an incompatible schema"
  locked_ids="$locked_ids $(grep -vE '^(schema:|#|[[:space:]]*$)' "$lock" | awk '{print $1}')"
done
if [ "$roots_seen" = 0 ]; then
  orch_warn "reconcile: no .eco-registry.lock under managed roots (run eco-lock.sh write in skills + kp-mcp)"; exit 2
fi
locked_set=" $(printf '%s ' $locked_ids) "

diverge=0
echo "== orchestrator reconcile (registry.yml <-> committed .eco-registry.lock; registry is authority) =="
# Enrolled in the registry but ABSENT from every committed lock => the capability the registry claims
# to vendor is not integrity-pinned on disk. Registry wins (the enrollment stands) but the lock is
# flagged as stale so the operator regenerates it.
while IFS= read -r id; do
  [ -n "$id" ] || continue
  case "$locked_set" in
    *" $id "*) ;;
    *) printf '  DIVERGE  %s: enrolled in registry.yml but absent from every committed lock (stale lock; run eco-lock.sh write)\n' "$id"; diverge=1 ;;
  esac
done < <(reg_ids enrolled)

[ "$diverge" = 0 ] && printf '  OK     every enrolled id is integrity-pinned in a committed lock\n'
echo
if [ "$diverge" = 0 ]; then orch_log "reconcile: OK (registry <-> lock consistent)"; exit 0
else orch_err "reconcile: DIVERGENCE (registry is authority; regenerate the stale lock)"; exit 1; fi
