#!/usr/bin/env bash
# lib/selfmanage.sh — orchestrator self-management (reorg-v2 WS-9 / ORCH-C). Subcommands:
#   install     install triggers (Cursor sessionStart hook + launchd agent) + state. Idempotent.
#   cpp-sync    registry-driven sync of enrolled capabilities into cpp (WF2/B4). PREFLIGHT (kind /
#               enabled_kinds / zero-link / cpp-integrity) then vendor; set-diff delete-propagation
#               for excluded/demoted ids (denylist-protected). DRY-RUN by default; --execute lands PRs.
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

# _master_kind <id> — kind read LIVE from the master meta.yml (empty if no master resolves).
_master_kind() {
  local id="$1" d
  for d in "$SRC_GLOBAL/$id" "$SRC_MCP_LOCAL/$id"; do
    [ -f "$d/meta.yml" ] && { awk -F': *' '/^kind:/{print $2; exit}' "$d/meta.yml" | tr -d '"' | tr -d "'" | tr -d '[:space:]'; return 0; }
  done
  return 1
}

# preflight_supply_chain <id> — FOLLOW-ON-PLAN STUB. A no-op in this plan; the follow-on plan
# implements the flavor-2 digest-approval gate (approved_digest bound to the content digest at
# --execute). Always returns 0 here so cpp-sync's contract has the hook wired but inert.
preflight_supply_chain() { return 0; }

# cpp-sync entrypoint. Preflight first (no pushes); only a fully-clear preflight proceeds to --execute.
cmd_cpp_sync() {
  local execute=0; [ "${1:-}" = "--execute" ] && execute=1
  reg_assert_schema || return 1
  local enabled denylist; enabled=" $(orch_cfg_get enabled_kinds) "; [ "$enabled" = "  " ] && enabled=" skill mcp "
  denylist=" $(orch_cfg_get cpp_sync_denylist) "
  local enrolled; enrolled="$(managed_ids)"

  # ---- Preflight: cheap kind gates, then a dry-run vendor (zero-link + cpp-integrity) per ok id ----
  local ok="" skip="" block="" id kind
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    kind="$(_master_kind "$id" || true)"
    if [ -z "$kind" ]; then block="$block $id(no-master)"; continue; fi
    case "$enabled" in *" $kind "*) ;; *) skip="$skip $id($kind!enabled_kinds)"; continue ;; esac        # (1)
    if ! payload_cpp_kind_for_kind "$kind" >/dev/null 2>&1; then block="$block $id($kind!vendorable)"; continue; fi  # (2)
    preflight_supply_chain "$id" || { block="$block $id(supply-chain)"; continue; }                      # (5) stub
    ok="$ok $id"
  done <<< "$enrolled"

  # (3)+(4): dry-run vendor builds the payload, asserts zero-link, runs cpp's integrity engine and
  # refuses RED. A non-zero dry-run for an ok id is a hard block (moves it out of the executable set).
  local ok2="" rc_pf=0
  for id in $ok; do
    if bash "$ORCH_ROOT/lib/vendor.sh" "$id" >/tmp/orch-pf.$$ 2>&1; then ok2="$ok2 $id"
    else block="$block $id(preflight)"; orch_warn "preflight FAILED for $id:"; sed 's/^/    | /' /tmp/orch-pf.$$ | tail -8 >&2; fi
  done
  rm -f /tmp/orch-pf.$$
  ok="$ok2"

  orch_log "cpp-sync preflight: OK=[${ok# }] SKIP=[${skip# }] BLOCK=[${block# }]"
  if [ -n "${block# }" ]; then
    orch_err "cpp-sync: preflight BLOCK set is non-empty -> aborting before any push:${block}"
    return 1
  fi

  # ---- Delete-propagation set-diff: vendored-in-cpp but NOT enrolled-for-cpp (excluded/demoted/
  # gone), minus the denylist (orchestrator-owned tooling). Computed against the on-disk cpp worktree.
  local cpp quiver; cpp="$(orch_expand "$(orch_cfg_get ld_cpp_worktree)")"
  quiver="$(orch_cfg_get cpp_quiver_path)"; quiver="${quiver:-quiver}"
  local enrolled_enabled=" $ok "   # ok = enrolled AND kind in enabled_kinds AND preflight-clean
  local to_delete="" d vid
  if [ -d "$cpp/$quiver" ]; then
    for d in "$cpp/$quiver"/*/*; do
      [ -e "$d" ] || continue
      # ONLY orchestrator-vendored payloads are delete-candidates. The VENDORED.md marker (written by
      # payload_emit_vendored_md) distinguishes our copies from cpp-NATIVE quiver items (council,
      # quickhost, ...), which the orchestrator must never touch. This bounds the delete blast radius
      # to ld-owned payloads (the cpp-side reconciler enforces the same invariant independently, B6).
      [ -f "$d/VENDORED.md" ] || continue
      vid="$(basename "$d")"
      case "$denylist" in *" $vid "*) continue ;; esac
      case "$enrolled_enabled" in *" $vid "*) continue ;; esac
      to_delete="$to_delete $vid"
    done
  fi

  # ---- Execute (or report dry-run) ----
  # The manifest (B5) is regenerated as ONE atomic PR AFTER the per-id payload PRs, listing exactly
  # the `ok` set under items: (eventual consistency is safe — the cpp reconciler warns, never prunes,
  # on a not-yet-landed payload). DRY-RUN does both as dry-runs so the operator sees the full plan.
  local rc=0
  if [ "$execute" != 1 ]; then
    orch_log "cpp-sync DRY-RUN: would vendor:${ok:- (none)}; would delete:${to_delete:- (none)}. Re-run with --execute."
    bash "$ORCH_ROOT/lib/manifest.sh" $ok || rc=1
    return "$rc"
  fi
  for id in $ok; do
    orch_log "cpp-sync: vendor $id (execute)"
    bash "$ORCH_ROOT/lib/vendor.sh" --execute "$id" || rc=1
  done
  for vid in $to_delete; do
    orch_log "cpp-sync: delete-propagate $vid (execute)"
    bash "$ORCH_ROOT/lib/vendor.sh" --delete --execute "$vid" || rc=1
  done
  orch_log "cpp-sync: regenerate data-plane manifest (atomic PR, after payloads)"
  bash "$ORCH_ROOT/lib/manifest.sh" --execute $ok || rc=1
  return "$rc"
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
  self-heal) cmd_selfheal "$@" ;;
  *) orch_err "selfmanage: unknown subcommand '$SUB' (install|cpp-sync|self-heal)"; exit 2 ;;
esac
