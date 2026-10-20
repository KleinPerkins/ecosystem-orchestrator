#!/usr/bin/env bash
# lib/status.sh — operator/agent matrix view for the ld->cpp capability edge.
set -uo pipefail
ST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$ST_LIB_DIR/common.sh"
. "$ST_LIB_DIR/registry.sh"
. "$ST_LIB_DIR/payload.sh"

JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --matrix) ;;
    --json) JSON=1 ;;
    -*) orch_err "status: unknown flag: $1"; exit 2 ;;
    *) orch_err "status: unexpected arg: $1"; exit 2 ;;
  esac
  shift
done

SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
SRC_MCP_LOCAL="$(orch_expand "$(orch_cfg_get source_mcp_local)")"
SRC_SKILLS_LOCAL="$(orch_expand "$(orch_cfg_get source_skills_local)")"
CPP="$(orch_expand "${ORCH_STATUS_CPP_DIR:-$(orch_cfg_get ld_cpp_worktree)}")"
QUIVER="$(orch_cfg_get cpp_quiver_path)"; QUIVER="${QUIVER:-quiver}"
OWNED="$(orch_cfg_get cpp_sync_denylist)"; OWNED="${OWNED:-eco-capability-sync}"
TOOL_ID="${OWNED%% *}"
MANIFEST="$CPP/$QUIVER/tooling/$TOOL_ID/eco-capability-manifest.yml"

