#!/usr/bin/env bash
# bin/orchestrator.sh — ecosystem orchestrator CLI (reorg-v2). The single owner of the
# ld<->cpp relationship. Subcommands:
#   enroll <id> [reason]   mark a global capability enrolled for cpp vendoring (registry SoT, B1b)
#   exclude <id> [reason]  mark it intentionally NOT vendored
#   demote <id> [reason]   mark it global->local; delete-propagated out of cpp on the next cpp-sync
#   approve <id>           pin the current content digest for flavor-2 supply-chain approval
#   status [--matrix]      registry enrollment state + cpp presence per id (B1b)
#   repair                 refresh derivable journal state from observed cpp main
#   rollback <id>          restore a payload from last_synced_cpp_sha via a governed cpp PR
#   quarantine <id> -- <r> close in-flight PRs, exclude, delete-propagate, regenerate manifest
#   lockkit check|write|diff [target...]  verify/propagate the shared eco-lock normalizer
#   vendor <id>        vendor a global capability into cpp via a governed PR (WS-7)
#   delete <id>        propagate a master delete via a governed cpp deletion PR (WS-7)
#   cpp-sync           registry-driven sync of enrolled capabilities into cpp (WF2/B4)
#   chaos-shim-sync    DRY-RUN/execute google-kit shim delivery to the configured chaos-labs target
#   reconcile          AUTHORITY: registry.yml <-> committed .eco-registry.lock (registry wins; B2)
#   consistency [id..] verify master<->cpp vendored-payload content is in sync (Decision A control)
#   dedup  <id>        DEPRECATED (Decision A): symlink-dedup abandoned; --reverse un-arms a legacy link
#   self-heal          bounded verifier-driven retry loop (WS-9)
#   install            install the orchestrator's triggers + state (ORCH-C, WS-9)
#   zero-link <m> <p>  forensic INV-zero-link assertion (mode global|cpp)
#   doctor             read-only health check
# Note: `rename` is NOT a verb — do `exclude old` + `enroll new` + `cpp-sync` (deletes old, vendors new).
set -uo pipefail
ORCH_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$ORCH_BIN_DIR/../lib/common.sh"
# shellcheck source=../lib/registry.sh
. "$ORCH_BIN_DIR/../lib/registry.sh"
# shellcheck source=../lib/payload.sh
. "$ORCH_BIN_DIR/../lib/payload.sh"

cmd_help() { sed -n '2,18p' "$0"; }

# ---- WF1/B1b: enrollment verbs (mutate the registry SoT) -----------------------------------------
cmd_enroll()  { _reg_verb enroll  enrolled "$@"; }
cmd_exclude() { _reg_verb exclude excluded "$@"; }
cmd_demote()  { _reg_verb demote  demoted  "$@"; }
_reg_verb() {
  local verb="$1" state="$2" id="${3:-}"; shift 3 2>/dev/null || true
  local reason="$*"
  [ -n "$id" ] || { orch_err "usage: orchestrator $verb <id> [reason]"; return 2; }
  reg_assert_schema || return 1
  local prev; prev="$(reg_state "$id")"
  reg_set "$id" "$state" "$reason" || return 1
  if [ -n "$prev" ]; then orch_log "registry: $id $prev -> $state"; else orch_log "registry: $id (new) -> $state"; fi
  case "$state" in
    enrolled) orch_log "next: run 'orchestrator cpp-sync --execute' to vendor $id into cpp" ;;
    excluded|demoted) orch_log "next: run 'orchestrator cpp-sync --execute' to delete-propagate $id out of cpp (if vendored)" ;;
  esac
}

