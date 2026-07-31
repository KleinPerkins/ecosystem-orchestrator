#!/usr/bin/env bash
# lib/vendor.sh — orchestrator vendoring engine (reorg-v2 WS-7). The ONLY sanctioned writer of the
# ld->cpp edge. Builds a SELF-SUFFICIENT, ld-agnostic copy of a global capability and lands it in
# cpp/quiver via an LD-authored GOVERNED PR; the delete path propagates a master removal the same way.
#
#   vendor.sh [--delete] [--execute] [--break-glass-admin] [--cpp-dir DIR] <id>
#     (default)     DRY-RUN: clone/refresh a work clone, build+stage payload (correct cpp quiver
#                   category + a translated cpp-schema meta.yml), assert zero-link, run cpp's
#                   integrity engine locally, commit on a branch. NO push / NO PR.
#     --execute     additionally push the branch, open the PR, and (GATED on integrity green) enable
#                   GitHub NATIVE auto-merge (`gh pr merge --auto --squash`). Decision B: routine
#                   landing relies on cpp's server-side required checks + the @affirm-cpp-bot
#                   CODEOWNER auto-approval — NO human reviewer, NO admin bypass.
#     --break-glass-admin   EMERGENCY ONLY: land via `gh pr merge --admin --squash`, bypassing cpp's
#                   server-side checks + CODEOWNERS. Off by default; also gated by ORCH_VENDOR_BREAKGLASS_ADMIN=1.
#     --delete      removal mode: git rm the vendored quiver/<cat>/<id> instead of writing it.
#     --cpp-dir DIR use an existing git tree as the cpp clone (tests/fixtures; skips network clone).
#
# SAFETY: never writes cpp control-plane paths (_ops/ .github/) — relies on cpp's WILDCARD
# /quiver/ ownership so a quiver-only add needs no CODEOWNERS/ownership regen; aborts if the staged
# payload trips zero-link (mode cpp); the local engine gate must be GREEN before any push; the routine
# landing path NEVER force-merges (auto-merge waits for cpp's own checks + bot approval).
set -uo pipefail
VEN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$VEN_LIB_DIR/common.sh"
. "$VEN_LIB_DIR/payload.sh"

DELETE=0 EXECUTE=0 CPP_DIR="" BREAKGLASS="${ORCH_VENDOR_BREAKGLASS_ADMIN:-0}"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --delete)  DELETE=1 ;;
    --execute) EXECUTE=1 ;;
    --break-glass-admin) BREAKGLASS=1 ;;
    --cpp-dir) CPP_DIR="${2:-}"; shift ;;
    -*) orch_err "unknown flag: $1"; exit 2 ;;
    *) args+=("$1") ;;
  esac; shift
done
ID="${args[0]:-}"
[ -n "$ID" ] || { orch_err "usage: vendor.sh [--delete] [--execute] [--cpp-dir DIR] <id>"; exit 2; }

QUIVER="$(orch_cfg_get cpp_quiver_path)";             QUIVER="${QUIVER:-quiver}"
DEFAULT_BRANCH="$(orch_cfg_get cpp_default_branch)";  DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
PREFIX="$(orch_cfg_get cpp_pr_branch_prefix)";        PREFIX="${PREFIX:-orchestrator/vendor}"
FORBIDDEN_PATHS="$(orch_cfg_get cpp_forbidden_paths)"
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
SRC_MCP_LOCAL="$(orch_expand "$(orch_cfg_get source_mcp_local)")"

