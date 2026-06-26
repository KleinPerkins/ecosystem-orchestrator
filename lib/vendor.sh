#!/usr/bin/env bash
# lib/vendor.sh — orchestrator vendoring engine (reorg-v2 WS-7). The ONLY sanctioned writer of the
# ld->cpp edge. Builds a SELF-SUFFICIENT, ld-agnostic copy of a global capability and lands it in
# cpp/quiver via an LD-authored GOVERNED PR; the delete path propagates a master removal the same way.
#
#   vendor.sh [--delete] [--execute] [--cpp-dir DIR] <id>
#     (default)     DRY-RUN: clone/refresh a work clone, build+stage payload (correct cpp quiver
#                   category + a translated cpp-schema meta.yml), assert zero-link, run cpp's
#                   integrity engine locally, commit on a branch. NO push / NO PR.
#     --execute     additionally push the branch, open the PR, and (GATED on integrity green) land it
#                   via `gh pr merge --admin --squash` (open item #1).
#     --delete      removal mode: git rm the vendored quiver/<cat>/<id> instead of writing it.
#     --cpp-dir DIR use an existing git tree as the cpp clone (tests/fixtures; skips network clone).
#
# SAFETY: never writes cpp control-plane paths (_ops/ .github/) — relies on cpp's WILDCARD
# /quiver/ ownership so a quiver-only add needs no CODEOWNERS/ownership regen; aborts if the staged
# payload trips zero-link (mode cpp); merge is gated on a GREEN local engine verdict, never forced.
set -uo pipefail
VEN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$VEN_LIB_DIR/common.sh"

DELETE=0 EXECUTE=0 CPP_DIR=""
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --delete)  DELETE=1 ;;
    --execute) EXECUTE=1 ;;
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
  local dst="$1" mm="$MASTER/meta.yml" kind owner title today kws
  kind="$(awk -F': *' '/^kind:/{print $2; exit}'  "$mm" 2>/dev/null)";  kind="${kind:-skill}"
  owner="$(awk -F': *' '/^owner:/{print $2; exit}' "$mm" 2>/dev/null)"; owner="${owner:-KleinPerkins}"
  today="$(date +%Y-%m-%d)"
  title="$(awk 'NF && /^# /{sub(/^# /,""); print; exit}' "$dst/SKILL.md" 2>/dev/null)"; title="${title:-$ID}"
  kws="$(printf '%s' "$ID" | tr '-' '\n' | awk 'NF{printf "\"%s\", ", $0}' | sed 's/, $//')"
  cat > "$dst/meta.yml" <<EOF
id: $ID
type: resource
status: stable
scope: team
owner: $owner
title: "$title"
kind: $kind
keywords: [$kws]
source: "vendored by the ecosystem orchestrator (self-sufficient copy)"
created: "$today"
updated: "$today"
EOF
}

build_payload() {
  local dst="$WORK/$REL"
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

# control-plane guard: only $REL may be staged; never _ops/ or .github/.
CHANGED="$(git -C "$WORK" diff --cached --name-only)"
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

# --- EXECUTE: push + governed PR + gated admin-squash merge ---------------------------------------
if [ "$GATE" = "red" ]; then orch_err "gate RED — refusing to push a failing PR (Deviation-2). Branch kept: $BRANCH"; exit 1; fi
command -v gh >/dev/null 2>&1 || { orch_err "gh not available; cannot open PR"; exit 1; }
git -C "$WORK" push -u origin "$BRANCH" >/dev/null 2>&1 || { orch_err "push failed"; exit 1; }
CPP_REPO="$(orch_cfg_get cpp_repo)"
PR_URL="$(gh pr create --repo "$CPP_REPO" --base "$DEFAULT_BRANCH" --head "$BRANCH" \
            --title "$MSG" --body "Automated by the ecosystem orchestrator (LD-authored). Local cpp-integrity-engine gate: $GATE." 2>/dev/null || true)"
[ -n "$PR_URL" ] && orch_log "PR: $PR_URL" || { orch_err "PR create failed"; exit 1; }
if [ "$GATE" = "green" ]; then
  orch_log "gate green -> landing via admin-squash"
  if gh pr merge "$PR_URL" --repo "$CPP_REPO" --admin --squash --delete-branch >/dev/null 2>&1; then orch_log "merged: $PR_URL"
  else orch_warn "admin-squash merge failed; PR left open for operator: $PR_URL"; exit 1; fi
else
  orch_warn "gate=$GATE -> PR left OPEN for operator review: $PR_URL"
fi
