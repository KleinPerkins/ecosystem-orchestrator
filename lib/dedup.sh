#!/usr/bin/env bash
# lib/dedup.sh — DEPRECATED single-master-copy dedup (reorg-v2 WS-8 / D-1; ABANDONED by Decision A).
#
# Decision A (2026-06-26): the live symlink-into-master dedup is ABANDONED. cpp keeps the REAL vendored
# copy (byte-identical to what teammates clone); master<->payload integrity is now enforced by the
# sync-time CONSISTENCY VERIFY (lib/consistency.sh), NOT by collapsing the two copies into one symlink.
# Why abandoned: (1) UNSAFE — routine cpp git ops (branch switch / re-vendor) write THROUGH the symlink
# into the global SOT; (2) SEMANTICALLY WRONG — the master is a self-managed skill, the vendored payload
# is an ld-agnostic copy, so master != payload and the local view diverged from the shipped bytes.
# INV-master-copy is intentionally RELAXED: two real copies are accepted, with the consistency verify as
# the compensating control.
#
#   dedup.sh --reverse [--cpp-dir DIR] <id>   ONE-TIME migration/safety util — undo a previously-applied
#                                             live dedup: clear skip-worktree, restore the real vendored
#                                             files from cpp's index, drop the local exclude. Returns cpp
#                                             to its pristine committed state. NOTHING auto-calls this.
#   dedup.sh [--apply|--reassert] ...         HARD-DISABLED (Decision A) — refuses. Use the consistency
#                                             verify instead: `orchestrator consistency` / `make eco-consistency`.
#   (default)                                 DRY-RUN: print current state + this deprecation notice.
#
# --reverse is retained ONLY so a machine still carrying a pre-Decision-A symlink can be un-armed.
set -uo pipefail
DD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$DD_LIB_DIR/common.sh"

MODE="dryrun" CPP_DIR=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)     MODE="apply" ;;
    --reverse)   MODE="reverse" ;;
    --reassert)  MODE="reassert" ;;
    --cpp-dir)   CPP_DIR="${2:-}"; shift ;;
    -*) orch_err "unknown flag: $1"; exit 2 ;;
    *) args+=("$1") ;;
  esac; shift
done
ID="${args[0]:-}"
[ -n "$ID" ] || { orch_err "usage: dedup.sh --reverse [--cpp-dir DIR] <id>  (--apply/--reassert disabled by Decision A; use the consistency verify)"; exit 2; }

QUIVER="$(orch_cfg_get cpp_quiver_path)"; QUIVER="${QUIVER:-quiver}"
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
MASTER="$(orch_resolve_skill_master "$SRC_GLOBAL" "$ID" 2>/dev/null || true)"
[ -n "$MASTER" ] || MASTER="$SRC_GLOBAL/skills/$ID"
[ -d "$MASTER" ] || { orch_err "master not found: $MASTER"; exit 1; }

[ -n "$CPP_DIR" ] || CPP_DIR="$(orch_expand "$(orch_cfg_get ld_cpp_worktree)")"
[ -n "$CPP_DIR" ] || { orch_err "no cpp tree (pass --cpp-dir or set ld_cpp_worktree)"; exit 2; }
[ -d "$CPP_DIR" ] || { orch_err "cpp tree not found: $CPP_DIR"; exit 1; }

TARGET="$(cd "$CPP_DIR" && for d in "$QUIVER"/*/"$ID"; do [ -e "$d" ] && { printf '%s/%s\n' "$CPP_DIR" "$d"; break; }; done)"
[ -n "$TARGET" ] || { orch_err "no vendored copy $QUIVER/*/$ID under $CPP_DIR"; exit 1; }
REL="${TARGET#"$CPP_DIR"/}"

