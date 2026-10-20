#!/usr/bin/env bash
# lib/selfmanage.sh — orchestrator self-management (reorg-v2 WS-9 / ORCH-C). Subcommands:
#   install     install triggers (Cursor sessionStart hook + launchd agent) + state. Idempotent.
#   cpp-sync    registry-driven sync of enrolled capabilities into cpp (WF2/B4). PREFLIGHT (lockkit /
#               reconcile / kind / enabled_kinds / flavor-2 digest), then ONE vendor.sh --sync change:
#               every vendor + delete-propagation (excluded/demoted ids, denylist-protected) + the
#               manifest in a single PR (ADR 0002). DRY-RUN by default; --execute opens that one PR.
#   vendor      per-id: the same preflight for exactly one enrolled id, then ONE PR carrying its
#               payload and its manifest row together.
#   self-heal   bounded retry loop (N=3) over orchestrator verifiers; heals a stale work clone.
set -uo pipefail
SM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SM_LIB_DIR/common.sh"
. "$SM_LIB_DIR/registry.sh"
. "$SM_LIB_DIR/payload.sh"

PLIST_LABEL="com.kleinperkins.orchestrator"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
CURSOR_HOOKS_DIR="$HOME/.cursor/hooks"
CURSOR_HOOKS_JSON="$HOME/.cursor/hooks.json"
WORK="$(orch_expand "$(orch_cfg_get work_clone_dir)")"
STATE_DIR="$(dirname "$WORK")"

# Enrolled-for-cpp ids come from the registry SoT (B1a; config/registry.yml, state:enrolled).
managed_ids() { reg_ids enrolled; }

# ---- install (ORCH-C triggers) -------------------------------------------------------------------
cmd_install() {
  mkdir -p "$STATE_DIR" "$CURSOR_HOOKS_DIR" "$(dirname "$PLIST_PATH")"

  # 1) Cursor sessionStart user hook: symlink the body + safely merge hooks.json.
  ln -sfn "$ORCH_ROOT/bin/session-hook.sh" "$CURSOR_HOOKS_DIR/orchestrator-session.sh"
  CURSOR_HOOKS_JSON="$CURSOR_HOOKS_JSON" python3 - <<'PY' || orch_warn "hooks.json merge skipped"
import json, os, sys, shutil, time
p = os.environ["CURSOR_HOOKS_JSON"]
if os.path.exists(p):
    try:
        data = json.load(open(p))
    except Exception:
        # Corrupt / non-JSON: back it up and DO NOT overwrite. Clobbering here would wipe other tools'
        # hooks (the old code fell through to writing an empty default). Leave the original for the
        # operator to fix, then re-run install — idempotent once it parses.
        bak = p + f".bak-{int(time.time())}"; shutil.copy(p, bak)
        print(f"hooks.json: UNPARSEABLE — backed up to {bak} and left UNTOUCHED (fix it, then re-run)")
        sys.exit(0)
else:
    data = {}
if not isinstance(data, dict):
    print("hooks.json: top-level is not a JSON object — left untouched"); sys.exit(0)
data.setdefault("version", 1); data.setdefault("hooks", {})
arr = data["hooks"].setdefault("sessionStart", [])
cmd = "./hooks/orchestrator-session.sh"
if not any(isinstance(h, dict) and h.get("command") == cmd for h in arr):
    if os.path.exists(p): shutil.copy(p, p + f".bak-{int(time.time())}")
    arr.append({"command": cmd, "timeout": 20})
    json.dump(data, open(p, "w"), indent=2); open(p, "a").write("\n")
    print("hooks.json: added sessionStart orchestrator-session.sh")
else:
    print("hooks.json: sessionStart already present (idempotent)")
PY
  orch_log "cursor sessionStart hook wired ($CURSOR_HOOKS_DIR/orchestrator-session.sh)"

  # 2) launchd agent: RunAtLoad (login) + every 6h, calls the hook body in --periodic mode.
  cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$ORCH_ROOT/bin/session-hook.sh</string>
    <string>--periodic</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>21600</integer>
  <key>StandardOutPath</key><string>$STATE_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/launchd.err.log</string>
</dict>
</plist>
EOF
  orch_log "launchd plist written: $PLIST_PATH"
  if [ "${ORCH_NO_LAUNCHCTL:-0}" = 1 ]; then
    orch_log "ORCH_NO_LAUNCHCTL=1 — plist written but NOT loaded (hermetic/test mode)"
  elif command -v launchctl >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" >/dev/null 2>&1; then orch_log "launchd agent loaded (bootstrap)"
    else launchctl load -w "$PLIST_PATH" >/dev/null 2>&1 && orch_log "launchd agent loaded (load -w)" || orch_warn "launchd load skipped (load manually: launchctl load -w $PLIST_PATH)"; fi
  else
    orch_warn "launchctl unavailable — plist written; load it on a mac with: launchctl load -w $PLIST_PATH"
  fi

  : > "$STATE_DIR/.installed"
  orch_log "orchestrator install complete (state: $STATE_DIR/.installed)"
}

