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
. "$C_LIB_DIR/payload.sh"

CPP_DIR=""; ids=(); ids_explicit=0
while [ $# -gt 0 ]; do
  case "$1" in
    --cpp-dir) CPP_DIR="${2:-}"; shift ;;
    -*) orch_err "unknown flag: $1"; exit 2 ;;
    *) ids+=("$1"); ids_explicit=1 ;;
  esac; shift
done
drift=0

QUIVER="$(orch_cfg_get cpp_quiver_path)"; QUIVER="${QUIVER:-quiver}"
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
SRC_MCP_LOCAL="$(orch_expand "$(orch_cfg_get source_mcp_local)")"
[ -n "$CPP_DIR" ] || CPP_DIR="$(orch_expand "$(orch_cfg_get ld_cpp_worktree)")"
MANAGED="$ORCH_ROOT/config/managed-items.txt"

[ -d "$SRC_GLOBAL" ] || { orch_err "consistency: master skills dir missing: $SRC_GLOBAL"; exit 2; }
[ -d "$CPP_DIR" ]    || { orch_err "consistency: cpp tree not found: $CPP_DIR (pass --cpp-dir or set ld_cpp_worktree)"; exit 2; }

# Resolve a master capability dir by id. Skills live under source_skills_global; mcp masters
# live flat under source_mcp_local. Returns empty on miss.
resolve_master() {
  local id="$1"
  if [ -d "$SRC_GLOBAL/$id" ]; then printf '%s\n' "$SRC_GLOBAL/$id"; return 0; fi
  if [ -n "$SRC_MCP_LOCAL" ] && [ -d "$SRC_MCP_LOCAL/$id" ]; then printf '%s\n' "$SRC_MCP_LOCAL/$id"; return 0; fi
  return 1
}

if [ "${#ids[@]}" -eq 0 ] && [ -f "$MANAGED" ]; then
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && ids+=("$line")
  done < "$MANAGED"
fi
[ "${#ids[@]}" -gt 0 ] || { orch_warn "consistency: no managed items to check"; exit 0; }

# Enrollment-drift check (added 2026-06-26). The orchestrator's managed-items.txt is a manually-
# maintained list; the disk state (scope:global masters under SRC_GLOBAL + SRC_MCP_LOCAL) is the
# ground truth. Whenever a global capability is added/removed and someone forgets to update
# managed-items.txt, the orchestrator silently ignores it. This check diffs the two and reports
# either direction as DRIFT, EXCEPT ids marked `# excluded: <id> -- <reason>` in MANAGED.
# Only runs when caller asked for the full list (no explicit ids on the command line).
if [ "$ids_explicit" = 0 ] && [ -f "$MANAGED" ]; then
  enroll_drift=0
  # Read the enrolled set + exclusions from MANAGED.
  enrolled_set=" $(printf '%s ' "${ids[@]}")"
  excluded_set=" $(awk '/^[[:space:]]*#[[:space:]]*excluded:/ {
    sub(/^[[:space:]]*#[[:space:]]*excluded:[[:space:]]*/, "")
    sub(/[[:space:]]+--.*$/, "")
    sub(/[[:space:]]+$/, "")
    print
  }' "$MANAGED" | tr '\n' ' ')"
  # Discover on-disk scope:global ids. Skills: any dir under SRC_GLOBAL (dir-paradigm guarantees
  # scope:global). Mcp: any subdir of SRC_MCP_LOCAL whose meta.yml declares scope: global.
  disk_globals=""
  if [ -d "$SRC_GLOBAL" ]; then
    for d in "$SRC_GLOBAL"/*/; do
      [ -d "$d" ] || continue
      disk_globals="$disk_globals $(basename "$d")"
    done
  fi
  if [ -n "$SRC_MCP_LOCAL" ] && [ -d "$SRC_MCP_LOCAL" ]; then
    for d in "$SRC_MCP_LOCAL"/*/; do
      [ -f "$d/meta.yml" ] || continue
      s="$(awk -F': *' '/^scope:/{print $2; exit}' "$d/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
      [ "$s" = "global" ] || continue
      disk_globals="$disk_globals $(basename "$d")"
    done
  fi
  # Direction 1: scope:global on disk but NOT enrolled and NOT excluded.
  for g in $disk_globals; do
    case "$enrolled_set" in *" $g "*) continue ;; esac
    case "$excluded_set" in *" $g "*) continue ;; esac
    printf '  DRIFT  %s: scope:global on disk but not in managed-items.txt (add it, or mark `# excluded: %s -- <reason>`)\n' "$g" "$g"
    enroll_drift=1
  done
  # Direction 2: enrolled in managed-items.txt but the master is missing/non-global on disk.
  for e in "${ids[@]}"; do
    m=""; for d in "$SRC_GLOBAL/$e" "$SRC_MCP_LOCAL/$e"; do [ -d "$d" ] && { m="$d"; break; }; done
    if [ -z "$m" ]; then
      printf '  DRIFT  %s: enrolled in managed-items.txt but no master found under SRC_GLOBAL or SRC_MCP_LOCAL\n' "$e"
      enroll_drift=1
      continue
    fi
    s="$(awk -F': *' '/^scope:/{print $2; exit}' "$m/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
    if [ -n "$s" ] && [ "$s" != "global" ]; then
      printf '  DRIFT  %s: enrolled but master scope=%s (only scope:global is vendorable; drop the enrollment + run `orchestrator delete %s`)\n' "$e" "$s" "$e"
      enroll_drift=1
    fi
  done
  if [ "$enroll_drift" = 1 ]; then
    drift=1
    echo
  else
    printf '  OK     enrollment: managed-items.txt matches the on-disk scope:global set (exclusions honored)\n'
  fi