# --- git-tracked detection ------------------------------------------------------------------------
is_git() { git -C "$CPP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
tracked=0
if is_git && git -C "$CPP_DIR" ls-files --error-unmatch -- "$REL" >/dev/null 2>&1; then tracked=1; fi

# --- helpers (skip-worktree + local exclude, all LOCAL-ONLY) --------------------------------------
sw_set()   { git -C "$CPP_DIR" ls-files -z -- "$REL" | git -C "$CPP_DIR" update-index --skip-worktree -z --stdin; }
sw_clear() { git -C "$CPP_DIR" ls-files -z -- "$REL" | git -C "$CPP_DIR" update-index --no-skip-worktree -z --stdin; }
sw_is_set(){ # true iff EVERY tracked entry under REL carries the skip-worktree bit (ls-files -v => 'S')
  local total marked
  total="$(git -C "$CPP_DIR" ls-files -- "$REL" | wc -l | tr -d ' ')"
  marked="$(git -C "$CPP_DIR" ls-files -v -- "$REL" | grep -c '^S' || true)"
  [ "$total" -gt 0 ] && [ "$total" = "$marked" ]
}
exclude_file() { # absolute path to this clone's info/exclude (handles worktrees + relative output)
  ( cd "$CPP_DIR" 2>/dev/null || exit 0
    p="$(git rev-parse --git-path info/exclude 2>/dev/null)" || exit 0
    case "$p" in /*) printf '%s\n' "$p" ;; *) printf '%s/%s\n' "$PWD" "$p" ;; esac )
}
exclude_add() {
  local ef; ef="$(exclude_file)"; [ -n "$ef" ] || return 0
  mkdir -p "$(dirname "$ef")"; touch "$ef"
  grep -qxF "/$REL" "$ef" 2>/dev/null || printf '/%s\n' "$REL" >> "$ef"
}
exclude_rm() {
  local ef; ef="$(exclude_file)"; [ -f "$ef" ] || return 0
  grep -vxF "/$REL" "$ef" > "$ef.tmp.$$" 2>/dev/null || true
  mv "$ef.tmp.$$" "$ef"
}
status_clean_for_rel() { [ -z "$(git -C "$CPP_DIR" status --porcelain -- "$REL" 2>/dev/null)" ]; }

orch_log "id:      $ID"
orch_log "master:  $MASTER"
orch_log "target:  $TARGET ($([ "$tracked" = 1 ] && echo git-tracked || echo untracked))"

# =================================================================================================
# REVERSE — undo a tracked dedup, returning cpp to pristine committed state.
# =================================================================================================
if [ "$MODE" = "reverse" ]; then
  if [ ! -L "$TARGET" ]; then orch_log "not deduped (target is not a symlink) — nothing to reverse"; exit 0; fi
  if [ "$tracked" != 1 ]; then orch_err "--reverse supports git-tracked targets only (untracked: restore from backup manually)"; exit 2; fi
  orch_log "reverse: clear skip-worktree -> remove symlink -> restore vendored files -> drop exclude"
  sw_clear
  rm -f "$TARGET"
  git -C "$CPP_DIR" checkout -- "$REL" || { orch_err "git checkout failed restoring $REL"; exit 1; }
  exclude_rm
  if [ ! -L "$TARGET" ] && [ -d "$TARGET" ] && status_clean_for_rel; then
    orch_log "reversed: $REL restored to committed vendored copy; cpp clean for this path"
    exit 0
  fi
  orch_err "reverse verify failed (REL not clean or not a dir)"; exit 1
fi

# =================================================================================================
# REASSERT / APPLY — HARD-DISABLED by Decision A (abandon symlink-dedup).
# =================================================================================================
if [ "$MODE" = "reassert" ] || [ "$MODE" = "apply" ]; then
  orch_err "dedup --$MODE is HARD-DISABLED (Decision A: symlink-dedup abandoned; cpp keeps the real"
  orch_err "vendored copy). master<->payload integrity is enforced by the consistency verify instead:"
  orch_err "    orchestrator consistency        # report drift"
  orch_err "    make eco-consistency            # same, from ~/dev"
  orch_err "To un-arm a legacy live symlink from before Decision A, use: dedup.sh --reverse <id>."
  exit 3
fi

# =================================================================================================
# DRY-RUN — report state + deprecation notice.
# =================================================================================================
if [ "$MODE" = "dryrun" ]; then
  orch_warn "DEPRECATED: symlink-dedup is ABANDONED (Decision A). cpp keeps the real vendored copy."
  if [ -L "$TARGET" ]; then
    orch_warn "LEGACY live symlink present: $TARGET -> $(readlink "$TARGET")"
    orch_warn "Un-arm it with: dedup.sh --reverse --cpp-dir \"$CPP_DIR\" $ID"
  else
    orch_log "$REL is a real directory (correct end-state under Decision A) — nothing to do."
  fi
  orch_log "Integrity is now verified by: orchestrator consistency / make eco-consistency."
  exit 0
fi