# Resolve the on-disk master directory for $ID. Skills live under source_skills_global; mcp
# capabilities (kind: mcp) live flat under source_mcp_local (the kp-mcp monorepo root). Returns
# empty when nothing resolves — callers that require the master (non-delete) still gate on
# `[ -d "$MASTER" ]` so a missing master fails loud.
resolve_master() {
  local d
  d="$(orch_resolve_skill_master "$SRC_GLOBAL" "$ID" 2>/dev/null || true)"
  [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  if [ -n "$SRC_MCP_LOCAL" ] && [ -d "$SRC_MCP_LOCAL/$ID" ]; then printf '%s\n' "$SRC_MCP_LOCAL/$ID"; return 0; fi
  return 1
}
MASTER="$(resolve_master 2>/dev/null || true)"
[ -n "$MASTER" ] || MASTER="$SRC_GLOBAL/skills/$ID"  # placeholder for delete-mode / "not found" error msg

# Defense-in-depth scope gate (Option A; 2026-06-26): the orchestrator MUST NEVER vendor a
# non-global master into cpp. Skill masters get this for free via the directory paradigm (only
# global/ skills resolve under SRC_GLOBAL); kind:mcp lives flat under SRC_MCP_LOCAL, so the
# manifest's explicit `scope:` is the gate. Delete mode is exempt (the master may be absent).
if [ "$DELETE" != 1 ] && [ -d "$MASTER" ]; then
  MSCOPE="$(awk -F': *' '/^scope:/{print $2; exit}' "$MASTER/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
  if [ -n "$MSCOPE" ] && [ "$MSCOPE" != "global" ]; then
    orch_err "refusing to vendor: master $ID declares scope='$MSCOPE' (only scope:global is vendorable to cpp)"
    exit 1
  fi
fi

TS="$(date +%Y%m%d-%H%M%S)"
BRANCH="$PREFIX/$ID-$TS"; [ "$DELETE" = 1 ] && BRANCH="$PREFIX/rm-$ID-$TS"

# cpp category + kind translations now live in lib/payload.sh (shared with consistency.sh).
# Thin wrappers preserve the legacy call-site names used below.
cpp_category_for_kind() { payload_cpp_category_for_kind "$1"; }
cpp_kind_for_kind()     { payload_cpp_kind_for_kind "$1"; }

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

# Translated cpp-quiver meta + mcp descriptor + VENDORED.md generators live in lib/payload.sh
# (shared with consistency.sh so regen-and-cmp is byte-identical to vendor output).
emit_cpp_meta() {
  local dst="$1" base_meta
  base_meta="$(git -C "$WORK" show "$DEFAULT_BRANCH:$REL/meta.yml" 2>/dev/null || true)"
  payload_emit_cpp_meta "$dst" "$ID" "$MASTER" "$base_meta"
}
emit_mcp_descriptor() { payload_emit_mcp_descriptor "$1" "$ID"; }

build_payload() {
  local dst="$WORK/$REL" mk shape
  # Guard the destructive refresh: $dst must be a safe (deep, absolute) path so a mis-set WORK/REL can
  # never `rm -rf` a top-level dir or $HOME (item-21 hardening; $dst is always $WORK/quiver/<cat>/<id>).
  orch_guard_rmrf "$dst" || { orch_err "build_payload: refusing to rebuild unsafe path '$dst'"; exit 1; }
  rm -rf "$dst"; mkdir -p "$dst"
  mk="$(awk -F': *' '/^kind:/{print $2; exit}' "$MASTER/meta.yml" 2>/dev/null)"
  shape="$(awk -F': *' '/^shape:/{print $2; exit}' "$MASTER/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
  if [ "$mk" = "mcp" ]; then
    # Descriptor mode: NO source tar (mcp masters carry forbidden-ld tokens).
    emit_mcp_descriptor "$dst"
  elif [ "$mk" = "tool" ] && [ "$shape" = "release-descriptor" ]; then
    # Pointer-only SSP (e.g. awa): the release repo/ref/commit are ld-only provenance — descriptor,
    # never source (docs/tool-descriptor-cpp-sync-design.md).
    payload_emit_tool_descriptor "$dst" "$ID"
  elif [ "$mk" = "tool" ] && [ "$shape" = "snapshot" ]; then
    # Snapshot SSP (e.g. operator-voice): the shelf carries real, already zero-link-clean runtime
    # bytes under payload/ — vendor them verbatim (docs/tool-snapshot-cpp-sync-design.md).
    payload_emit_tool_snapshot "$dst" "$ID" "$MASTER"
  else
    ( cd "$MASTER" && payload_shared_list "$MASTER" | tar -cf - -T - ) | ( cd "$dst" && tar -xf - )
  fi
  payload_emit_vendored_md "$dst" "$ID"
  emit_cpp_meta "$dst"
  printf '%s\n' "$dst"
}

cpp_integrity() {
  local rc=0 ran=0
  # RCE guard: when called from an UNATTENDED periodic trigger, never execute cpp's Makefile/integrity
  # engine freshly fetched from origin/main. Skipping yields gate=INDETERMINATE (which never auto-lands).
  if [ "${ORCH_SKIP_CPP_EXEC:-0}" = 1 ]; then orch_warn "cpp integrity SKIPPED (ORCH_SKIP_CPP_EXEC=1); gate = INDETERMINATE"; return 2; fi
  if [ -f "$WORK/Makefile" ] && grep -qE '^(verify|integrity|check):' "$WORK/Makefile" 2>/dev/null; then
    ran=1; ( cd "$WORK" && make verify ) >/tmp/orch-integ.$$ 2>&1 || rc=$?
  elif [ -x "$WORK/_ops/ci/cpp-integrity-engine" ]; then
    ran=1; ( cd "$WORK" && python3 _ops/ci/cpp-integrity-engine check --ci ) >/tmp/orch-integ.$$ 2>&1 || rc=$?
  elif [ -x "$WORK/_ops/bin/cpp-doctor.sh" ]; then
    ran=1; ( cd "$WORK" && bash _ops/bin/cpp-doctor.sh ) >/tmp/orch-integ.$$ 2>&1 || rc=$?
  fi
  if [ "$ran" = 0 ]; then orch_warn "no cpp integrity entrypoint found; gate = INDETERMINATE"; return 2; fi
  [ "$rc" -eq 0 ] && orch_log "cpp integrity: GREEN" || { orch_warn "cpp integrity: RED (rc=$rc)"; sed 's/^/    | /' /tmp/orch-integ.$$ | tail -14 >&2; }
  return "$rc"
}

# --- main flow ------------------------------------------------------------------------------------
prepare_clone
[ "$DELETE" = 1 ] || { [ -d "$MASTER" ] || { orch_err "master not found: $MASTER"; exit 1; }; }
set_cpp_identity

if [ "$DELETE" = 1 ]; then
  REL="$(cd "$WORK" && for d in "$QUIVER"/*/"$ID"; do [ -d "$d" ] && { printf '%s\n' "$d"; break; }; done)"
  [ -n "$REL" ] || { orch_warn "nothing to delete: no $QUIVER/*/$ID in cpp"; exit 0; }
else
  KIND="$(awk -F': *' '/^kind:/{print $2; exit}' "$MASTER/meta.yml" 2>/dev/null)"; KIND="${KIND:-skill}"
  CAT="$(cpp_category_for_kind "$KIND")" || exit 1
  REL="$QUIVER/$CAT/$ID"
fi
git -C "$WORK" checkout -qB "$BRANCH"

if [ "$DELETE" = 1 ]; then
  git -C "$WORK" rm -rq "$REL"
  MSG="chore(quiver): remove vendored $ID (orchestrator delete-propagation)"
  orch_log "staged deletion: $REL"
else
  DST="$(build_payload)"
  if ! orch_zero_link cpp "$DST"; then orch_err "ABORT: payload tripped zero-link (ld tokens in cpp)"; exit 1; fi
  orch_log "zero-link OK (cpp): $REL"
  git -C "$WORK" add "$REL"
  MSG="feat(quiver): vendor $ID (orchestrator sync)"
fi

# idempotent no-op: if nothing staged, the item already matches the base branch.
CHANGED="$(git -C "$WORK" diff --cached --name-only)"
if [ -z "$CHANGED" ]; then
  orch_log "no changes — $ID already in sync on $DEFAULT_BRANCH (no-op)"; exit 0
fi

# control-plane guard: only $REL may be staged; never _ops/ or .github/.
for p in $FORBIDDEN_PATHS; do
  if printf '%s\n' "$CHANGED" | grep -qE "^$p"; then orch_err "ABORT: staged a control-plane path ($p)"; exit 1; fi
done
if printf '%s\n' "$CHANGED" | grep -qvE "^$REL(/|$)"; then
  orch_err "ABORT: staged paths outside $REL:"; printf '%s\n' "$CHANGED" | sed 's/^/    /' >&2; exit 1
fi

git -C "$WORK" commit -q -m "$MSG"
orch_log "committed on $BRANCH: $MSG"

set +e; cpp_integrity; INTEG=$?; set -e
case "$INTEG" in 0) GATE="green" ;; 2) GATE="indeterminate" ;; *) GATE="red" ;; esac

