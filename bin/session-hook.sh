#!/usr/bin/env bash
# bin/session-hook.sh — the orchestrator trigger body (reorg-v2 WS-9 / ORCH-C). Shared by:
#   * the Cursor sessionStart user hook (runs once per session), and
#   * the launchd agent (RunAtLoad at login + every StartInterval).
# FAIL-OPEN by contract: it must NEVER block a session, so it always exits 0 and only logs.
#   modes:  (none) = quick read-only doctor;  --periodic = doctor + self-heal + DRY-RUN sync.
set -uo pipefail
# Resolve through symlinks FIRST: Cursor installs this hook as
# ~/.cursor/hooks/orchestrator-session.sh -> <repo>/bin/session-hook.sh, so $0/BASH_SOURCE is the
# SYMLINK. Without resolving it, SELF_DIR would be ~/.cursor/hooks and the common.sh source below would
# miss → ORCH_ROOT/ORCH_CONFIG unbound under `set -u` → the hook aborts non-zero, BREAKING fail-open.
SRC="${BASH_SOURCE[0]:-$0}"
while [ -L "$SRC" ]; do
  _d="$(cd -P "$(dirname "$SRC")" >/dev/null 2>&1 && pwd)"
  SRC="$(readlink "$SRC")"; case "$SRC" in /*) ;; *) SRC="$_d/$SRC" ;; esac
done
SELF_DIR="$(cd -P "$(dirname "$SRC")" >/dev/null 2>&1 && pwd)"
. "$SELF_DIR/../lib/common.sh" 2>/dev/null || true
# Defensive defaults so the fail-open hook never trips `set -u` even if common.sh could not be sourced.
: "${ORCH_ROOT:=$(cd "$SELF_DIR/.." >/dev/null 2>&1 && pwd)}"
: "${ORCH_CONFIG:=$ORCH_ROOT/config/relationship.yml}"
LOG_DIR="$(orch_expand "$(orch_cfg_get work_clone_dir)")"; LOG_DIR="$(dirname "${LOG_DIR:-$HOME/.orchestrator-work/x}")"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/orchestrator.log"
MODE="${1:-}"
{
  echo "===== [$(date '+%Y-%m-%d %H:%M:%S')] session-hook ${MODE:-quick} ====="
  if [ "$MODE" = "--periodic" ]; then
    # launchd: full (network OK) — doctor + reconcile + consistency + heal + DRY-RUN sync. All
    # fail-open (|| true): a passive check must NEVER block. Never auto-merges to cpp.
    bash "$ORCH_ROOT/bin/orchestrator.sh" doctor 2>&1 | sed 's/^/  /' || true
    # B2/B3 authority: registry<->lock parity (local; registry wins on conflict).
    bash "$ORCH_ROOT/lib/reconcile.sh" 2>&1 | sed 's/^/  /' || true
    # B3 enrollment-drift + master<->payload content drift (read-only).
    bash "$ORCH_ROOT/lib/consistency.sh" 2>&1 | sed 's/^/  /' || true
    bash "$ORCH_ROOT/lib/selfmanage.sh" self-heal 2>&1 | sed 's/^/  /' || true
    # ORCH_SKIP_CPP_EXEC=1: an UNATTENDED periodic run must never execute cpp's Makefile/integrity
    # engine fetched from origin/main (RCE surface). Dry-run cpp-sync still detects drift; landing a
    # PR (needs a GREEN gate) stays operator-initiated via an explicit `orchestrator cpp-sync --execute`.
    ORCH_SKIP_CPP_EXEC=1 bash "$ORCH_ROOT/lib/selfmanage.sh" cpp-sync 2>&1 | sed 's/^/  /' || true
  else
    # sessionStart: keep it INSTANT + network-free (no gh calls) so it never slows a session.
    [ -f "$ORCH_CONFIG" ] && echo "  config present; orchestrator ready" || echo "  WARN config missing"
    # B3 in-session breadcrumb: reconcile is LOCAL (reads registry.yml + committed locks; no network),
    # so a quick registry<->lock divergence hint is cheap. Fail-open; only emits a one-liner on drift.
    if ! bash "$ORCH_ROOT/lib/reconcile.sh" >/dev/null 2>&1; then
      echo "  BREADCRUMB registry<->lock divergence — run 'orchestrator reconcile' (registry is authority)"
    fi
  fi
} >> "$LOG" 2>&1
exit 0