# ---- cpp-sync (WF2/B4: registry-driven sync of enrolled capabilities into cpp) -------------------
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
SRC_MCP_LOCAL="$(orch_expand "$(orch_cfg_get source_mcp_local)")"

_meta_field() {
  local file="$1" field="$2"
  awk -F': *' -v f="$field" '$1==f{print $2; exit}' "$file" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]'
}

_master_dir() {
  local id="$1" d
  d="$(orch_resolve_skill_master "$SRC_GLOBAL" "$id" 2>/dev/null || true)"
  [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  d="$SRC_MCP_LOCAL/$id"
  [ -f "$d/meta.yml" ] && { printf '%s\n' "$d"; return 0; }
  return 1
}

# _master_kind <id> — kind read LIVE from the master meta.yml (empty if no master resolves).
_master_kind() {
  local d; d="$(_master_dir "$1" || true)"
  [ -n "$d" ] || return 1
  _meta_field "$d/meta.yml" kind
}

_master_flavor() {
  local d flavor; d="$(_master_dir "$1" || true)"
  [ -n "$d" ] || return 1
  flavor="$(_meta_field "$d/meta.yml" flavor)"
  [ -n "$flavor" ] || flavor="1"
  printf '%s\n' "$flavor"
}

preflight_supply_chain() {
  local id="$1" master flavor approved current
  master="$(_master_dir "$id" || true)"
  [ -n "$master" ] || { orch_err "supply-chain: $id has no master"; return 1; }
  flavor="$(_master_flavor "$id" || true)"
  [ "$flavor" = "2" ] || return 0

  approved="$(reg_journal_get "$id" approved_digest)"
  if [ -z "$approved" ]; then
    local raw; raw="$(reg_journal_raw "$id" approved_digest)"
    if [ -n "$raw" ]; then orch_err "supply-chain: $id has malformed approved_digest ($raw)"
    else orch_err "supply-chain: $id flavor-2 is missing approved_digest (run 'orchestrator approve $id')"; fi
    return 1
  fi
  current="$(payload_content_digest "$master" || true)"
  if [ -z "$current" ]; then orch_err "supply-chain: $id digest could not be computed"; return 1; fi
  if [ "$current" != "$approved" ]; then
    orch_err "supply-chain: $id digest drifted (approved=$approved current=$current; run 'orchestrator approve $id' after review)"
    return 1
  fi
  return 0
}

# WF1 half of the preflight (B2/B3): shared metadata-lock parity incl. each capability repo's own
# verifier (verify-skills / verify-capabilities, via lockkit check) + registry<->lock authority.
wf1_preflight() {
  orch_log "WF1 preflight: lockkit check (incl. capability verifiers) + registry reconcile"
  bash "$ORCH_ROOT/lib/lockkit.sh" check || return 1
  bash "$ORCH_ROOT/lib/reconcile.sh" >/dev/null || return 1
  reg_assert_schema || return 1
}

# wf2_gate_ids <id>... — cheap per-id WF2 gates. Sets PF_OK / PF_SKIP / PF_BLOCK (space-prefixed).
# Payload build, zero-link and cpp integrity run afterwards inside vendor.sh, on the combined change.
wf2_gate_ids() {
  local enabled id kind
  enabled=" $(orch_cfg_get enabled_kinds) "; [ "$enabled" = "  " ] && enabled=" skill mcp "
  PF_OK="" PF_SKIP="" PF_BLOCK=""
  for id in "$@"; do
    [ -n "$id" ] || continue
    kind="$(_master_kind "$id" || true)"
    if [ -z "$kind" ]; then PF_BLOCK="$PF_BLOCK $id(no-master)"; continue; fi
    case "$enabled" in *" $kind "*) ;; *) PF_SKIP="$PF_SKIP $id($kind!enabled_kinds)"; continue ;; esac   # (1)
    if ! payload_cpp_kind_for_kind "$kind" >/dev/null 2>&1; then PF_BLOCK="$PF_BLOCK $id($kind!vendorable)"; continue; fi  # (2)
    preflight_supply_chain "$id" || { PF_BLOCK="$PF_BLOCK $id(supply-chain)"; continue; }              # (5)
    PF_OK="$PF_OK $id"
  done
}

