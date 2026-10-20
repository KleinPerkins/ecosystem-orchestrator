#!/usr/bin/env bash
# lib/vendor.sh — orchestrator vendoring engine (reorg-v2 WS-7). The ONLY sanctioned writer of the
# ld->cpp edge. Builds SELF-SUFFICIENT, ld-agnostic copies of global capabilities, removes retired
# ones, regenerates the data-plane manifest (lib/manifest.sh), and lands ALL of it as ONE LD-authored
# GOVERNED PR (ADR 0002): cpp main never holds a payload without its manifest row, or an active
# manifest row without its payload, because both always arrive in the same squash commit.
# PR authoring: Regime B (cpp data-plane / WF2 / Decision B) — see README.md § PR authoring.
#
#   vendor.sh [--execute] [--break-glass-admin] [--cpp-dir DIR] [--delete] <id>
#   vendor.sh --sync [--execute] [--break-glass-admin] [--cpp-dir DIR] [<id> ...]
#     <id>          per-id mode: vendor one capability (with --delete: remove it). Only that id's
#                   manifest row changes; every other row is carried unchanged.
#     --sync        cpp-sync mode: vendor every listed id, remove every other orchestrator-marked
#                   (VENDORED.md) payload outside cpp_sync_denylist, and regenerate the manifest so its
#                   active items are exactly the listed ids.
#     (default)     DRY-RUN: refresh a work clone, stage the whole change on one branch (a translated
#                   cpp-schema meta.yml per payload), assert zero-link per payload, commit once, run
#                   cpp's integrity engine on the combined tree. NO push / NO PR.
#     --execute     additionally (GATED on integrity green, and refused while any orchestrator PR is
#                   still open in cpp) push the branch, open the ONE PR, and enable GitHub NATIVE
#                   auto-merge (`gh pr merge --auto --squash`). Decision B: routine landing relies on
#                   cpp's server-side required checks + the @affirm-cpp-bot CODEOWNER auto-approval —
#                   NO human reviewer, NO admin bypass.
#     --break-glass-admin   EMERGENCY ONLY: land via `gh pr merge --admin --squash`, bypassing cpp's
#                   server-side checks + CODEOWNERS. Off by default; also gated by ORCH_VENDOR_BREAKGLASS_ADMIN=1.
#     --cpp-dir DIR use an existing git tree as the cpp clone (tests/fixtures; skips network clone).
#
# FAIL CLOSED: a capability that cannot be built (missing master, non-global scope, unvendorable kind,
# generator error) or trips zero-link aborts the WHOLE change before anything is committed; a RED
# integrity gate refuses the push. Nothing ever ships partially.
# SAFETY: never writes cpp control-plane paths (_ops/ .github/) — every staged path must sit under a
# targeted payload dir or the manifest; removal only touches marked (VENDORED.md) orchestrator
# payloads, never cpp-native items or the fixed tooling ids; the routine landing path NEVER
# force-merges (auto-merge waits for cpp's own checks + bot approval). Policy gates (enrollment,
# enabled_kinds, flavor-2 approved_digest, lockkit/reconcile) run in the operator verbs
# (lib/selfmanage.sh `cpp-sync` / `vendor`) before this engine is invoked.
set -uo pipefail
VEN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$VEN_LIB_DIR/common.sh"
. "$VEN_LIB_DIR/payload.sh"

DELETE=0 EXECUTE=0 SYNC=0 CPP_DIR="" BREAKGLASS="${ORCH_VENDOR_BREAKGLASS_ADMIN:-0}"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --delete)  DELETE=1 ;;
    --sync)    SYNC=1 ;;
    --execute) EXECUTE=1 ;;
    --break-glass-admin) BREAKGLASS=1 ;;
    --cpp-dir) CPP_DIR="${2:-}"; shift ;;
    -*) orch_err "unknown flag: $1"; exit 2 ;;
    *) args+=("$1") ;;
  esac; shift
done
USAGE="usage: vendor.sh [--execute] [--cpp-dir DIR] [--delete] <id>  |  vendor.sh --sync [--execute] [--cpp-dir DIR] [<id> ...]"
if [ "$SYNC" = 1 ]; then
  [ "$DELETE" = 0 ] || { orch_err "--sync and --delete cannot be combined ($USAGE)"; exit 2; }
else
  [ "${#args[@]}" -eq 1 ] || { orch_err "$USAGE"; exit 2; }
fi

