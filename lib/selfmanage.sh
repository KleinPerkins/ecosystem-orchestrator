#!/usr/bin/env bash
# lib/selfmanage.sh — orchestrator self-management (reorg-v2 WS-9 / ORCH-C). Subcommands:
#   install     install triggers (Cursor sessionStart hook + launchd agent) + state. Idempotent.
#   sync        reconcile every managed item into cpp. DRY-RUN by default; --execute lands PRs.
#   self-heal   bounded retry loop (N=3) over orchestrator verifiers; heals a stale work clone.
set -uo pipefail
SM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$SM_LIB_DIR/common.sh"

PLIST_LABEL="com.kleinperkins.orchestrator"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
CURSOR_HOOKS_DIR="$HOME/.cursor/hooks"
CURSOR_HOOKS_JSON="$HOME/.cursor/hooks.json"
MANAGED="$ORCH_ROOT/config/managed-items.txt"
WORK="$(orch_expand "$(orch_cfg_get work_clone_dir)")"
STATE_DIR="$(dirname "$WORK")"

managed_ids() { grep -vE '^[[:space:]]*(#|$)' "$MANAGED" 2>/dev/null || true; }

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

# ---- sync (reconcile managed items into cpp) -----------------------------------------------------
cmd_sync() {
  local execute=0; [ "${1:-}" = "--execute" ] && execute=1
  local ids; ids="$(managed_ids)"
  [ -n "$ids" ] || { orch_log "sync: no managed items"; return 0; }
  local rc=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    orch_log "sync: $id ($([ "$execute" = 1 ] && echo execute || echo dry-run))"
    if [ "$execute" = 1 ]; then bash "$ORCH_ROOT/lib/vendor.sh" --execute "$id" || rc=1
    else bash "$ORCH_ROOT/lib/vendor.sh" "$id" || rc=1; fi
    # Decision A: symlink-dedup is abandoned — NO post-sync dedup --reassert (that wrote the live cpp
    # index from a background job = one-writer violation). cpp keeps the real vendored copy; drift is
    # caught by the consistency verify (lib/consistency.sh), not hidden behind skip-worktree.
  done <<< "$ids"
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
  sync)      cmd_sync "$@" ;;
  self-heal) cmd_selfheal "$@" ;;
  *) orch_err "selfmanage: unknown subcommand '$SUB' (install|sync|self-heal)"; exit 2 ;;
esac