cmd_status() {
  if [ "${1:-}" = "--matrix" ]; then
    bash "$ORCH_BIN_DIR/../lib/status.sh" "$@"; return $?
  elif [ $# -gt 0 ]; then
    orch_err "usage: orchestrator status [--matrix [--json]]"; return 2
  fi
  reg_assert_schema || return 1
  local cpp quiver; cpp="$(orch_expand "$(orch_cfg_get ld_cpp_worktree)")"
  quiver="$(orch_cfg_get cpp_quiver_path)"; quiver="${quiver:-quiver}"
  printf '%-24s %-9s %s\n' "ID" "STATE" "CPP"
  printf '%-24s %-9s %s\n' "------------------------" "---------" "----------------------"
  local id st present d
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    st="$(reg_state "$id")"
    present=0
    if [ -d "$cpp" ]; then for d in "$cpp/$quiver"/*/"$id"; do [ -e "$d" ] && { present=1; break; }; done; fi
    local cppcol
    if [ ! -d "$cpp" ]; then cppcol="? (no cpp worktree)"
    elif [ "$st" = "enrolled" ] && [ "$present" = 1 ]; then cppcol="vendored"
    elif [ "$st" = "enrolled" ] && [ "$present" = 0 ]; then cppcol="MISSING (run cpp-sync)"
    elif [ "$st" != "enrolled" ] && [ "$present" = 1 ]; then cppcol="STRAY (cpp-sync prunes)"
    else cppcol="-"; fi
    printf '%-24s %-9s %s\n' "$id" "$st" "$cppcol"
  done < <(reg_ids)
}

_cli_meta_field() {
  local file="$1" field="$2"
  awk -F': *' -v f="$field" '$1==f{print $2; exit}' "$file" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

_cli_master_dir() {
  local id="$1" src_global src_mcp d
  src_global="$(orch_expand "$(orch_cfg_get source_skills_global)")"
  src_mcp="$(orch_expand "$(orch_cfg_get source_mcp_local)")"
  d="$(orch_resolve_skill_master "$src_global" "$id" 2>/dev/null || true)"
  [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  d="$src_mcp/$id"
  [ -f "$d/meta.yml" ] && { printf '%s\n' "$d"; return 0; }
  return 1
}

cmd_approve() {
  local id="${1:-}" master kind flavor old digest
  [ -n "$id" ] || { orch_err "usage: orchestrator approve <id>"; return 2; }
  reg_assert_schema || return 1
  reg_has "$id" || { orch_err "approve: $id is not in registry.yml (enroll it first)"; return 1; }
  master="$(_cli_master_dir "$id" || true)"
  [ -n "$master" ] || { orch_err "approve: master not found for $id"; return 1; }
  kind="$(_cli_meta_field "$master/meta.yml" kind)"; kind="${kind:-skill}"
  flavor="$(_cli_meta_field "$master/meta.yml" flavor)"; flavor="${flavor:-1}"
  digest="$(payload_content_digest "$master" || true)"
  [ -n "$digest" ] || { orch_err "approve: could not compute content digest for $id"; return 1; }
  old="$(reg_journal_raw "$id" approved_digest)"
  printf 'id: %s\nkind: %s\nflavor: %s\nold_approved_digest: %s\nnew_approved_digest: %s\n' \
    "$id" "$kind" "$flavor" "${old:-<none>}" "$digest"
  reg_journal_set "$id" approved_digest "$digest" || return 1
  reg_journal_set "$id" content_digest "$digest" || return 1
  if [ "$flavor" = "2" ]; then orch_log "approval pinned: $id@$digest"
  else orch_log "approval recorded for flavor-$flavor item (advisory): $id@$digest"; fi
}

_repair_rel_at_ref() {
  local cpp="$1" ref="$2" quiver="$3" id="$4"
  git -C "$cpp" ls-tree -r --name-only "$ref" -- "$quiver" 2>/dev/null \
    | awk -F/ -v id="$id" '$NF=="VENDORED.md" && $(NF-1)==id {sub(/\/VENDORED\.md$/,""); print; exit}'
}

cmd_repair() {
  reg_assert_schema || return 1
  orch_log "repair: running doctor"
  bash "$ORCH_BIN_DIR/orchestrator.sh" doctor || orch_warn "repair: doctor reported warnings/failures"
  orch_log "repair: running self-heal"
  bash "$ORCH_BIN_DIR/../lib/selfmanage.sh" self-heal || orch_warn "repair: self-heal did not reach green"

  local work default_branch cpp quiver ref sha now id master digest rel
  work="$(orch_expand "$(orch_cfg_get work_clone_dir)")"
  default_branch="$(orch_cfg_get cpp_default_branch)"; default_branch="${default_branch:-main}"
  if [ -d "$work/.git" ]; then
    git -C "$work" fetch --depth 1 origin "$default_branch" >/dev/null 2>&1 || orch_warn "repair: could not refresh work clone"
  fi

  cpp="$(orch_expand "$(orch_cfg_get ld_cpp_worktree)")"
  quiver="$(orch_cfg_get cpp_quiver_path)"; quiver="${quiver:-quiver}"
  ref="$default_branch"
  if [ -d "$work/.git" ] && git -C "$work" rev-parse --verify "origin/$default_branch^{commit}" >/dev/null 2>&1; then
    cpp="$work"
    ref="origin/$default_branch"
  fi
  [ -d "$cpp/.git" ] || { orch_err "repair: cpp worktree unavailable: $cpp"; return 1; }
  git -C "$cpp" rev-parse --verify "$ref^{commit}" >/dev/null 2>&1 || ref="HEAD"
  sha="$(git -C "$cpp" rev-parse "$ref" 2>/dev/null || true)"
  [ -n "$sha" ] || { orch_err "repair: could not resolve observed cpp main/HEAD"; return 1; }
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  while IFS= read -r id; do
    [ -n "$id" ] || continue
    master="$(_cli_master_dir "$id" || true)"
    if [ -n "$master" ]; then
      digest="$(payload_content_digest "$master" || true)"
      [ -n "$digest" ] && reg_journal_set "$id" content_digest "$digest"
    fi
    rel="$(_repair_rel_at_ref "$cpp" "$sha" "$quiver" "$id")"
    if [ -n "$rel" ]; then
      reg_journal_set "$id" last_synced_cpp_sha "$sha" || return 1
      reg_journal_set "$id" last_synced_at "$now" || return 1
      orch_log "repair: refreshed $id last_synced_cpp_sha=${sha:0:12}"
    fi
  done < <(reg_ids)

  orch_log "repair: status matrix"
  ORCH_STATUS_CPP_DIR="$cpp" bash "$ORCH_BIN_DIR/../lib/status.sh" --matrix
}

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

  # --- WF1 drift lines (B3) — local, network-free ---
  if reg_assert_schema >/dev/null 2>&1; then
    echo "  PASS  registry.yml present ($(reg_ids | wc -l | tr -d ' ') ids; $(reg_ids enrolled | wc -l | tr -d ' ') enrolled)"
    # enrollment-drift: scope:global on disk but unknown to the registry (Direction 1, cheap).
    local sg known_set ed=0 d id
    sg="$(orch_expand "$(orch_cfg_get source_skills_global)")"
    known_set=" $(reg_ids | tr '\n' ' ') "
    if [ -d "$sg" ]; then
      while IFS= read -r meta; do
        [ -n "$meta" ] || continue
        d="${meta%/meta.yml}"
        id="$(orch_meta_field "$meta" id)"; [ -n "$id" ] || id="$(basename "$d")"
        case "$known_set" in *" $id "*) ;; *) echo "  WARN  enrollment-drift: $id scope:global on disk but absent from registry.yml"; ed=1 ;; esac
      done < <(orch_each_skill_meta "$sg")
    fi
    [ "$ed" = 0 ] && echo "  PASS  enrollment: registry.yml covers the on-disk scope:global skills"
    # registry<->lock divergence (authority; B2). Fail-open: report, never fail doctor.
    if bash "$ORCH_BIN_DIR/../lib/reconcile.sh" >/dev/null 2>&1; then echo "  PASS  registry<->lock reconcile (every enrolled id is lock-pinned)"
    else echo "  WARN  registry<->lock divergence — run 'orchestrator reconcile' for detail"; fi
  else
    echo "  FAIL  registry.yml missing or wrong schema"; rc=1
  fi

  # --- WF2 auto-merge preconditions (D6) — not derivable from local files; gh-asserted ---
  if command -v gh >/dev/null 2>&1; then
    local who; who="$(gh api user -q .login 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
    case "$who" in
      kleinperkins) echo "  PASS  gh login == kleinperkins (orchestrator quiver PRs are bot-auto-approved)" ;;
      "") echo "  WARN  gh login unknown (orchestrator cpp PRs need login==kleinperkins for bot auto-approval)" ;;
      *)  echo "  WARN  gh login is '$who', not kleinperkins — orchestrator cpp PRs won't be bot-auto-approved (cpp-auto-approve.yml)" ;;
    esac
    local am; am="$(gh api "repos/$cpp" -q .allow_auto_merge 2>/dev/null || true)"
    case "$am" in
      true)  echo "  PASS  cpp 'Allow auto-merge' is ON" ;;
      false) echo "  WARN  cpp 'Allow auto-merge' is OFF — cpp-sync PRs cannot native-auto-merge (enable in repo settings)" ;;
      *)     echo "  WARN  could not read cpp 'Allow auto-merge' setting (network/permission)" ;;
    esac
    echo "  INFO  precondition (not queryable): @affirm-cpp-bot must auto-approve orchestrator quiver PRs; use local lockkit checks + CI lock-parity backstops for skills + kp-mcp unless branch protection becomes available"
  fi

  echo; [ "$rc" -eq 0 ] && echo "doctor: OK" || echo "doctor: FAILED"; return "$rc"
}

# --- WS-7 (vendor/delete) and WS-8 (dedup) and WS-9 (sync/self-heal/install) fill these in. ---
cmd_vendor()   { bash "$ORCH_BIN_DIR/../lib/vendor.sh" "$@"; }
cmd_delete()   { bash "$ORCH_BIN_DIR/../lib/vendor.sh" --delete "$@"; }
cmd_consistency() { bash "$ORCH_BIN_DIR/../lib/consistency.sh" "$@"; }
cmd_reconcile() { bash "$ORCH_BIN_DIR/../lib/reconcile.sh" "$@"; }
cmd_dedup()    { bash "$ORCH_BIN_DIR/../lib/dedup.sh" "$@"; }
cmd_cpp_sync() { bash "$ORCH_BIN_DIR/../lib/selfmanage.sh" cpp-sync "$@"; }
cmd_chaos_shim_sync() { bash "$ORCH_BIN_DIR/../lib/chaos_shim.sh" "$@"; }
cmd_selfheal() { bash "$ORCH_BIN_DIR/../lib/selfmanage.sh" self-heal "$@"; }
cmd_install()  { bash "$ORCH_BIN_DIR/../lib/selfmanage.sh" install "$@"; }
cmd_rollback() { bash "$ORCH_BIN_DIR/../lib/recovery.sh" rollback "$@"; }
cmd_quarantine() { bash "$ORCH_BIN_DIR/../lib/recovery.sh" quarantine "$@"; }
cmd_lockkit() { bash "$ORCH_BIN_DIR/../lib/lockkit.sh" "$@"; }

main() {
  local sub="${1:-help}"; shift || true
  case "$sub" in
    enroll)     cmd_enroll "$@" ;;
    exclude)    cmd_exclude "$@" ;;
    demote)     cmd_demote "$@" ;;
    approve)    cmd_approve "$@" ;;
    status)     cmd_status "$@" ;;
    repair)     cmd_repair "$@" ;;
    vendor)     cmd_vendor "$@" ;;
    delete)     cmd_delete "$@" ;;
    cpp-sync)   cmd_cpp_sync "$@" ;;
    chaos-shim-sync) cmd_chaos_shim_sync "$@" ;;
    reconcile)  cmd_reconcile "$@" ;;
    consistency) cmd_consistency "$@" ;;
    dedup)      cmd_dedup "$@" ;;
    self-heal)  cmd_selfheal "$@" ;;
    install)    cmd_install "$@" ;;
    zero-link)  cmd_zero_link "$@" ;;
    doctor)     cmd_doctor "$@" ;;
    rollback)   cmd_rollback "$@" ;;
    quarantine) cmd_quarantine "$@" ;;
    lockkit)    cmd_lockkit "$@" ;;
    -h|--help|help) cmd_help ;;
    *) orch_err "unknown subcommand: $sub"; cmd_help; exit 2 ;;
  esac
}
main "$@"
