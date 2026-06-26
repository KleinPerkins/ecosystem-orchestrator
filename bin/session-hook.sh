#!/usr/bin/env bash
# bin/session-hook.sh — the orchestrator trigger body (reorg-v2 WS-9 / ORCH-C). Shared by:
#   * the Cursor sessionStart user hook (runs once per session), and
#   * the launchd agent (RunAtLoad at login + every StartInterval).
# FAIL-OPEN by contract: it must NEVER block a session, so it always exits 0 and only logs.
#   modes:  (none) = quick read-only doctor;  --periodic = doctor + self-heal + DRY-RUN sync.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SELF_DIR/../lib/common.sh"
LOG_DIR="$(orch_expand "$(orch_cfg_get work_clone_dir)")"; LOG_DIR="$(dirname "${LOG_DIR:-$HOME/.orchestrator-work/x}")"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/orchestrator.log"
MODE="${1:-}"
{
  echo "===== [$(date '+%Y-%m-%d %H:%M:%S')] session-hook ${MODE:-quick} ====="
  if [ "$MODE" = "--periodic" ]; then
    # launchd: full (network OK) — doctor + heal + DRY-RUN sync. Never auto-merges to cpp.
    bash "$ORCH_ROOT/bin/orchestrator.sh" doctor 2>&1 | sed 's/^/  /' || true
    bash "$ORCH_ROOT/lib/selfmanage.sh" self-heal 2>&1 | sed 's/^/  /' || true
    # ORCH_SKIP_CPP_EXEC=1: an UNATTENDED periodic run must never execute cpp's Makefile/integrity
    # engine fetched from origin/main (RCE surface). Dry-run sync still detects+stages drift; landing
    # a PR (which needs a GREEN gate) stays operator-initiated via an explicit `orchestrator sync --execute`.
    ORCH_SKIP_CPP_EXEC=1 bash "$ORCH_ROOT/lib/selfmanage.sh" sync 2>&1 | sed 's/^/  /' || true
  else
    # sessionStart: keep it INSTANT + network-free (no gh calls) so it never slows a session.
    [ -f "$ORCH_CONFIG" ] && echo "  config present; orchestrator ready" || echo "  WARN config missing"
  fi
} >> "$LOG" 2>&1
exit 0
