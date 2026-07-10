#!/usr/bin/env bash
# lib/manifest.sh — orchestrator data-plane MANIFEST writer (WF2/B5). Lands ONE atomic, governed PR
# that regenerates quiver/tooling/eco-capability-sync/eco-capability-manifest.yml (schema
# eco-manifest/v1) — SEPARATE from the per-id payload PRs (vendor.sh) and meant to land AFTER them.
#
#   manifest.sh [--cpp-dir DIR] [--execute] <id> [<id> ...]
#     <id>...      the orchestrator-vendored capability ids to list under `items:` (the cpp-sync
#                  preflight-clean "ok" set). `owned_ids` is derived independently as the union of
#                  active items, marked payloads currently in cpp, prior active/owned ids, and fixed
#                  orchestrator tooling ids. Removed ownership is retained for late downstream prune.
#                  Category/scope/expose are read LIVE from each master meta.yml.
#     (default)    DRY-RUN: prepare a work clone, write the manifest, commit on a branch, run cpp's
#                  integrity engine locally. NO push / NO PR. A byte-identical manifest is a no-op.
#     --execute    additionally push + open the governed PR + enable native auto-merge on green.
#     --cpp-dir    use an existing git tree as the cpp clone (tests/fixtures; skips the network clone).
#
# Same governance as vendor.sh (Decision B): LD-authored, DATA-plane-only PR; never stages _ops/ or
# .github/; lands via cpp's required server checks + @affirm-cpp-bot CODEOWNER approval. No human
# reviewer and no admin bypass on the routine path.
set -uo pipefail
MAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$MAN_LIB_DIR/common.sh"
. "$MAN_LIB_DIR/payload.sh"

EXECUTE=0 CPP_DIR=""; ids=()
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=1 ;;
    --cpp-dir) CPP_DIR="${2:-}"; shift ;;
    -*) orch_err "unknown flag: $1"; exit 2 ;;
    *) ids+=("$1") ;;
  esac; shift
done

QUIVER="$(orch_cfg_get cpp_quiver_path)";            QUIVER="${QUIVER:-quiver}"
DEFAULT_BRANCH="$(orch_cfg_get cpp_default_branch)"; DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
PREFIX="$(orch_cfg_get cpp_pr_branch_prefix)";       PREFIX="${PREFIX:-orchestrator/vendor}"
FORBIDDEN_PATHS="$(orch_cfg_get cpp_forbidden_paths)"
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
SRC_MCP_LOCAL="$(orch_expand "$(orch_cfg_get source_mcp_local)")"
FIXED_OWNED="$(orch_cfg_get cpp_sync_denylist)"; FIXED_OWNED="${FIXED_OWNED:-eco-capability-sync}"
# The manifest lives inside the FIRST owned tooling id's dir (the orchestrator-owned sync shelf).
TOOL_ID="${FIXED_OWNED%% *}"
REL="$QUIVER/tooling/$TOOL_ID/eco-capability-manifest.yml"

