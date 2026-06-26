#!/usr/bin/env bash
# lib/consistency.sh — Decision-A compensating control (reorg-v2 WS-8 / Decision A, 2026-06-26).
#
# Symlink-dedup is ABANDONED, so cpp keeps a REAL vendored copy of each global capability (byte-identical
# to what teammates clone). The invariant "one master copy" is intentionally relaxed; THIS verify is the
# compensating control that replaces it. It asserts the SHARED CONTENT of every managed item is
# byte-identical between the ld master and the cpp vendored payload, and flags drift in either direction
# (master file missing/changed in the payload, an orphan in the payload, or a legacy symlink left armed).
#
# Read-only — never mutates either tree. Exit 0 = all in sync; 1 = drift; 2 = could not run.
#
#   consistency.sh [--cpp-dir DIR] [<id> ...]
#     (no ids)   check every id in config/managed-items.txt
#     <id>...    check just those ids
#
# "Shared content" = everything the vendor actually copies: the master files EXCEPT the ld-management
# artifacts (meta.yml, install.sh) and vcs/cache noise; on the payload side VENDORED.md + the translated
# meta.yml are likewise excluded (they are vendor-authored, not shared).
set -uo pipefail
C_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$C_LIB_DIR/common.sh"

CPP_DIR=""; ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cpp-dir) CPP_DIR="${2:-}"; shift ;;
    -*) orch_err "unknown flag: $1"; exit 2 ;;
    *) ids+=("$1") ;;
  esac; shift
done

QUIVER="$(orch_cfg_get cpp_quiver_path)"; QUIVER="${QUIVER:-quiver}"
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
[ -n "$CPP_DIR" ] || CPP_DIR="$(orch_expand "$(orch_cfg_get ld_cpp_worktree)")"
MANAGED="$ORCH_ROOT/config/managed-items.txt"

[ -d "$SRC_GLOBAL" ] || { orch_err "consistency: master skills dir missing: $SRC_GLOBAL"; exit 2; }
[ -d "$CPP_DIR" ]    || { orch_err "consistency: cpp tree not found: $CPP_DIR (pass --cpp-dir or set ld_cpp_worktree)"; exit 2; }

if [ "${#ids[@]}" -eq 0 ] && [ -f "$MANAGED" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && ids+=("$line")
  done < "$MANAGED"
fi
[ "${#ids[@]}" -gt 0 ] || { orch_warn "consistency: no managed items to check"; exit 0; }

# shared_list <dir> — relative paths of the shared content set, sorted (stable across machines).
shared_list() {
  ( cd "$1" 2>/dev/null && find . -type f \
      ! -name meta.yml ! -name install.sh ! -name VENDORED.md \
      ! -path '*/.git/*' ! -path '*/__pycache__/*' ! -name '*.pyc' \
      | sed 's|^\./||' | LC_ALL=C sort )
}

echo "== orchestrator consistency (master <-> cpp vendored payload) =="
drift=0
for id in "${ids[@]}"; do
  master="$SRC_GLOBAL/$id"
  if [ ! -d "$master" ]; then printf '  DRIFT  %s: master missing (%s)\n' "$id" "$master"; drift=1; continue; fi
  target="$(cd "$CPP_DIR" && for d in "$QUIVER"/*/"$id"; do [ -e "$d" ] && { printf '%s/%s\n' "$CPP_DIR" "$d"; break; }; done)"
  if [ -z "$target" ]; then printf '  DRIFT  %s: not vendored under %s/%s/*\n' "$id" "$CPP_DIR" "$QUIVER"; drift=1; continue; fi
  if [ -L "$target" ]; then printf '  DRIFT  %s: vendored path is a LEGACY symlink — un-arm with dedup.sh --reverse\n' "$id"; drift=1; continue; fi
  item_drift=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if   [ ! -f "$target/$f" ];        then printf '  DRIFT  %s: missing in cpp payload: %s\n'  "$id" "$f"; item_drift=1
    elif ! cmp -s "$master/$f" "$target/$f"; then printf '  DRIFT  %s: content differs: %s\n'   "$id" "$f"; item_drift=1; fi
  done <<EOF
$(shared_list "$master")
EOF
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$master/$f" ] || { printf '  DRIFT  %s: orphan in cpp payload (absent in master): %s\n' "$id" "$f"; item_drift=1; }
  done <<EOF
$(shared_list "$target")
EOF
  [ "$item_drift" = 0 ] && printf '  OK     %s: master<->payload content in sync\n' "$id" || drift=1
done

echo
if [ "$drift" = 0 ]; then orch_log "consistency: OK (all managed items in sync)"; exit 0
else orch_err "consistency: DRIFT detected (re-sync with: orchestrator sync --execute, or reverse a legacy symlink)"; exit 1; fi