if [ "$EXECUTE" != 1 ]; then
  orch_log "DRY-RUN complete (branch $BRANCH local only; gate=$GATE). Re-run with --execute to open the PR."
  exit 0
fi

# --- EXECUTE: push + governed PR + landing (Decision B) -------------------------------------------
# Routine landing = GitHub NATIVE auto-merge: enable `--auto --squash` and let cpp's OWN server-side
# required checks + the @affirm-cpp-bot CODEOWNER auto-approval gate the merge. No human reviewer is
# required for a quiver-only PR, and the orchestrator NEVER force-merges on the routine path. `--admin`
# (bypass) is BREAK-GLASS only, behind --break-glass-admin / ORCH_VENDOR_BREAKGLASS_ADMIN=1.
if [ "$GATE" = "red" ]; then orch_err "gate RED — refusing to push a failing PR (Deviation-2). Branch kept: $BRANCH"; exit 1; fi
command -v gh >/dev/null 2>&1 || { orch_err "gh not available; cannot open PR"; exit 1; }
git -C "$WORK" push -u origin "$BRANCH" >/dev/null 2>&1 || { orch_err "push failed"; exit 1; }
CPP_REPO="$(orch_cfg_get cpp_repo)"
PR_BODY="Automated by the ecosystem orchestrator (LD-authored, quiver-only). Local cpp-integrity-engine gate: $GATE.
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
