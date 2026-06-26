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
MASTER="$SRC_GLOBAL/$ID"
TS="$(date +%Y%m%d-%H%M%S)"
BRANCH="$PREFIX/$ID-$TS"; [ "$DELETE" = 1 ] && BRANCH="$PREFIX/rm-$ID-$TS"

# cpp quiver categories: skills mcp rules sub-agents tooling workflows. Map a kp kind onto one.
cpp_category_for_kind() {
  case "$1" in
    skill)            printf 'skills\n' ;;
    workflow)         printf 'workflows\n' ;;
    mcp)              printf 'mcp\n' ;;
    sub-agent|subagent) printf 'sub-agents\n' ;;
    rule|doc)         printf 'rules\n' ;;
    asset|data|tool|tooling) printf 'tooling\n' ;;
    *)                printf 'skills\n' ;;
  esac
}

# Map a kp kind onto cpp's CLOSED quiver meta `kind` enum, which is EXACTLY:
#   skill | workflow | asset | mcp | doc | data   (_ops/schemas/meta.schema.json, additionalProperties:false)
# Anything outside this set trips cpp schema validation, so kp kinds with no cpp equivalent are folded
# onto the nearest legal value: rule -> doc (documentation-like); tool/tooling -> asset; sub-agent ->
# asset (cpp has no sub-agent KIND even though it has a sub-agents CATEGORY dir). Without this only
# `skill` would ever vendor green. Keep the legal set in lockstep with cpp's meta.schema.json.
cpp_kind_for_kind() {
  case "$1" in
    skill)              printf 'skill\n' ;;
    workflow)           printf 'workflow\n' ;;
    mcp)                printf 'mcp\n' ;;
    doc)                printf 'doc\n' ;;
    data)               printf 'data\n' ;;
    asset|tool|tooling) printf 'asset\n' ;;
    rule)               printf 'doc\n' ;;
    sub-agent|subagent) printf 'asset\n' ;;
    *)                  printf 'skill\n' ;;
  esac
}

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

# Translate the kp-capability/v1 master meta into cpp's CLOSED quiver meta schema (meta.schema.json).
emit_cpp_meta() {
  local dst="$1" mm="$MASTER/meta.yml" kind cppkind owner title today kws created updated base_meta
  kind="$(awk -F': *' '/^kind:/{print $2; exit}'  "$mm" 2>/dev/null)";  kind="${kind:-skill}"
  cppkind="$(cpp_kind_for_kind "$kind")"
  owner="$(awk -F': *' '/^owner:/{print $2; exit}' "$mm" 2>/dev/null)"; owner="${owner:-KleinPerkins}"
  today="$(date +%Y-%m-%d)"
  title="$(awk 'NF && /^# /{sub(/^# /,""); print; exit}' "$dst/SKILL.md" 2>/dev/null)"; title="${title:-$ID}"
  kws="$(printf '%s' "$ID" | tr '-' '\n' | awk 'NF{printf "\"%s\", ", $0}' | sed 's/, $//')"
  # Idempotent dates (kill per-run churn / preserve provenance):
  #   created — preserve the value already on the cpp base branch (the first-vendored date); else today.
  #   updated — derive from the MASTER capability (its updated, else its created), NEVER `date`, so a
  #             re-vendor of an unchanged master yields a byte-identical meta (no spurious churn PR).
  base_meta="$(git -C "$WORK" show "$DEFAULT_BRANCH:$REL/meta.yml" 2>/dev/null || true)"
  created="$(printf '%s\n' "$base_meta" | awk -F': *' '/^created:/{v=$2; gsub(/"/,"",v); print v; exit}')"
  [ -n "$created" ] || created="$today"
  updated="$(awk -F': *' '/^updated:/{v=$2; gsub(/"/,"",v); print v; exit}' "$mm" 2>/dev/null)"
  [ -n "$updated" ] || updated="$(awk -F': *' '/^created:/{v=$2; gsub(/"/,"",v); print v; exit}' "$mm" 2>/dev/null)"
  [ -n "$updated" ] || updated="$created"
  cat > "$dst/meta.yml" <<EOF
id: $ID
type: resource
status: stable
scope: team
owner: $owner
title: "$title"
kind: $cppkind
keywords: [$kws]
source: "vendored by the ecosystem orchestrator (self-sufficient copy)"
created: "$created"
updated: "$updated"
EOF
}

build_payload() {
  local dst="$WORK/$REL"
  # Guard the destructive refresh: $dst must be a safe (deep, absolute) path so a mis-set WORK/REL can
  # never `rm -rf` a top-level dir or $HOME (item-21 hardening; $dst is always $WORK/quiver/<cat>/<id>).
  orch_guard_rmrf "$dst" || { orch_err "build_payload: refusing to rebuild unsafe path '$dst'"; exit 1; }
  rm -rf "$dst"; mkdir -p "$dst"
  ( cd "$MASTER" && tar --exclude='./meta.yml' --exclude='./install.sh' \
        --exclude='./.git' --exclude='./__pycache__' --exclude='*.pyc' -cf - . ) | ( cd "$dst" && tar -xf - )
  cat > "$dst/VENDORED.md" <<EOF
# Vendored capability: $ID

This directory is a self-sufficient vendored copy managed by the ecosystem orchestrator.
Do not edit it here — changes are overwritten on the next sync. It carries no upstream paths.
EOF
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
  REL="$QUIVER/$(cpp_category_for_kind "$KIND")/$ID"
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