fi

# shared_list <dir> — relative paths of the shared content set, sorted (stable across machines).
shared_list() {
  ( cd "$1" 2>/dev/null && find . -type f \
      ! -name meta.yml ! -name install.sh ! -name VENDORED.md \
      ! -path '*/.git/*' ! -path '*/__pycache__/*' ! -name '*.pyc' \
      | sed 's|^\./||' | LC_ALL=C sort )
}

echo "== orchestrator consistency (master <-> cpp vendored payload) =="
for id in "${ids[@]}"; do
  master="$(resolve_master "$id" || true)"
  if [ -z "$master" ]; then printf '  DRIFT  %s: master missing (no skills/global or mcp/<id>)\n' "$id"; drift=1; continue; fi
  # Defense-in-depth scope gate (Option A; 2026-06-26): non-global masters must not be in
  # managed-items.txt. Flag as drift so the enrollment can be corrected (drop the entry
  # and/or `orchestrator delete <id>` to purge any stranded cpp payload).
  mscope="$(awk -F': *' '/^scope:/{print $2; exit}' "$master/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
  if [ -n "$mscope" ] && [ "$mscope" != "global" ]; then
    printf '  DRIFT  %s: master declares scope=%s but is enrolled in managed-items.txt (only scope:global is vendorable)\n' "$id" "$mscope"
    drift=1; continue
  fi
  target="$(cd "$CPP_DIR" && for d in "$QUIVER"/*/"$id"; do [ -e "$d" ] && { printf '%s/%s\n' "$CPP_DIR" "$d"; break; }; done)"
  if [ -z "$target" ]; then printf '  DRIFT  %s: not vendored under %s/%s/*\n' "$id" "$CPP_DIR" "$QUIVER"; drift=1; continue; fi
  if [ -L "$target" ]; then printf '  DRIFT  %s: vendored path is a LEGACY symlink — un-arm with dedup.sh --reverse\n' "$id"; drift=1; continue; fi

  # Kind-aware comparison. For `kind: mcp` masters the orchestrator vendors a SOURCE-FREE,
  # ld-agnostic discoverability descriptor (README.md + VENDORED.md + meta.yml only). Comparing
  # the master's source tree would always flag every source file as "missing in cpp payload",
  # so for mcp we (1) assert descriptor shape (required files present; no unexpected source),
  # then (2) REGENERATE the descriptor into a tmpdir using the same generators vendor.sh uses
  # and BYTE-COMPARE README.md + meta.yml against the cpp payload. This catches template drift
  # AND any hand-edit on the cpp side that vendor would clobber on the next sync — symmetric
  # with the skill path below. VENDORED.md is intentionally generic so stays shape-only.
  kind="$(awk -F': *' '/^kind:/{print $2; exit}' "$master/meta.yml" 2>/dev/null)"
  if [ "$kind" = "mcp" ]; then
    item_drift=0
    for f in README.md VENDORED.md meta.yml; do
      [ -f "$target/$f" ] || { printf '  DRIFT  %s: missing in cpp mcp descriptor: %s\n' "$id" "$f"; item_drift=1; }
    done
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        README.md|VENDORED.md|meta.yml) ;;
        *) printf '  DRIFT  %s: unexpected source file in cpp mcp descriptor: %s\n' "$id" "$f"; item_drift=1 ;;
      esac
    done <<EOF
$(cd "$target" 2>/dev/null && find . -type f ! -path '*/.git/*' | sed 's|^\./||' | LC_ALL=C sort)
EOF
    # Regen-and-cmp: regenerate the descriptor with the SAME generators as vendor.sh into a
    # tmpdir, seeded with the existing cpp meta so `created` is preserved (idempotent).
    if [ "$item_drift" = 0 ]; then
      regen="$(mktemp -d)"
      payload_emit_mcp_descriptor "$regen" "$id"
      base_meta=""; [ -f "$target/meta.yml" ] && base_meta="$(cat "$target/meta.yml")"
      payload_emit_cpp_meta "$regen" "$id" "$master" "$base_meta"
      for f in README.md meta.yml; do
        if ! cmp -s "$regen/$f" "$target/$f"; then
          printf '  DRIFT  %s: cpp mcp %s differs from regenerated payload (template drift or hand-edit)\n' "$id" "$f"
          item_drift=1
        fi
      done
      rm -rf "$regen"
    fi
    [ "$item_drift" = 0 ] && printf '  OK     %s: cpp mcp descriptor in sync (shape + README/meta byte-equal to regen)\n' "$id" || drift=1
    continue
  fi

  # Default (skill / workflow / asset / etc): master<->payload byte comparison over shared content.
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