resolve_master() {
  local d
  d="$(orch_resolve_skill_master "$SRC_GLOBAL" "$1" 2>/dev/null || true)"
  [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  if [ -n "$SRC_MCP_LOCAL" ] && [ -d "$SRC_MCP_LOCAL/$1" ]; then printf '%s\n' "$SRC_MCP_LOCAL/$1"; return 0; fi
  return 1
}

# Build sorted id:category:scope:expose tuples for every id whose master resolves (skip the rest;
# cpp-sync's preflight already vetted these, this is defense-in-depth).
build_tuples() {
  local id m kind cat scope expose
  for id in "$@"; do
    m="$(resolve_master "$id" || true)"; [ -n "$m" ] || { orch_warn "manifest: skipping $id (no master)"; continue; }
    kind="$(awk -F': *' '/^kind:/{print $2; exit}' "$m/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"; kind="${kind:-skill}"
    cat="$(payload_cpp_category_for_kind "$kind")" || { orch_warn "manifest: skipping $id (kind $kind is not cpp-vendorable)"; continue; }
    scope="$(awk -F': *' '/^scope:/{print $2; exit}' "$m/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"; scope="${scope:-global}"
    expose="$(payload_expose_norm "$m")"
    printf '%s:%s:%s:%s\n' "$id" "$cat" "$scope" "$expose"
  done | LC_ALL=C sort
}

# The manifest separates active delivery (`items`) from prune authorization (`owned_ids`).
# Ownership is intentionally bounded to four sources:
#   1. fixed orchestrator tooling ids;
#   2. this generation's active items;
#   3. current cpp payloads carrying the orchestrator's VENDORED.md marker; and
#   4. the prior manifest's active and owned ids.
#
# Removed ids remain as ownership tombstones because cpp laptop reconcilers have no acknowledgement
# channel and may sync arbitrarily late; expiring them automatically would recreate dangling links.
# The namespace is still bounded: only fixed ids, real marked payloads, and ids this writer previously
# emitted as active/owned can enter it. Repeated generation from the same cpp base is byte-stable.
build_owned_ids() {
  local tuples="$1" existing="$2" d o
  {
    for o in $FIXED_OWNED; do printf '%s\n' "$o"; done
    printf '%s\n' "$tuples" | awk -F: 'NF && $1!="" {print $1}'
    if [ -d "$WORK/$QUIVER" ]; then
      for d in "$WORK/$QUIVER"/*/*; do
        [ -f "$d/VENDORED.md" ] || continue
        basename "$d"
      done
    fi
    # Prior active ids seed migration from manifests written before active ownership was emitted.
    printf '%s\n' "$existing" | awk '
      /^items:[[:space:]]*$/ { in_items=1; next }
      in_items && /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
        v=$0
        sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", v)
        gsub(/[[:space:]]/, "", v)
        if (v != "") print v
      }
    '
    # Prior ownership is monotonic. Without per-laptop acknowledgements this is the only deterministic
    # way to let an arbitrarily late downstream reconcile prune a link after its payload disappeared.
    printf '%s\n' "$existing" | awk '
      /^owned_ids:[[:space:]]*\[/ {
        v=$0
        sub(/^owned_ids:[[:space:]]*\[/, "", v)
        sub(/\].*$/, "", v)
        n=split(v, ids, ",")
        for (i=1; i<=n; i++) {
          gsub(/[[:space:]]/, "", ids[i])
          if (ids[i] != "") print ids[i]
        }
      }
    '
  } | awk '/^[A-Za-z0-9][A-Za-z0-9._-]*$/ && !seen[$0]++' | LC_ALL=C sort
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
}

cpp_integrity() {
  local rc=0 ran=0
  if [ "${ORCH_SKIP_CPP_EXEC:-0}" = 1 ]; then orch_warn "cpp integrity SKIPPED (ORCH_SKIP_CPP_EXEC=1); gate = INDETERMINATE"; return 2; fi
  if [ -f "$WORK/Makefile" ] && grep -qE '^(verify|integrity|check):' "$WORK/Makefile" 2>/dev/null; then
    ran=1; ( cd "$WORK" && make verify ) >/tmp/orch-man-integ.$$ 2>&1 || rc=$?
  elif [ -x "$WORK/_ops/ci/cpp-integrity-engine" ]; then
    ran=1; ( cd "$WORK" && python3 _ops/ci/cpp-integrity-engine check --ci ) >/tmp/orch-man-integ.$$ 2>&1 || rc=$?
  fi
  if [ "$ran" = 0 ]; then orch_warn "no cpp integrity entrypoint found; gate = INDETERMINATE"; return 2; fi
  [ "$rc" -eq 0 ] && orch_log "cpp integrity: GREEN" || { orch_warn "cpp integrity: RED (rc=$rc)"; sed 's/^/    | /' /tmp/orch-man-integ.$$ | tail -14 >&2; }
  rm -f /tmp/orch-man-integ.$$
  return "$rc"
}

# --- main flow ------------------------------------------------------------------------------------
prepare_clone
set_cpp_identity

TUPLES="$(build_tuples "${ids[@]+"${ids[@]}"}")"
TS="$(date +%Y%m%d-%H%M%S)"
BRANCH="$PREFIX/manifest-$TS"
git -C "$WORK" checkout -qB "$BRANCH"

mkdir -p "$(dirname "$WORK/$REL")"
EXISTING=""; [ -f "$WORK/$REL" ] && EXISTING="$(cat "$WORK/$REL")"
OWNED_IDS="$(build_owned_ids "$TUPLES" "$EXISTING" | paste -sd' ' -)"
# shellcheck disable=SC2046
# Intentional word-split of the newline tuple list into positional args.
IFS=$'\n' read -r -d '' -a _tarr < <(printf '%s\0' "$TUPLES")
payload_emit_manifest "$WORK/$REL" "$OWNED_IDS" "$EXISTING" "${_tarr[@]+"${_tarr[@]}"}"

git -C "$WORK" add "$REL"
CHANGED="$(git -C "$WORK" diff --cached --name-only)"
if [ -z "$CHANGED" ]; then
  orch_log "manifest: no changes — already in sync on $DEFAULT_BRANCH (no-op)"; exit 0
fi
# control-plane + scope guard: ONLY the manifest path may be staged.
for p in $FORBIDDEN_PATHS; do
  if printf '%s\n' "$CHANGED" | grep -qE "^$p"; then orch_err "ABORT: staged a control-plane path ($p)"; exit 1; fi
done
if printf '%s\n' "$CHANGED" | grep -qvE "^$REL$"; then
  orch_err "ABORT: staged paths outside the manifest:"; printf '%s\n' "$CHANGED" | sed 's/^/    /' >&2; exit 1
fi

MSG="chore(quiver): regenerate eco-capability-manifest (orchestrator sync)"
git -C "$WORK" commit -q -m "$MSG"
orch_log "committed manifest on $BRANCH: $MSG"

set +e; cpp_integrity; INTEG=$?; set -e
case "$INTEG" in 0) GATE="green" ;; 2) GATE="indeterminate" ;; *) GATE="red" ;; esac

if [ "$EXECUTE" != 1 ]; then
  orch_log "manifest DRY-RUN complete (branch $BRANCH local only; gate=$GATE). Re-run with --execute."
  exit 0
fi

if [ "$GATE" = "red" ]; then orch_err "gate RED — refusing to push a failing manifest PR. Branch kept: $BRANCH"; exit 1; fi
command -v gh >/dev/null 2>&1 || { orch_err "gh not available; cannot open PR"; exit 1; }
git -C "$WORK" push -u origin "$BRANCH" >/dev/null 2>&1 || { orch_err "push failed"; exit 1; }
CPP_REPO="$(orch_cfg_get cpp_repo)"
PR_BODY="Automated by the ecosystem orchestrator (LD-authored, data-plane manifest only). Local cpp-integrity gate: $GATE.
Landing via GitHub native auto-merge — gated by cpp's required checks + @affirm-cpp-bot CODEOWNER approval."
PR_URL="$(gh pr create --repo "$CPP_REPO" --base "$DEFAULT_BRANCH" --head "$BRANCH" \
            --title "$MSG" --body "$PR_BODY" 2>/dev/null || true)"
[ -n "$PR_URL" ] && orch_log "manifest PR: $PR_URL" || { orch_err "PR create failed"; exit 1; }
if [ "$GATE" != "green" ]; then orch_warn "gate=$GATE -> manifest PR left OPEN for review: $PR_URL"; exit 0; fi
if gh pr merge "$PR_URL" --repo "$CPP_REPO" --auto --squash --delete-branch >/dev/null 2>&1; then
  orch_log "manifest auto-merge enabled: $PR_URL"
else
  orch_warn "could not enable auto-merge on manifest PR (repo setting / not yet mergeable). Left OPEN: $PR_URL"; exit 0
fi