# cpp-sync entrypoint. Preflight first (no pushes); only a fully-clear preflight reaches vendor.sh,
# which builds the whole run as ONE change and (with --execute) opens ONE PR.
cmd_cpp_sync() {
  local execute=0 cpp_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --execute) execute=1 ;;
      --cpp-dir) cpp_dir="${2:-}"; shift ;;
      *) orch_err "usage: orchestrator cpp-sync [--execute] [--cpp-dir DIR]"; return 2 ;;
    esac; shift
  done
  wf1_preflight || return 1
  # shellcheck disable=SC2046
  wf2_gate_ids $(managed_ids)

  if [ "${ORCH_CPP_SYNC_PREFLIGHT_ONLY:-0}" = 1 ]; then
    orch_log "cpp-sync preflight-only: OK=[${PF_OK# }] SKIP=[${PF_SKIP# }] BLOCK=[${PF_BLOCK# }]"
    if [ -n "${PF_BLOCK# }" ]; then
      orch_err "cpp-sync: preflight BLOCK set is non-empty -> aborting before any push:${PF_BLOCK}"
      return 1
    fi
    return 0
  fi

  orch_log "cpp-sync preflight: OK=[${PF_OK# }] SKIP=[${PF_SKIP# }] BLOCK=[${PF_BLOCK# }]"
  if [ -n "${PF_BLOCK# }" ]; then
    orch_err "cpp-sync: preflight BLOCK set is non-empty -> aborting before any push:${PF_BLOCK}"
    return 1
  fi

  # ONE change for the whole run (ADR 0002): vendor.sh --sync vendors the OK set (enrolled AND kind in
  # enabled_kinds AND gate-clean), delete-propagates every other orchestrator-marked payload against
  # the fresh cpp clone, and regenerates the manifest — all in one commit/PR. Any capability that
  # fails to build or trips zero-link, or a RED integrity gate, stops the whole run before any push.
  local v_args=(--sync)
  [ "$execute" = 1 ] && v_args+=(--execute)
  [ -n "$cpp_dir" ] && v_args+=(--cpp-dir "$cpp_dir")
  [ "$execute" = 1 ] || orch_log "cpp-sync DRY-RUN: building the ONE combined change (no push)"
  # shellcheck disable=SC2086
  bash "$ORCH_ROOT/lib/vendor.sh" "${v_args[@]}" $PF_OK
}

# per-id vendor entrypoint: the cpp-sync preflight for exactly one enrolled id. vendor.sh then ships
# its payload together with its manifest row, so a per-id run can activate a capability only after the
# same gates cpp-sync applies.
cmd_vendor() {
  local v_args=() id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --execute|--break-glass-admin) v_args+=("$1") ;;
      --cpp-dir) v_args+=(--cpp-dir "${2:-}"); shift ;;
      -*) orch_err "vendor: unknown flag: $1"; return 2 ;;
      *) [ -z "$id" ] || { orch_err "vendor takes exactly one id (cpp-sync ships many together)"; return 2; }; id="$1" ;;
    esac; shift
  done
  [ -n "$id" ] || { orch_err "usage: orchestrator vendor [--execute] [--cpp-dir DIR] <id>"; return 2; }
  # Cheap per-id gates first, then the (slow) WF1 lock/verifier preflight; all pass before any build.
  reg_assert_schema || return 1
  [ "$(reg_state "$id")" = "enrolled" ] \
    || { orch_err "vendor: $id is not enrolled for cpp (run 'orchestrator enroll $id -- <reason>' first)"; return 1; }
  wf2_gate_ids "$id"
  if [ -n "${PF_BLOCK# }${PF_SKIP# }" ]; then
    orch_err "vendor: preflight refused $id:${PF_BLOCK}${PF_SKIP} -> nothing built or pushed"
    return 1
  fi
  wf1_preflight || return 1
  bash "$ORCH_ROOT/lib/vendor.sh" ${v_args[@]+"${v_args[@]}"} "$id"
}

# ---- self-heal (bounded retry over orchestrator verifiers) ---------------------------------------
verifiers_ok() {
  local ok=1
  bash "$ORCH_ROOT/bin/orchestrator.sh" doctor >/tmp/orch-sh.$$ 2>&1 || ok=0
  # a stale/corrupt work clone is the main self-healable failure
  if [ -e "$WORK" ] && ! git -C "$WORK" rev-parse --is-inside-work-tree >/dev/null 2>&1; then ok=0; fi
  return $([ "$ok" = 1 ] && echo 0 || echo 1)
}
heal() {
  orch_log "heal: resetting work clone"
  if orch_guard_rmrf "$WORK"; then rm -rf "$WORK" 2>/dev/null || true
  else orch_err "heal: refusing rm -rf on unsafe work-clone path ('$WORK') — check work_clone_dir in relationship.yml"; fi
}

cmd_selfheal() {
  local N="${ECO_HEAL_RETRIES:-3}" a=1
  while :; do
    orch_log "self-heal attempt $a/$N"
    if verifiers_ok; then orch_log "self-heal: GREEN on attempt $a"; return 0; fi
    [ "$a" -ge "$N" ] && { orch_err "self-heal: exhausted $N attempts"; return 1; }
    heal; a=$((a+1))
  done
}

SUB="${1:-}"; shift || true
case "$SUB" in
  install)   cmd_install "$@" ;;
  cpp-sync)  cmd_cpp_sync "$@" ;;
  vendor)    cmd_vendor "$@" ;;
  self-heal) cmd_selfheal "$@" ;;
  *) orch_err "selfmanage: unknown subcommand '$SUB' (install|cpp-sync|vendor|self-heal)"; exit 2 ;;
esac