_meta_field() {
  local file="$1" field="$2"
  awk -F': *' -v f="$field" '$1==f{print $2; exit}' "$file" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

master_dir() {
  local id="$1" d
  d="$(orch_resolve_skill_master "$SRC_GLOBAL" "$id" 2>/dev/null || true)"
  [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  d="$SRC_MCP_LOCAL/$id"
  [ -f "$d/meta.yml" ] && { printf '%s\n' "$d"; return 0; }
  return 1
}

manifest_ids() {
  [ -f "$MANIFEST" ] || return 0
  awk '/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/{v=$0; sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/,"",v); gsub(/[[:space:]]/,"",v); print v}' "$MANIFEST"
}

payload_ids() {
  [ -d "$CPP/$QUIVER" ] || return 0
  local d
  for d in "$CPP/$QUIVER"/*/*; do
    [ -d "$d" ] || continue
    [ -f "$d/VENDORED.md" ] || continue
    basename "$d"
  done
}

payload_path() {
  local id="$1" d
  [ -d "$CPP/$QUIVER" ] || return 1
  for d in "$CPP/$QUIVER"/*/"$id"; do
    [ -d "$d" ] && [ -f "$d/VENDORED.md" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

lock_state() {
  local id="$1" root lock saw=0
  for root in "$SRC_SKILLS_LOCAL" "$SRC_MCP_LOCAL"; do
    [ -n "$root" ] || continue
    lock="$root/.eco-registry.lock"
    [ -f "$lock" ] || continue
    saw=1
    if awk -v id="$id" '$1==id{found=1} END{exit found?0:1}' "$lock"; then printf 'locked\n'; return 0; fi
  done
  [ "$saw" = 1 ] && printf 'absent\n' || printf 'no-lock\n'
}

open_pr_state() {
  local id="$1" repo prefix refs
  [ "${ORCH_STATUS_SKIP_GH:-0}" = 1 ] && { printf 'unknown\n'; return 0; }
  command -v gh >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  gh auth status >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  repo="$(orch_cfg_get cpp_repo)"
  prefix="$(orch_cfg_get cpp_pr_branch_prefix)"; prefix="${prefix:-orchestrator/vendor}"
  refs="$(gh pr list --repo "$repo" --state open --json headRefName --jq '.[].headRefName' 2>/dev/null || true)"
  # Per-id branches name their id; a combined cpp-sync branch (sync-*) may carry any id.
  if printf '%s\n' "$refs" | awk -v p="$prefix" -v id="$id" '$0 == p "/" id || $0 ~ ("^" p "/" id "-") || $0 ~ ("^" p "/rm-" id "-") || $0 ~ ("^" p "/sync-") {found=1} END{exit found?0:1}'; then
    printf 'open\n'
  else
    printf 'none\n'
  fi
}

approval_state() {
  local flavor="$1" current="$2" approved_raw="$3" approved_valid="$4"
  [ "$flavor" = "2" ] || { [ -n "$approved_valid" ] && printf 'advisory\n' || printf 'not-required\n'; return 0; }
  [ -n "$approved_raw" ] || { printf 'missing\n'; return 0; }
  [ -n "$approved_valid" ] || { printf 'malformed\n'; return 0; }
  [ -n "$current" ] || { printf 'unknown-current\n'; return 0; }
  [ "$current" = "$approved_valid" ] && printf 'approved\n' || printf 'drifted\n'
}

payload_state() {
  local reg="$1" payload="$2" manifest="$3"
  if [ "$payload" = 1 ] && [ "$reg" != "enrolled" ]; then printf 'stray'
  elif [ "$payload" = 1 ] && [ "$manifest" = 1 ]; then printf 'present'
  elif [ "$payload" = 1 ] && [ "$manifest" = 0 ] && [ "$reg" = "enrolled" ]; then printf 'payload-only'
  elif [ "$payload" = 0 ] && [ "$manifest" = 1 ]; then printf 'manifest-only'
  elif [ "$payload" = 0 ] && [ "$reg" = "enrolled" ]; then printf 'missing'
  else printf 'absent'; fi
}

next_action() {
  local reg="$1" approval="$2" pstate="$3" invalid="$4" open="$5"
  case "$approval" in missing|malformed|drifted) printf 'approve' ; return 0 ;; esac
  [ -n "$invalid" ] && { printf 'repair'; return 0; }
  # cpp-sync --execute repairs every payload/manifest mismatch in one PR, but refuses while an
  # orchestrator PR is still open, so an open PR always comes first.
  case "$pstate" in
    missing|stray|payload-only|manifest-only) [ "$open" = "open" ] && printf 'wait for PR' || printf 'cpp-sync --execute' ;;
    *) [ "$open" = "open" ] && printf 'wait for PR' || printf 'none' ;;
  esac
}

emit_rows() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    id kind flavor registry_state meta_present lock_state current_digest approved_digest approval_state \
    cpp_payload_state manifest_state open_pr_state last_synced_cpp_sha last_synced_at next_action

  local ids id master kind flavor meta current approved_raw approved_valid approval reg lock invalid
  local payload manifest pstate mstate open last_sha last_at action p
  ids="$( { reg_ids; payload_ids; manifest_ids; } | LC_ALL=C sort -u )"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    master="$(master_dir "$id" || true)"
    if [ -n "$master" ]; then
      meta=yes
      kind="$(_meta_field "$master/meta.yml" kind)"; kind="${kind:-skill}"
      flavor="$(_meta_field "$master/meta.yml" flavor)"; flavor="${flavor:-1}"
      current="$(payload_content_digest "$master" || true)"
    else
      meta=no
      kind="$(reg_kind "$id")"; kind="${kind:-unknown}"
      flavor="unknown"
      current=""
    fi
    reg="$(reg_state "$id")"; reg="${reg:-absent}"
    lock="$(lock_state "$id")"
    approved_raw="$(reg_journal_raw "$id" approved_digest)"
    approved_valid="$(reg_journal_get "$id" approved_digest)"
    approval="$(approval_state "$flavor" "$current" "$approved_raw" "$approved_valid")"
    p="$(payload_path "$id" || true)"; [ -n "$p" ] && payload=1 || payload=0
    if manifest_ids | awk -v id="$id" '$0==id{found=1} END{exit found?0:1}'; then manifest=1; else manifest=0; fi
    pstate="$(payload_state "$reg" "$payload" "$manifest")"
    [ "$manifest" = 1 ] && mstate=active || mstate=absent
    open="$(open_pr_state "$id")"
    last_sha="$(reg_journal_raw "$id" last_synced_cpp_sha)"
    last_at="$(reg_journal_raw "$id" last_synced_at)"
    invalid="$(reg_journal_invalid_fields "$id" | paste -sd ',' -)"
    action="$(next_action "$reg" "$approval" "$pstate" "$invalid" "$open")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$id" "$kind" "$flavor" "$reg" "$meta" "$lock" "${current:-}" "${approved_raw:-}" "$approval" \
      "$pstate" "$mstate" "$open" "${last_sha:-}" "${last_at:-}" "$action"
  done <<< "$ids"
}

tmp="$(mktemp)" || exit 1
emit_rows > "$tmp"
if [ "$JSON" = 1 ]; then
  python3 - "$tmp" <<'PY'
import csv, json, sys
with open(sys.argv[1], newline="") as f:
    rows = list(csv.DictReader(f, delimiter="\t"))
print(json.dumps(rows, indent=2, sort_keys=True))
PY
else
  awk -F'\t' '
    NR==1 { next }
    BEGIN { fmt="%-24s %-9s %-6s %-10s %-7s %-8s %-12s %-13s %-11s %-12s %-10s %-10s %s\n";
      printf fmt,"ID","STATE","KIND","FLAVOR","META","LOCK","APPROVAL","CPP_PAYLOAD","MANIFEST","OPEN_PR","LAST_SHA","LAST_AT","NEXT";
      printf fmt,"------------------------","---------","------","----------","-------","--------","------------","-------------","-----------","----------","----------","----------","----" }
    { sha=$13; if (length(sha)>10) sha=substr(sha,1,10); printf fmt,$1,$4,$2,$3,$5,$6,$9,$10,$11,$12,sha,$14,$15 }
  ' "$tmp"
fi
rm -f "$tmp"
