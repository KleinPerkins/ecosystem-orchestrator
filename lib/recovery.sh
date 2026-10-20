#!/usr/bin/env bash
# lib/recovery.sh — governed recovery verbs for orchestrator-managed cpp payloads.
set -uo pipefail
REC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$REC_LIB_DIR/common.sh"
. "$REC_LIB_DIR/registry.sh"

SUB="${1:-}"; shift || true

QUIVER="$(orch_cfg_get cpp_quiver_path)";             QUIVER="${QUIVER:-quiver}"
DEFAULT_BRANCH="$(orch_cfg_get cpp_default_branch)";  DEFAULT_BRANCH="${DEFAULT_BRANCH:-main}"
PREFIX="$(orch_cfg_get cpp_pr_branch_prefix)";        PREFIX="${PREFIX:-orchestrator/vendor}"
FORBIDDEN_PATHS="$(orch_cfg_get cpp_forbidden_paths)"

EXECUTE=0
DRY_RUN=0
CPP_DIR=""

set_cpp_identity() {
  local email name="KleinPerkins" people="$WORK/_ops/facts/people.yml"
  email="$(orch_canonical_noreply)"
  if [ -f "$people" ]; then
    local found; found="$(awk '
      /KleinPerkins/ {h=1}
      h && /email:/ {gsub(/.*email:[[:space:]]*/,""); gsub(/["'\''[:space:]]/,""); print; exit}' "$people" 2>/dev/null || true)"
    [ -n "$found" ] && email="$found"
  fi
  git -C "$WORK" config user.name "$name"
  git -C "$WORK" config user.email "$email"
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

cpp_integrity() {
  local rc=0 ran=0
  if [ "${ORCH_SKIP_CPP_EXEC:-0}" = 1 ]; then orch_warn "cpp integrity SKIPPED (ORCH_SKIP_CPP_EXEC=1); gate = INDETERMINATE"; return 2; fi
  if [ -f "$WORK/Makefile" ] && grep -qE '^(verify|integrity|check):' "$WORK/Makefile" 2>/dev/null; then
    ran=1; ( cd "$WORK" && make verify ) >/tmp/orch-rec-integ.$$ 2>&1 || rc=$?
  elif [ -x "$WORK/_ops/ci/cpp-integrity-engine" ]; then
    ran=1; ( cd "$WORK" && python3 _ops/ci/cpp-integrity-engine check --ci ) >/tmp/orch-rec-integ.$$ 2>&1 || rc=$?
  fi
  if [ "$ran" = 0 ]; then orch_warn "no cpp integrity entrypoint found; gate = INDETERMINATE"; return 2; fi
  # rc 2 means "could not run" (INDETERMINATE) only when returned above; a failing check is always
  # RED, even when the tool itself exits 2 (make does).
  if [ "$rc" -eq 0 ]; then orch_log "cpp integrity: GREEN"
  else orch_warn "cpp integrity: RED (rc=$rc)"; sed 's/^/    | /' /tmp/orch-rec-integ.$$ | tail -14 >&2; rc=1; fi
  rm -f /tmp/orch-rec-integ.$$
  return "$rc"
}

rel_at_sha() {
  local sha="$1" id="$2"
  git -C "$WORK" ls-tree -r --name-only "$sha" -- "$QUIVER" 2>/dev/null \
    | awk -F/ -v id="$id" '$NF=="VENDORED.md" && $(NF-1)==id {sub(/\/VENDORED\.md$/,""); print; exit}'
}

cmd_rollback() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --execute) EXECUTE=1 ;;
      --cpp-dir) CPP_DIR="${2:-}"; shift ;;
      -*) orch_err "rollback: unknown flag: $1"; return 2 ;;
      *) break ;;
    esac
    shift
  done
  local id="${1:-}" sha rel ts branch msg changed integ gate repo body pr_url
  [ -n "$id" ] || { orch_err "usage: orchestrator rollback [--execute] [--cpp-dir DIR] <id>"; return 2; }
  reg_assert_schema || return 1
  sha="$(reg_journal_get "$id" last_synced_cpp_sha)"
  if [ -z "$sha" ]; then
    local raw; raw="$(reg_journal_raw "$id" last_synced_cpp_sha)"
    [ -n "$raw" ] && orch_err "rollback: malformed last_synced_cpp_sha for $id: $raw" \
      || orch_err "rollback: no trusted last_synced_cpp_sha for $id (run 'orchestrator repair' and inspect 'status --matrix')"
    return 1
  fi
  prepare_clone
  set_cpp_identity
  git -C "$WORK" cat-file -e "$sha^{commit}" 2>/dev/null || { orch_err "rollback: cpp sha not present in clone: $sha"; return 1; }
  rel="$(rel_at_sha "$sha" "$id")"
  [ -n "$rel" ] || { orch_err "rollback: $sha does not contain quiver/*/$id/VENDORED.md"; return 1; }
  ts="$(date +%Y%m%d-%H%M%S)"
  branch="$PREFIX/rollback-$id-$ts"
  git -C "$WORK" checkout -qB "$branch"
  orch_guard_rmrf "$WORK/$rel" || { orch_err "rollback: unsafe payload path: $WORK/$rel"; return 1; }
  rm -rf "$WORK/$rel"
  mkdir -p "$WORK/$rel"
  git -C "$WORK" archive "$sha" "$rel" | tar -x -C "$WORK"
  [ -f "$WORK/$rel/VENDORED.md" ] || { orch_err "rollback: restored payload missing VENDORED.md"; return 1; }
  orch_zero_link cpp "$WORK/$rel" || { orch_err "rollback: restored payload failed zero-link"; return 1; }
  git -C "$WORK" add "$rel"
  changed="$(git -C "$WORK" diff --cached --name-only)"
  [ -n "$changed" ] || { orch_log "rollback: no changes — $id already matches $sha"; return 0; }
  for p in $FORBIDDEN_PATHS; do
    if printf '%s\n' "$changed" | grep -qE "^$p"; then orch_err "ABORT: staged a control-plane path ($p)"; return 1; fi
  done
  if printf '%s\n' "$changed" | grep -qvE "^$rel(/|$)"; then
    orch_err "ABORT: rollback staged paths outside $rel:"; printf '%s\n' "$changed" | sed 's/^/    /' >&2; return 1
  fi
  msg="revert(quiver): rollback $id to ${sha:0:12} (orchestrator recovery)"
  git -C "$WORK" commit -q -m "$msg"
  set +e; cpp_integrity; integ=$?; set -e
  case "$integ" in 0) gate=green ;; 2) gate=indeterminate ;; *) gate=red ;; esac
  if [ "$EXECUTE" != 1 ]; then
    orch_log "rollback DRY-RUN complete (branch $branch local only; gate=$gate). Re-run with --execute to open the PR."
    return 0
  fi
  [ "$gate" = "red" ] && { orch_err "gate RED — refusing to push rollback PR. Branch kept: $branch"; return 1; }
  command -v gh >/dev/null 2>&1 || { orch_err "gh not available; cannot open rollback PR"; return 1; }
  repo="$(orch_cfg_get cpp_repo)"
  orch_refuse_if_orchestrator_pr_open "$repo" "$PREFIX" || { orch_err "rollback branch kept locally: $branch"; return 1; }
  git -C "$WORK" push -u origin "$branch" >/dev/null 2>&1 || { orch_err "push failed"; return 1; }
  body="Automated rollback by the ecosystem orchestrator. Restores $rel from trusted cpp sha $sha. Local cpp-integrity gate: $gate."
  pr_url="$(gh pr create --repo "$repo" --base "$DEFAULT_BRANCH" --head "$branch" --title "$msg" --body "$body" 2>/dev/null || true)"
  [ -n "$pr_url" ] || { orch_err "rollback PR create failed"; return 1; }
  orch_log "rollback PR: $pr_url"
  if [ "$gate" = "green" ]; then
    gh pr merge "$pr_url" --repo "$repo" --auto --squash --delete-branch >/dev/null 2>&1 \
      && orch_log "rollback auto-merge enabled: $pr_url" \
      || orch_warn "could not enable auto-merge for rollback PR; left open: $pr_url"
  else
    orch_warn "gate=$gate -> rollback PR left OPEN for operator review: $pr_url"
  fi
}

