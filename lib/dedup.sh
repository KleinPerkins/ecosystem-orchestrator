#!/usr/bin/env bash
# lib/dedup.sh — single-master-copy dedup (reorg-v2 WS-8 / D-9). On LD's machine, replace a cpp
# vendored copy with a SYMLINK to the global master so there is exactly one real copy to maintain.
#
#   dedup.sh [--apply] [--cpp-dir DIR] <id>
#     (default)  DRY-RUN: report the master, the vendored target, and the backup that --apply would take.
#     --apply    back up the target OUT-OF-TREE, then replace it with a symlink -> master; verify.
#     --cpp-dir  the cpp tree to dedup against (default: config ld_cpp_worktree).
#
# SAFETY (why the live swap is DEFERRED by default — Deviation-1):
#   * A symlink in the cpp working tree points at an ld path (~/dev/...) — committing it would both
#     dirty cpp and LEAK an ld path (zero-link). So this is a LOCAL-ONLY disk optimization.
#   * Therefore --apply REFUSES a git-TRACKED target unless ORCH_DEDUP_ALLOW_TRACKED=1 is set
#     (sandbox/untracked targets proceed). Always backs up before touching anything. Idempotent.
set -uo pipefail
DD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$DD_LIB_DIR/common.sh"

APPLY=0 CPP_DIR=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1 ;;
    --cpp-dir) CPP_DIR="${2:-}"; shift ;;
    -*) orch_err "unknown flag: $1"; exit 2 ;;
    *) args+=("$1") ;;
  esac; shift
done
ID="${args[0]:-}"
[ -n "$ID" ] || { orch_err "usage: dedup.sh [--apply] [--cpp-dir DIR] <id>"; exit 2; }

QUIVER="$(orch_cfg_get cpp_quiver_path)"; QUIVER="${QUIVER:-quiver}"
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
MASTER="$SRC_GLOBAL/$ID"
[ -d "$MASTER" ] || { orch_err "master not found: $MASTER"; exit 1; }

[ -n "$CPP_DIR" ] || CPP_DIR="$(orch_expand "$(orch_cfg_get ld_cpp_worktree)")"
[ -n "$CPP_DIR" ] || { orch_err "no cpp tree (pass --cpp-dir or set ld_cpp_worktree)"; exit 2; }
[ -d "$CPP_DIR" ] || { orch_err "cpp tree not found: $CPP_DIR"; exit 1; }

TARGET="$(cd "$CPP_DIR" && for d in "$QUIVER"/*/"$ID"; do [ -e "$d" ] && { printf '%s/%s\n' "$CPP_DIR" "$d"; break; }; done)"
[ -n "$TARGET" ] || { orch_err "no vendored copy $QUIVER/*/$ID under $CPP_DIR"; exit 1; }

if [ -L "$TARGET" ]; then
  orch_log "already deduped: $TARGET -> $(readlink "$TARGET")"; exit 0
fi

orch_log "master:  $MASTER"
orch_log "target:  $TARGET"

# git-tracked guard (enforces Deviation-1 for the real cpp worktree).
tracked=0
if git -C "$CPP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rel="${TARGET#"$CPP_DIR"/}"
  if git -C "$CPP_DIR" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then tracked=1; fi
fi

if [ "$APPLY" != 1 ]; then
  orch_log "DRY-RUN: --apply would back up the target out-of-tree, then symlink it to the master."
  [ "$tracked" = 1 ] && orch_warn "target is git-TRACKED — live swap is DEFERRED (Deviation-1); set ORCH_DEDUP_ALLOW_TRACKED=1 to override."
  exit 0
fi

if [ "$tracked" = 1 ] && [ "${ORCH_DEDUP_ALLOW_TRACKED:-0}" != 1 ]; then
  orch_err "REFUSING: target is git-tracked (a symlink would dirty cpp / leak an ld path). Deviation-1 keeps this deferred. Override: ORCH_DEDUP_ALLOW_TRACKED=1"
  exit 3
fi

bk="$(orch_backup_outoftree "$TARGET" "dedup-$ID")"
orch_log "backup (out-of-tree): $bk"
rm -rf "$TARGET"
ln -s "$MASTER" "$TARGET"
# verify: resolves to master + a sample file is readable through the link.
if [ -L "$TARGET" ] && [ "$(readlink "$TARGET")" = "$MASTER" ] && [ -e "$TARGET/SKILL.md" -o -d "$TARGET" ]; then
  orch_log "deduped: $TARGET -> $MASTER"
else
  orch_err "verify failed; restoring from backup"; rm -f "$TARGET"; ( cd "$(dirname "$TARGET")" && tar -xzf "$bk" ); exit 1
fi
