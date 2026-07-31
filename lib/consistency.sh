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
#     (no ids)   check every enrolled id in config/registry.yml (state:enrolled)
#     <id>...    check just those ids
#
# "Shared content" = everything the vendor actually copies: the master files EXCEPT the ld-management
# artifacts (meta.yml, install.sh) and vcs/cache noise; on the payload side VENDORED.md + the translated
# meta.yml are likewise excluded (they are vendor-authored, not shared).
set -uo pipefail
C_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$C_LIB_DIR/common.sh"
. "$C_LIB_DIR/payload.sh"
. "$C_LIB_DIR/registry.sh"

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

[ -d "$SRC_GLOBAL" ] || { orch_err "consistency: master skills dir missing: $SRC_GLOBAL"; exit 2; }
[ -d "$CPP_DIR" ]    || { orch_err "consistency: cpp tree not found: $CPP_DIR (pass --cpp-dir or set ld_cpp_worktree)"; exit 2; }

# Resolve a master capability dir by id. Skills live under source_skills_global; mcp masters
# live flat under source_mcp_local. Returns empty on miss.
resolve_master() {
  local id="$1" d
  d="$(orch_resolve_skill_master "$SRC_GLOBAL" "$id" 2>/dev/null || true)"
  [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  if [ -n "$SRC_MCP_LOCAL" ] && [ -d "$SRC_MCP_LOCAL/$id" ]; then printf '%s\n' "$SRC_MCP_LOCAL/$id"; return 0; fi
  return 1
}

if [ "${#ids[@]}" -eq 0 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && ids+=("$line")
  done < <(reg_ids enrolled)
fi
[ "${#ids[@]}" -gt 0 ] || { orch_warn "consistency: no enrolled items to check"; exit 0; }

# Enrollment-drift check (B1a; registry-driven). config/registry.yml is the enrollment SoT; the disk
# state (scope:global masters under SRC_GLOBAL + SRC_MCP_LOCAL) is the ground truth. Whenever a global
# capability is added/removed and someone forgets to update the registry, the orchestrator silently
# ignores it. This check diffs the two and reports either direction as DRIFT. A capability KNOWN to
# the registry in ANY state (enrolled|excluded|demoted) is an expected entry; only ids on disk that
# the registry has never heard of are drift. Only runs for the full list (no explicit ids).
if [ "$ids_explicit" = 0 ]; then
  enroll_drift=0
  # The registry's known set (any state) — anything here is an intentional, recorded decision.
  known_set=" $(reg_ids | tr '\n' ' ')"
  # Discover on-disk scope:global ids. Skills: any dir under SRC_GLOBAL (dir-paradigm guarantees
  # scope:global). Mcp: any subdir of SRC_MCP_LOCAL whose meta.yml declares scope: global.
  disk_globals=""
  if [ -d "$SRC_GLOBAL" ]; then
    while IFS= read -r meta; do
      [ -n "$meta" ] || continue
      id="$(orch_meta_field "$meta" id)"; [ -n "$id" ] || id="$(basename "$(dirname "$meta")")"
      disk_globals="$disk_globals $id"
    done < <(orch_each_skill_meta "$SRC_GLOBAL")
  fi
  if [ -n "$SRC_MCP_LOCAL" ] && [ -d "$SRC_MCP_LOCAL" ]; then
    for d in "$SRC_MCP_LOCAL"/*/; do
      [ -f "$d/meta.yml" ] || continue
      s="$(awk -F': *' '/^scope:/{print $2; exit}' "$d/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
      [ "$s" = "global" ] || continue
      disk_globals="$disk_globals $(basename "$d")"
    done
  fi
  # Direction 1: scope:global on disk but unknown to the registry (any state).
  for g in $disk_globals; do
    case "$known_set" in *" $g "*) continue ;; esac
    printf '  DRIFT  %s: scope:global on disk but absent from registry.yml (enroll it, or mark it excluded: `orchestrator exclude %s -- <reason>`)\n' "$g" "$g"
    enroll_drift=1
  done
  # Direction 2: enrolled in the registry but the master is missing/non-global on disk.
  for e in "${ids[@]}"; do
    m="$(resolve_master "$e" || true)"
    if [ -z "$m" ]; then
      printf '  DRIFT  %s: enrolled in registry.yml but no master found under SRC_GLOBAL or SRC_MCP_LOCAL\n' "$e"
      enroll_drift=1
      continue
    fi
    s="$(awk -F': *' '/^scope:/{print $2; exit}' "$m/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
    if [ -n "$s" ] && [ "$s" != "global" ]; then
      printf '  DRIFT  %s: enrolled but master scope=%s (only scope:global is vendorable; `orchestrator demote %s` + `orchestrator cpp-sync` to delete-propagate)\n' "$e" "$s" "$e"
      enroll_drift=1
    fi
  done
  if [ "$enroll_drift" = 1 ]; then
    drift=1
    echo
  else
    printf '  OK     enrollment: registry.yml matches the on-disk scope:global set (exclusions/demotions honored)\n'
  fi
fi

# Shared-content traversal lives in payload.sh so consistency, digest, and vendor emit cannot drift.
shared_list() { payload_shared_list "$1"; }

echo "== orchestrator consistency (master <-> cpp vendored payload) =="
for id in "${ids[@]}"; do
  master="$(resolve_master "$id" || true)"
  if [ -z "$master" ]; then printf '  DRIFT  %s: master missing (no skills/global or mcp/<id>)\n' "$id"; drift=1; continue; fi
  # Defense-in-depth scope gate (Option A; 2026-06-26): non-global masters must not be enrolled.
  # Flag as drift so the enrollment can be corrected (`orchestrator demote <id>` + `cpp-sync` to
  # purge any stranded cpp payload).
  mscope="$(awk -F': *' '/^scope:/{print $2; exit}' "$master/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
  if [ -n "$mscope" ] && [ "$mscope" != "global" ]; then
    printf '  DRIFT  %s: master declares scope=%s but is enrolled in registry.yml (only scope:global is vendorable)\n' "$id" "$mscope"
    drift=1; continue
  fi
  target="$(cd "$CPP_DIR" && for d in "$QUIVER"/*/"$id"; do [ -e "$d" ] && { printf '%s/%s\n' "$CPP_DIR" "$d"; break; }; done)"
  if [ -z "$target" ]; then printf '  DRIFT  %s: not vendored under %s/%s/*\n' "$id" "$CPP_DIR" "$QUIVER"; drift=1; continue; fi
  if [ -L "$target" ]; then printf '  DRIFT  %s: vendored path is a LEGACY symlink — un-arm with dedup.sh --reverse\n' "$id"; drift=1; continue; fi

  # Kind-aware comparison. For `kind: mcp` masters the orchestrator vendors a SOURCE-FREE,
  # ld-agnostic descriptor/package instead of source. Comparing the master's source tree would
  # always flag every source file as missing, so regenerate the exact mcp payload into a tmpdir
  # and byte-compare the payload file set. google-kit uses this same path for its suite overlay.
  kind="$(awk -F': *' '/^kind:/{print $2; exit}' "$master/meta.yml" 2>/dev/null)"
  if [ "$kind" = "mcp" ]; then
    item_drift=0
    regen="$(mktemp -d)"
    payload_emit_mcp_descriptor "$regen" "$id"
    payload_emit_vendored_md "$regen" "$id"
    base_meta=""; [ -f "$target/meta.yml" ] && base_meta="$(cat "$target/meta.yml")"
    payload_emit_cpp_meta "$regen" "$id" "$master" "$base_meta"

    expected="$(cd "$regen" 2>/dev/null && find . -type f ! -path '*/.git/*' | sed 's|^\./||' | LC_ALL=C sort)"
    actual="$(cd "$target" 2>/dev/null && find . -type f ! -path '*/.git/*' | sed 's|^\./||' | LC_ALL=C sort)"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if [ ! -f "$target/$f" ]; then
        printf '  DRIFT  %s: missing in cpp mcp payload: %s\n' "$id" "$f"; item_drift=1
      elif ! cmp -s "$regen/$f" "$target/$f"; then
        printf '  DRIFT  %s: cpp mcp %s differs from regenerated payload\n' "$id" "$f"; item_drift=1
      fi
    done <<< "$expected"
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      if ! printf '%s\n' "$expected" | awk -v f="$f" '$0==f{found=1} END{exit found?0:1}'; then
        printf '  DRIFT  %s: unexpected source file in cpp mcp payload: %s\n' "$id" "$f"; item_drift=1
      fi
    done <<< "$actual"
    rm -rf "$regen"
    [ "$item_drift" = 0 ] && printf '  OK     %s: cpp mcp payload in sync (byte-equal to regenerated source-free package)\n' "$id" || drift=1
    continue
  fi

  # kind:tool with a descriptor/snapshot shape also vendors a REGENERATED (not shared-content-diffed)
  # payload — same regen-and-cmp treatment as mcp, dispatched by shape exactly like vendor.sh's
  # build_payload(). A plain kind:tool with no recognized shape falls through to the default branch
  # below (a future ordinary vendorable script/binary shelf, per docs/tool-descriptor-cpp-sync-design.md).
  if [ "$kind" = "tool" ]; then
    shape="$(awk -F': *' '/^shape:/{print $2; exit}' "$master/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
    if [ "$shape" = "release-descriptor" ] || [ "$shape" = "snapshot" ]; then
      item_drift=0
      regen="$(mktemp -d)"
      if [ "$shape" = "release-descriptor" ]; then
        payload_emit_tool_descriptor "$regen" "$id"
      else
        payload_emit_tool_snapshot "$regen" "$id" "$master" || { orch_err "$id: payload_emit_tool_snapshot failed"; drift=1; rm -rf "$regen"; continue; }
      fi
      payload_emit_vendored_md "$regen" "$id"
      base_meta=""; [ -f "$target/meta.yml" ] && base_meta="$(cat "$target/meta.yml")"
      payload_emit_cpp_meta "$regen" "$id" "$master" "$base_meta"

      expected="$(cd "$regen" 2>/dev/null && find . -type f ! -path '*/.git/*' | sed 's|^\./||' | LC_ALL=C sort)"
      actual="$(cd "$target" 2>/dev/null && find . -type f ! -path '*/.git/*' | sed 's|^\./||' | LC_ALL=C sort)"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ ! -f "$target/$f" ]; then
          printf '  DRIFT  %s: missing in cpp tool payload: %s\n' "$id" "$f"; item_drift=1
        elif ! cmp -s "$regen/$f" "$target/$f"; then
          printf '  DRIFT  %s: cpp tool %s differs from regenerated payload\n' "$id" "$f"; item_drift=1
        fi
      done <<< "$expected"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        if ! printf '%s\n' "$expected" | awk -v f="$f" '$0==f{found=1} END{exit found?0:1}'; then
          printf '  DRIFT  %s: unexpected file in cpp tool payload: %s\n' "$id" "$f"; item_drift=1
        fi
      done <<< "$actual"
      rm -rf "$regen"
      [ "$item_drift" = 0 ] && printf '  OK     %s: cpp tool payload in sync (byte-equal to regenerated %s package)\n' "$id" "$shape" || drift=1
      continue
    fi
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
if [ "$drift" = 0 ]; then orch_log "consistency: OK (all enrolled items in sync)"; exit 0
else orch_err "consistency: DRIFT detected (re-sync with: orchestrator cpp-sync --execute, or reverse a legacy symlink)"; exit 1; fi
