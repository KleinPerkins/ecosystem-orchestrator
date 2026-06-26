#!/usr/bin/env bash
# lib/dedup.sh — single-master-copy dedup (reorg-v2 WS-8 / D-1). On LD's machine, replace a cpp
# vendored copy with a SYMLINK to the global master so there is exactly one real copy to maintain.
#
#   dedup.sh [--apply|--reverse|--reassert] [--cpp-dir DIR] <id>
#     (default)    DRY-RUN: report the master, the vendored target, and what --apply would do.
#     --apply      perform the dedup. Idempotent. For a git-TRACKED cpp target this is the SAFE LIVE
#                  mode (gated behind ORCH_DEDUP_ALLOW_TRACKED=1, default refusal preserved).
#     --reverse    the documented INVERSE of a tracked dedup (clears skip-worktree, restores the real
#                  vendored files from cpp's index, drops the local exclude). Returns cpp to pristine.
#     --reassert   re-assert skip-worktree (+ exclude) on an already-deduped target; no-op otherwise.
#                  Called by the orchestrator sync path so dedup survives a re-sync and cpp never dirties.
#     --cpp-dir    the cpp tree to operate on (default: config ld_cpp_worktree).
#
# SAFE LIVE MODE — D-1 resolution (LD-only, LOCAL-ONLY; never committed/pushed to cpp). In order:
#   1. back up the current cpp vendored copy OUT-OF-TREE (timestamped archive);
#   2. `git update-index --skip-worktree` every tracked file under the target FIRST, so the swap
#      cannot dirty cpp;
#   3. add the target to `.git/info/exclude` (local-only) so the replacement symlink is not reported
#      as an untracked path;
#   4. replace the real files with a symlink -> the global MASTER.
# This is sanctioned on the cpp worktree precisely because it is purely local: the tracked/pushed cpp
# content is unchanged, INV-zero-link holds for the repo, and `git status` stays clean.
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
[ -n "$ID" ] || { orch_err "usage: dedup.sh [--apply|--reverse|--reassert] [--cpp-dir DIR] <id>"; exit 2; }

QUIVER="$(orch_cfg_get cpp_quiver_path)"; QUIVER="${QUIVER:-quiver}"
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
MASTER="$SRC_GLOBAL/$ID"
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
# REASSERT — re-apply skip-worktree (+exclude) on an already-deduped target; no-op otherwise.
# Used by the sync path so a deduped copy survives a re-sync without dirtying cpp.
# =================================================================================================
if [ "$MODE" = "reassert" ]; then
  if [ -L "$TARGET" ] && [ "$tracked" = 1 ]; then
    sw_set; exclude_add
    status_clean_for_rel && orch_log "reasserted: skip-worktree+exclude set; cpp clean for $REL" \
                         || { orch_warn "reassert: $REL not clean after re-set"; exit 1; }
  else
    orch_log "reassert: $REL not deduped (no symlink) — no-op"
  fi
  exit 0
fi

# =================================================================================================
# DRY-RUN
# =================================================================================================
if [ "$MODE" = "dryrun" ]; then
  if [ -L "$TARGET" ]; then orch_log "DRY-RUN: already a symlink -> $(readlink "$TARGET")"; exit 0; fi
  orch_log "DRY-RUN: --apply would back up out-of-tree, skip-worktree the tracked files, add a local"
  orch_log "         exclude, then symlink $REL -> the master."
  if [ "$tracked" = 1 ] && [ "${ORCH_DEDUP_ALLOW_TRACKED:-0}" != 1 ]; then
    orch_warn "target is git-TRACKED — safe live swap requires ORCH_DEDUP_ALLOW_TRACKED=1 (default refusal)."
  fi
  exit 0
fi

# =================================================================================================
# APPLY
# =================================================================================================
# Idempotency: a correct symlink already in place -> re-assert (harmless) and report no-op.
if [ -L "$TARGET" ] && [ "$(readlink "$TARGET")" = "$MASTER" ]; then
  if [ "$tracked" = 1 ]; then sw_set; exclude_add; fi
  orch_log "already deduped (idempotent): $TARGET -> $MASTER"
  exit 0
fi

# Untracked target (sandbox / not in cpp index): simple backup + swap (original behavior).
if [ "$tracked" != 1 ]; then
  bk="$(orch_backup_outoftree "$TARGET" "dedup-$ID")"; orch_log "backup (out-of-tree): $bk"
  rm -rf "$TARGET"; ln -s "$MASTER" "$TARGET"
  if [ -L "$TARGET" ] && [ "$(readlink "$TARGET")" = "$MASTER" ]; then orch_log "deduped (untracked): $TARGET -> $MASTER"; exit 0
  else orch_err "verify failed; restoring"; rm -f "$TARGET"; ( cd "$(dirname "$TARGET")" && tar -xzf "$bk" ); exit 1; fi
fi

# Tracked target: SAFE LIVE MODE, gated.
if [ "${ORCH_DEDUP_ALLOW_TRACKED:-0}" != 1 ]; then
  orch_err "REFUSING: target is git-tracked. The safe live swap is LD-only + opt-in. Override: ORCH_DEDUP_ALLOW_TRACKED=1"
  exit 3
fi

bk="$(orch_backup_outoftree "$TARGET" "dedup-$ID")"; orch_log "backup (out-of-tree): $bk"
orch_log "skip-worktree: $(git -C "$CPP_DIR" ls-files -- "$REL" | wc -l | tr -d ' ') tracked file(s) under $REL"
sw_set                       # 2) skip-worktree FIRST so the swap can't dirty cpp
exclude_add                  # 3) local-only exclude so the symlink isn't an untracked entry
rm -rf "$TARGET"             # 4) swap the real files for a symlink -> master
ln -s "$MASTER" "$TARGET"

# verify: symlink resolves to master, master content readable, skip-worktree set, cpp clean for REL.
ok=1
[ -L "$TARGET" ] && [ "$(readlink "$TARGET")" = "$MASTER" ] || { orch_err "verify: not a symlink->master"; ok=0; }
[ -e "$TARGET/SKILL.md" ] || [ -d "$TARGET" ] || { orch_err "verify: master content unreadable via link"; ok=0; }
sw_is_set || { orch_err "verify: skip-worktree not fully set"; ok=0; }
status_clean_for_rel || { orch_err "verify: cpp not clean for $REL"; ok=0; }

if [ "$ok" = 1 ]; then
  orch_log "deduped (safe live): $TARGET -> $MASTER  [skip-worktree set; exclude added; cpp clean]"
  orch_log "reverse with: dedup.sh --reverse --cpp-dir \"$CPP_DIR\" $ID"
  exit 0
fi
orch_err "verify failed — rolling back to pristine"
sw_clear; rm -f "$TARGET"; git -C "$CPP_DIR" checkout -- "$REL" 2>/dev/null || ( cd "$(dirname "$TARGET")" && tar -xzf "$bk" ); exclude_rm
exit 1