QUIVER="$(orch_cfg_get cpp_quiver_path)";             QUIVER="${QUIVER:-quiver}"
DEFAULT_BRANCH="$(orch_cfg_get cpp_default_branch)";  DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
PREFIX="$(orch_cfg_get cpp_pr_branch_prefix)";        PREFIX="${PREFIX:-orchestrator/vendor}"
FORBIDDEN_PATHS="$(orch_cfg_get cpp_forbidden_paths)"
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
SRC_MCP_LOCAL="$(orch_expand "$(orch_cfg_get source_mcp_local)")"
DENYLIST=" $(orch_cfg_get cpp_sync_denylist) "; [ "$DENYLIST" = "  " ] && DENYLIST=" eco-capability-sync "
MANIFEST_REL="$(orch_manifest_rel)"

# Resolve the on-disk master directory for an id. Skills live under source_skills_global; mcp
# capabilities (kind: mcp) live flat under source_mcp_local (the kp-mcp monorepo root).
resolve_master() {
  local d
  d="$(orch_resolve_skill_master "$SRC_GLOBAL" "$1" 2>/dev/null || true)"
  [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  if [ -n "$SRC_MCP_LOCAL" ] && [ -d "$SRC_MCP_LOCAL/$1" ]; then printf '%s\n' "$SRC_MCP_LOCAL/$1"; return 0; fi
  return 1
}

FAILED=""
fail_id() { FAILED="$FAILED
    - $1: $2"; }

prepare_clone() {
  if [ -n "$CPP_DIR" ]; then
    [ -d "$CPP_DIR/.git" ] || { orch_err "--cpp-dir is not a git repo: $CPP_DIR"; exit 2; }
    WORK="$CPP_DIR"; orch_log "using provided cpp clone: $WORK"; return
  fi
  WORK="$(orch_expand "$(orch_cfg_get work_clone_dir)")"
  local url; url="$(orch_cfg_get cpp_clone_url)"
  if [ -d "$WORK/.git" ]; then
    orch_log "refreshing cpp work clone: $WORK"
    git -C "$WORK" fetch --depth 1 origin "$DEFAULT_BRANCH" >/dev/null 2>&1 || { orch_err "fetch failed"; exit 1; }
    git -C "$WORK" checkout -q "$DEFAULT_BRANCH" 2>/dev/null || git -C "$WORK" checkout -qB "$DEFAULT_BRANCH" "origin/$DEFAULT_BRANCH"
    git -C "$WORK" reset -q --hard "origin/$DEFAULT_BRANCH"
    git -C "$WORK" clean -qfd "$QUIVER" 2>/dev/null || true
    # Prune our own disposable vendor branches (now that we're back on $DEFAULT_BRANCH) so the work
    # clone can't accumulate one stale orchestrator/vendor/<id>-<ts> branch per run forever.
    git -C "$WORK" for-each-ref --format='%(refname:short)' "refs/heads/$PREFIX" 2>/dev/null \
      | while IFS= read -r _b; do [ -n "$_b" ] && git -C "$WORK" branch -qD "$_b" 2>/dev/null || true; done
  else
    orch_log "cloning cpp (partial, blob:none) -> $WORK"
    mkdir -p "$(dirname "$WORK")"
    git clone --filter=blob:none --no-tags --branch "$DEFAULT_BRANCH" "$url" "$WORK" >/dev/null 2>&1 \
      || { orch_err "clone failed ($url) — cpp access?"; exit 1; }
  fi
}

set_cpp_identity() {
  local email name="KleinPerkins" people="$WORK/_ops/facts/people.yml"
  email="$(orch_canonical_noreply)"
  if [ -f "$people" ]; then
    local found; found="$(awk '
      /KleinPerkins/ {h=1}
      h && /email:/ {gsub(/.*email:[[:space:]]*/,""); gsub(/["'\''[:space:]]/,""); print; exit}' "$people" 2>/dev/null || true)"
    [ -n "$found" ] && email="$found"
  fi
  git -C "$WORK" config user.name  "$name"
  git -C "$WORK" config user.email "$email"
  orch_log "cpp commit identity: $name <$email>"
}

# plan_vendor <id> — resolve the master + cpp target dir, or record why the id cannot ship.
# Defense-in-depth scope gate (Option A; 2026-06-26): the orchestrator MUST NEVER vendor a
# non-global master into cpp. Skill masters get this for free via the directory paradigm (only
# global/ skills resolve under SRC_GLOBAL); kind:mcp lives flat under SRC_MCP_LOCAL, so the
# manifest's explicit `scope:` is the gate.
V_IDS=() V_MASTERS=() V_RELS=()
plan_vendor() {
  local id="$1" master scope kind cat
  case "$DENYLIST" in *" $id "*) fail_id "$id" "fixed orchestrator tooling id (cpp_sync_denylist); never vendored"; return ;; esac
  master="$(resolve_master "$id" || true)"
  if [ -z "$master" ] || [ ! -d "$master" ]; then fail_id "$id" "master not found"; return; fi
  scope="$(orch_meta_field "$master/meta.yml" scope)"
  if [ -n "$scope" ] && [ "$scope" != "global" ]; then
    fail_id "$id" "refusing to vendor: master declares scope='$scope' (only scope:global is vendorable to cpp)"; return
  fi
  kind="$(orch_meta_field "$master/meta.yml" kind)"; kind="${kind:-skill}"
  cat="$(payload_cpp_category_for_kind "$kind" 2>/dev/null)" || { fail_id "$id" "kind '$kind' is not vendorable to cpp"; return; }
  V_IDS+=("$id"); V_MASTERS+=("$master"); V_RELS+=("$QUIVER/$cat/$id")
}

# plan_remove <id> — every orchestrator-marked quiver/*/<id> payload is removed. An unmarked match is a
# cpp-native item the orchestrator does not own and must never touch.
R_IDS=() R_RELS=()
plan_remove() {
  local id="$1" d rel native=""
  case "$DENYLIST" in *" $id "*) fail_id "$id" "fixed orchestrator tooling id (cpp_sync_denylist); never removed"; return ;; esac
  for d in "$WORK/$QUIVER"/*/"$id"; do
    [ -d "$d" ] || continue
    rel="${d#"$WORK"/}"
    if [ -f "$d/VENDORED.md" ]; then R_IDS+=("$id"); R_RELS+=("$rel")
    else native="$native $rel"; fi
  done
  if [ -n "$native" ]; then
    if [ "${#R_RELS[@]}" -eq 0 ]; then fail_id "$id" "no VENDORED.md marker at$native (cpp-native; never removed)"
    else orch_warn "leaving cpp-native (unmarked) path(s) untouched:$native"; fi
  elif [ "${#R_RELS[@]}" -eq 0 ]; then
    orch_log "nothing to remove: no $QUIVER/*/$id payload in cpp (its manifest row, if any, is still dropped)"
  fi
}

# plan_sync_removals — cpp-sync delete-propagation set-diff against the FRESH cpp tree: orchestrator-
# marked payloads (VENDORED.md) that are not in this run's vendor set, minus the fixed tooling ids.
# The marker distinguishes our copies from cpp-NATIVE quiver items (council, quickhost, ...), which the
# orchestrator must never touch; the cpp-side reconciler enforces the same bound independently (B6).
plan_sync_removals() {
  local keep d vid
  keep=" ${args[*]+${args[*]}} "
  for d in "$WORK/$QUIVER"/*/*; do
    [ -d "$d" ] && [ -f "$d/VENDORED.md" ] || continue
    vid="$(basename "$d")"
    case "$DENYLIST" in *" $vid "*) continue ;; esac
    case "$keep" in *" $vid "*) continue ;; esac
    R_IDS+=("$vid"); R_RELS+=("${d#"$WORK"/}")
  done
}

# cpp category + kind translations, the translated cpp-quiver meta, the mcp/tool descriptors and
# VENDORED.md all live in lib/payload.sh (shared with consistency.sh so regen-and-cmp is byte-identical
# to vendor output).
build_payload() {
  local ID="$1" MASTER="$2" REL="$3" dst="$WORK/$3" mk shape base_meta
  # Guard the destructive refresh: $dst must be a safe (deep, absolute) path so a mis-set WORK/REL can
  # never `rm -rf` a top-level dir or $HOME (item-21 hardening; $dst is always $WORK/quiver/<cat>/<id>).
  orch_guard_rmrf "$dst" || return 1
  rm -rf "$dst"; mkdir -p "$dst"
  mk="$(orch_meta_field "$MASTER/meta.yml" kind)"
  shape="$(orch_meta_field "$MASTER/meta.yml" shape)"
  if [ "$mk" = "mcp" ]; then
    # Descriptor mode: NO source tar (mcp masters carry forbidden-ld tokens).
    payload_emit_mcp_descriptor "$dst" "$ID" || return 1
  elif [ "$mk" = "tool" ] && [ "$shape" = "release-descriptor" ]; then
    # Pointer-only SSP (e.g. awa): the release repo/ref/commit are ld-only provenance — descriptor,
    # never source (docs/tool-descriptor-cpp-sync-design.md).
    payload_emit_tool_descriptor "$dst" "$ID" || return 1
  elif [ "$mk" = "tool" ] && [ "$shape" = "snapshot" ]; then
    # Snapshot SSP (e.g. operator-voice): the shelf carries real, already zero-link-clean runtime
    # bytes under payload/ — vendor them verbatim (docs/tool-snapshot-cpp-sync-design.md).
    payload_emit_tool_snapshot "$dst" "$ID" "$MASTER" || return 1
  else
    ( cd "$MASTER" && payload_shared_list "$MASTER" | tar -cf - -T - ) | ( cd "$dst" && tar -xf - ) || return 1
  fi
  payload_emit_vendored_md "$dst" "$ID" || return 1
  base_meta="$(git -C "$WORK" show "$DEFAULT_BRANCH:$REL/meta.yml" 2>/dev/null || true)"
  payload_emit_cpp_meta "$dst" "$ID" "$MASTER" "$base_meta" || return 1
}

cpp_integrity() {
  local rc=0 ran=0 log="/tmp/orch-integ.$$"
  # RCE guard: when called from an UNATTENDED periodic trigger, never execute cpp's Makefile/integrity
  # engine freshly fetched from origin/main. Skipping yields gate=INDETERMINATE (which never auto-lands).
  if [ "${ORCH_SKIP_CPP_EXEC:-0}" = 1 ]; then orch_warn "cpp integrity SKIPPED (ORCH_SKIP_CPP_EXEC=1); gate = INDETERMINATE"; return 2; fi
  if [ -f "$WORK/Makefile" ] && grep -qE '^(verify|integrity|check):' "$WORK/Makefile" 2>/dev/null; then
    ran=1; ( cd "$WORK" && make verify ) >"$log" 2>&1 || rc=$?
  elif [ -x "$WORK/_ops/ci/cpp-integrity-engine" ]; then
    ran=1; ( cd "$WORK" && python3 _ops/ci/cpp-integrity-engine check --ci ) >"$log" 2>&1 || rc=$?
  elif [ -x "$WORK/_ops/bin/cpp-doctor.sh" ]; then
    ran=1; ( cd "$WORK" && bash _ops/bin/cpp-doctor.sh ) >"$log" 2>&1 || rc=$?
  fi
  if [ "$ran" = 0 ]; then orch_warn "no cpp integrity entrypoint found; gate = INDETERMINATE"; return 2; fi
  # rc 2 means "could not run" (INDETERMINATE) only when returned above; a failing check is always
  # RED, even when the tool itself exits 2 (make does).
  if [ "$rc" -eq 0 ]; then orch_log "cpp integrity: GREEN"
  else orch_warn "cpp integrity: RED (rc=$rc)"; sed 's/^/    | /' "$log" | tail -14 >&2; rc=1; fi
  rm -f "$log"
  return "$rc"
}

join_ids() { local out="" x; for x in "$@"; do out="${out:+$out, }$x"; done; printf '%s' "${out:-(none)}"; }

# --- main flow ------------------------------------------------------------------------------------
prepare_clone
set_cpp_identity

if [ "$SYNC" = 1 ]; then
  for id in ${args[@]+"${args[@]}"}; do plan_vendor "$id"; done
  plan_sync_removals
  orch_log "sync plan: vendor ${#args[@]} enrolled capabilities (unchanged ones stage nothing); remove: $(join_ids ${R_IDS[@]+"${R_IDS[@]}"})"
elif [ "$DELETE" = 1 ]; then
  plan_remove "${args[0]}"
else
  plan_vendor "${args[0]}"
fi
if [ -n "$FAILED" ]; then
  orch_err "ABORT before any commit/push — nothing ships because these capabilities cannot:$FAILED"
  exit 1
fi

TS="$(date +%Y%m%d-%H%M%S)"
if [ "$SYNC" = 1 ]; then BRANCH="$PREFIX/sync-$TS"
elif [ "$DELETE" = 1 ]; then BRANCH="$PREFIX/rm-${args[0]}-$TS"
else BRANCH="$PREFIX/${args[0]}-$TS"; fi
git -C "$WORK" checkout -qB "$BRANCH"

i=0
while [ "$i" -lt "${#V_IDS[@]}" ]; do
  id="${V_IDS[$i]}" rel="${V_RELS[$i]}"
  if ! build_payload "$id" "${V_MASTERS[$i]}" "$rel"; then fail_id "$id" "payload build failed"
  elif ! orch_zero_link cpp "$WORK/$rel"; then fail_id "$id" "payload tripped zero-link (ld tokens in cpp)"
  else git -C "$WORK" add -A -- "$rel"; fi
  i=$((i+1))
done
for rel in ${R_RELS[@]+"${R_RELS[@]}"}; do
  git -C "$WORK" rm -rq -- "$rel" || fail_id "$rel" "git rm failed"
done
if [ -n "$FAILED" ]; then
  orch_err "ABORT before any commit/push — nothing ships because these capabilities failed:$FAILED"
  exit 1
fi

# The manifest is regenerated INSIDE this same change (never its own PR): cpp-sync rewrites the
# active set; per-id runs touch only the named id's row.
m_args=(--cpp-dir "$WORK")
if [ "$SYNC" = 1 ]; then m_args+=(${V_IDS[@]+"${V_IDS[@]}"})
elif [ "$DELETE" = 1 ]; then m_args+=(--keep-existing --drop "${args[0]}")
else m_args+=(--keep-existing "${args[0]}"); fi
bash "$VEN_LIB_DIR/manifest.sh" "${m_args[@]}" && git -C "$WORK" add -- "$MANIFEST_REL" \
  || { orch_err "ABORT: manifest regeneration failed; nothing committed"; exit 1; }

# idempotent no-op: if nothing staged, every item already matches the base branch.
CHANGED="$(git -C "$WORK" diff --cached --name-only)"
if [ -z "$CHANGED" ]; then
  orch_log "no changes — already in sync on $DEFAULT_BRANCH (no-op; no PR)"; exit 0
fi

# control-plane + scope guard: only the targeted payload dirs and the manifest may be staged.
for p in $FORBIDDEN_PATHS; do
  if printf '%s\n' "$CHANGED" | grep -qE "^$p"; then orch_err "ABORT: staged a control-plane path ($p)"; exit 1; fi
done
OUTSIDE=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  inside=0
  [ "$f" = "$MANIFEST_REL" ] && inside=1
  for r in ${V_RELS[@]+"${V_RELS[@]}"} ${R_RELS[@]+"${R_RELS[@]}"}; do
    case "$f" in "$r"/*) inside=1 ;; esac
  done
  [ "$inside" = 1 ] || OUTSIDE="$OUTSIDE
    $f"
done <<< "$CHANGED"
if [ -n "$OUTSIDE" ]; then orch_err "ABORT: staged paths outside the targeted payloads + manifest:$OUTSIDE"; exit 1; fi

VENDORED=() REMOVED=()
i=0
while [ "$i" -lt "${#V_IDS[@]}" ]; do
  git -C "$WORK" diff --cached --quiet -- "${V_RELS[$i]}" || VENDORED+=("${V_IDS[$i]}")
  i=$((i+1))
done
for id in $(printf '%s\n' ${R_IDS[@]+"${R_IDS[@]}"} | awk 'NF && !seen[$0]++'); do REMOVED+=("$id"); done
MANIFEST_STATE="unchanged"; printf '%s\n' "$CHANGED" | grep -qxF "$MANIFEST_REL" && MANIFEST_STATE="updated"
FILES="$(printf '%s\n' "$CHANGED" | grep -c .)"

if [ "$SYNC" != 1 ] && [ "$DELETE" = 1 ]; then
  MSG="chore(quiver): remove vendored ${args[0]} (orchestrator delete-propagation)"
elif [ "$SYNC" != 1 ]; then
  MSG="feat(quiver): vendor ${args[0]} (orchestrator sync)"
else
  ctype="chore"; [ "${#VENDORED[@]}" -gt 0 ] && ctype="feat"
  parts=""
  [ "${#VENDORED[@]}" -gt 0 ] && parts="vendor: $(join_ids "${VENDORED[@]}")"
  [ "${#REMOVED[@]}" -gt 0 ] && parts="${parts:+$parts; }remove: $(join_ids "${REMOVED[@]}")"
  MSG="$ctype(quiver): orchestrator sync (${parts:-manifest refresh})"
  [ "${#MSG}" -le 120 ] || MSG="$ctype(quiver): orchestrator sync (${#VENDORED[@]} vendored, ${#REMOVED[@]} removed)"
fi
SUMMARY="- Vendored: $(join_ids ${VENDORED[@]+"${VENDORED[@]}"})
- Removed: $(join_ids ${REMOVED[@]+"${REMOVED[@]}"})
- Capability manifest: $MANIFEST_STATE"

git -C "$WORK" commit -q -m "$MSG" -m "$SUMMARY"
orch_log "committed ONE change on $BRANCH: $MSG"

set +e; cpp_integrity; INTEG=$?; set -e
case "$INTEG" in 0) GATE="green" ;; 2) GATE="indeterminate" ;; *) GATE="red" ;; esac

orch_log "ONE combined cpp PR planned (branch $BRANCH; gate=$GATE; $FILES files):"
orch_log "  title:    $MSG"
orch_log "  vendor:   $(join_ids ${VENDORED[@]+"${VENDORED[@]}"})"
orch_log "  remove:   $(join_ids ${REMOVED[@]+"${REMOVED[@]}"})"
orch_log "  manifest: $MANIFEST_STATE"

if [ "$EXECUTE" != 1 ]; then
  orch_log "DRY-RUN complete (branch $BRANCH local only). Re-run with --execute to open this one PR."
  exit 0
fi

# --- EXECUTE: push + governed PR + landing (Decision B) -------------------------------------------
# Routine landing = GitHub NATIVE auto-merge: enable `--auto --squash` and let cpp's OWN server-side
# required checks + the @affirm-cpp-bot CODEOWNER auto-approval gate the merge. No human reviewer is
# required for a quiver-only PR, and the orchestrator NEVER force-merges on the routine path. `--admin`
# (bypass) is BREAK-GLASS only, behind --break-glass-admin / ORCH_VENDOR_BREAKGLASS_ADMIN=1.
if [ "$GATE" = "red" ]; then orch_err "gate RED — refusing to push a failing PR (Deviation-2). Branch kept: $BRANCH"; exit 1; fi
command -v gh >/dev/null 2>&1 || { orch_err "gh not available; cannot open PR"; exit 1; }
CPP_REPO="$(orch_cfg_get cpp_repo)"
# One orchestrator PR in flight at a time: every sync/vendor PR rewrites the shared manifest, so a
# second one would duplicate or conflict with it, and legacy per-capability PRs must land first.
orch_refuse_if_orchestrator_pr_open "$CPP_REPO" "$PREFIX" || { orch_err "Branch kept locally: $BRANCH"; exit 1; }

git -C "$WORK" push -u origin "$BRANCH" >/dev/null 2>&1 || { orch_err "push failed"; exit 1; }
PR_BODY="Automated by the ecosystem orchestrator (LD-authored, quiver-only). Local cpp-integrity-engine gate: $GATE.

One atomic PR: every capability change below and the matching capability-manifest update land together, so main never lists a capability whose files are missing.
$SUMMARY

Landing via GitHub native auto-merge — gated by cpp's required checks + @affirm-cpp-bot CODEOWNER approval (no human reviewer; no admin bypass)."
PR_URL="$(gh pr create --repo "$CPP_REPO" --base "$DEFAULT_BRANCH" --head "$BRANCH" \
            --title "$MSG" --body "$PR_BODY" 2>/dev/null || true)"
[ -n "$PR_URL" ] && orch_log "PR: $PR_URL" || { orch_err "PR create failed"; exit 1; }

if [ "$GATE" != "green" ]; then
  orch_warn "gate=$GATE -> PR left OPEN for operator review: $PR_URL"; exit 0
fi

if [ "$BREAKGLASS" = 1 ]; then
  orch_warn "BREAK-GLASS: landing via --admin (bypasses cpp server checks + CODEOWNERS). PR: $PR_URL"
  if gh pr merge "$PR_URL" --repo "$CPP_REPO" --admin --squash --delete-branch >/dev/null 2>&1; then orch_log "break-glass merged: $PR_URL"
  else orch_warn "break-glass admin merge failed; PR left open: $PR_URL"; exit 1; fi
else
  orch_log "gate green -> enabling GitHub native auto-merge (squash); cpp checks + bot approval will land it"
  if gh pr merge "$PR_URL" --repo "$CPP_REPO" --auto --squash --delete-branch >/dev/null 2>&1; then
    orch_log "auto-merge enabled: $PR_URL (merges once cpp required checks pass + @affirm-cpp-bot approves)"
  else
    orch_warn "could not enable auto-merge (repo 'Allow auto-merge' off, or not yet mergeable). PR left OPEN: $PR_URL"
    orch_warn "operator: confirm cpp repo allows auto-merge + bot auto-approves orchestrator quiver PRs (governance follow-up)."
    exit 0
  fi
fi