# Every orchestrator PR rewrites the shared capability manifest and vendor.sh --execute refuses while
# one is open (ADR 0002), so quarantine stops the line: it closes EVERY in-flight orchestrator PR (a
# combined PR may carry the quarantined id alongside others), then ships the removal as the only PR.
# Closed PRs lose nothing: their branches are regenerated by the next `cpp-sync --execute`.
close_inflight_prs() {
  local id="$1" reason="$2" repo refs ref num
  [ "${ORCH_SKIP_GH_PR_CLOSE:-0}" = 1 ] && { orch_warn "quarantine: ORCH_SKIP_GH_PR_CLOSE=1; skipping PR close step"; return 0; }
  command -v gh >/dev/null 2>&1 || { orch_warn "quarantine: gh unavailable; skipping PR close step"; return 0; }
  gh auth status >/dev/null 2>&1 || { orch_warn "quarantine: gh unauthenticated; skipping PR close step"; return 0; }
  repo="$(orch_cfg_get cpp_repo)"
  refs="$(gh pr list --repo "$repo" --state open --limit 200 --json number,headRefName --jq '.[] | [.number, .headRefName] | @tsv' 2>/dev/null || true)"
  while IFS=$'\t' read -r num ref; do
    [ -n "$num" ] || continue
    case "$ref" in
      "$PREFIX"/*)
        gh pr close "$num" --repo "$repo" --comment "Closed by orchestrator quarantine for $id: $reason. Orchestrator PRs share the capability manifest, so only one may be in flight; the next orchestrator sync re-delivers anything else this PR carried." >/dev/null 2>&1 \
          && orch_log "quarantine: closed in-flight orchestrator PR #$num ($ref)" || orch_warn "quarantine: failed to close PR #$num ($ref)"
        ;;
    esac
  done <<< "$refs"
}

cmd_quarantine() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --cpp-dir) CPP_DIR="${2:-}"; shift ;;
      -*) break ;;
      *) break ;;
    esac
    shift
  done
  local id="${1:-}"; shift || true
  [ "${1:-}" = "--" ] && shift || true
  local reason="$*"
  [ -n "$id" ] && [ -n "$reason" ] || { orch_err "usage: orchestrator quarantine [--dry-run] [--cpp-dir DIR] <id> -- <reason>"; return 2; }
  reg_assert_schema || return 1
  close_inflight_prs "$id" "$reason" || return 1
  reg_set "$id" excluded "quarantine: $reason" || return 1
  # One PR: the payload removal and the manifest row removal land together (vendor.sh --delete).
  if [ "$DRY_RUN" = 1 ]; then
    orch_log "quarantine DRY-RUN: would remove $id's payload and its manifest row in one PR"
    if [ -n "$CPP_DIR" ]; then
      bash "$ORCH_ROOT/lib/vendor.sh" --delete --cpp-dir "$CPP_DIR" "$id" || return 1
    fi
    return 0
  fi
  local v_args=()
  [ -n "$CPP_DIR" ] && v_args+=(--cpp-dir "$CPP_DIR")
  bash "$ORCH_ROOT/lib/vendor.sh" --delete --execute ${v_args[@]+"${v_args[@]}"} "$id" || return 1
  orch_log "quarantine complete for $id; once its PR merges, run 'orchestrator cpp-sync --execute' to re-deliver anything a closed PR carried, then inspect 'orchestrator status --matrix'"
}

case "$SUB" in
  rollback)   cmd_rollback "$@" ;;
  quarantine) cmd_quarantine "$@" ;;
  *) orch_err "recovery: unknown subcommand '$SUB' (rollback|quarantine)"; exit 2 ;;
esac
