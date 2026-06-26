#!/usr/bin/env bash
# bin/orchestrator.sh — ecosystem orchestrator CLI (reorg-v2). The single owner of the
# ld<->cpp relationship. Subcommands:
#   vendor <id>        vendor a global capability into cpp via a governed PR (WS-7)
#   delete <id>        propagate a master delete via a governed cpp deletion PR (WS-7)
#   consistency [id..] verify master<->cpp vendored-payload content is in sync (Decision A control)
#   dedup  <id>        DEPRECATED (Decision A): symlink-dedup abandoned; --reverse un-arms a legacy link
#   sync               refresh the orchestrator's own install state (WS-9)
#   self-heal          bounded verifier-driven retry loop (WS-9)
#   install            install the orchestrator's triggers + state (ORCH-C, WS-9)
#   zero-link <m> <p>  forensic INV-zero-link assertion (mode global|cpp)
#   doctor             read-only health check
set -uo pipefail
ORCH_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$ORCH_BIN_DIR/../lib/common.sh"

cmd_help() { sed -n '2,12p' "$0"; }

cmd_zero_link() {
  local mode="${1:-}" path="${2:-}"
  [ -n "$mode" ] && [ -n "$path" ] || { orch_err "usage: zero-link <global|cpp> <path>"; return 2; }
  if orch_zero_link "$mode" "$path"; then orch_log "zero-link OK ($mode): $path"; return 0
  else orch_err "zero-link FAILED ($mode): $path"; return 1; fi
}

cmd_doctor() {
  local rc=0
  echo "== orchestrator doctor =="
  if [ -f "$ORCH_CONFIG" ]; then echo "  PASS  config present ($ORCH_CONFIG)"; else echo "  FAIL  config missing"; rc=1; fi
  for f in forbidden-cpp.txt forbidden-ld.txt; do
    [ -f "$ORCH_FORBIDDEN_DIR/$f" ] && echo "  PASS  $f present" || { echo "  FAIL  $f missing"; rc=1; }
  done
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then echo "  PASS  gh authenticated"; else echo "  WARN  gh not authenticated"; fi
  local sg; sg="$(orch_expand "$(orch_cfg_get source_skills_global)")"
  [ -d "$sg" ] && echo "  PASS  source skills present ($sg)" || echo "  WARN  source skills missing ($sg)"
  local cpp; cpp="$(orch_cfg_get cpp_repo)"
  if command -v gh >/dev/null 2>&1; then
    local perm; perm="$(gh repo view "$cpp" --json viewerPermission -q .viewerPermission 2>/dev/null || true)"
    case "$perm" in ADMIN|WRITE|MAINTAIN) echo "  PASS  cpp access: $perm ($cpp)" ;; "") echo "  WARN  cpp not reachable ($cpp)" ;; *) echo "  WARN  cpp read-only: $perm ($cpp)" ;; esac
  fi
  echo; [ "$rc" -eq 0 ] && echo "doctor: OK" || echo "doctor: FAILED"; return "$rc"
}

# --- WS-7 (vendor/delete) and WS-8 (dedup) and WS-9 (sync/self-heal/install) fill these in. ---
cmd_vendor()   { bash "$ORCH_BIN_DIR/../lib/vendor.sh" "$@"; }
cmd_delete()   { bash "$ORCH_BIN_DIR/../lib/vendor.sh" --delete "$@"; }
cmd_consistency() { bash "$ORCH_BIN_DIR/../lib/consistency.sh" "$@"; }
cmd_dedup()    { bash "$ORCH_BIN_DIR/../lib/dedup.sh" "$@"; }
cmd_sync()     { bash "$ORCH_BIN_DIR/../lib/selfmanage.sh" sync "$@"; }
cmd_selfheal() { bash "$ORCH_BIN_DIR/../lib/selfmanage.sh" self-heal "$@"; }
cmd_install()  { bash "$ORCH_BIN_DIR/../lib/selfmanage.sh" install "$@"; }

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    vendor)     cmd_vendor "$@" ;;
    delete)     cmd_delete "$@" ;;
    consistency) cmd_consistency "$@" ;;
    dedup)      cmd_dedup "$@" ;;
    sync)       cmd_sync "$@" ;;
    self-heal)  cmd_selfheal "$@" ;;
    install)    cmd_install "$@" ;;
    zero-link)  cmd_zero_link "$@" ;;
    doctor)     cmd_doctor "$@" ;;
    -h|--help|help) cmd_help ;;
    *) orch_err "unknown subcommand: $sub"; cmd_help; exit 2 ;;
  esac
}
main "$@"
