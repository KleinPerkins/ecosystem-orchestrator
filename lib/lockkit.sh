#!/usr/bin/env bash
# lib/lockkit.sh — propagate and verify the shared eco-lock normalizer.
#
# Lockkit is deliberately smaller than vendor/cpp-sync: it never writes cpp and never reuses the
# vendoring engine. Its only authority is config/lockkit.yml plus templates/eco-lock/eco-lock.sh.
set -uo pipefail

LK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
. "$LK_LIB_DIR/common.sh"

LOCKKIT_CONFIG="${LOCKKIT_CONFIG:-$ORCH_ROOT/config/lockkit.yml}"

lk_usage() {
  cat <<'EOF'
usage: orchestrator lockkit <check|write|diff> [target...]
       orchestrator lockkit --allow-dirty write [target...]

Targets are defined in config/lockkit.yml. `write` refuses to touch any dirty
target repo unless --allow-dirty is explicit; `check` and `diff` are read-only.
EOF
}

lk_clean_value() {
  sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//'
}

lk_expand() { orch_expand "$1"; }

lk_config_scalar() {
  local key="$1"
  awk -v k="$key" '
    /^[[:space:]]*#/ { next }
    $0 ~ "^[[:space:]]*" k ":" {
      sub(/^[^:]*:[[:space:]]*/, "")
      sub(/[[:space:]]*#.*$/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }' "$LOCKKIT_CONFIG" | lk_clean_value
}

lk_targets() {
  awk '
    function emit() {
      if (name != "") print name "|" root "|" script "|" lock "|" verify
    }
    function val(line) {
      sub(/^[^:]*:[[:space:]]*/, "", line)
      sub(/[[:space:]]*#.*$/, "", line)
      gsub(/^"|"$/, "", line)
      return line
    }
    /^[[:space:]]*-[[:space:]]*name:/ { emit(); name=val($0); root=script=lock=verify=""; next }
    /^[[:space:]]+root:/   { root=val($0); next }
    /^[[:space:]]+script:/ { script=val($0); next }
    /^[[:space:]]+lock:/   { lock=val($0); next }
    /^[[:space:]]+verify:/ { verify=val($0); next }
    END { emit() }
  ' "$LOCKKIT_CONFIG"
}

lk_selected_targets() {
  if [ "$#" -eq 0 ]; then
    lk_targets
    return
  fi

  local wanted=" $* " found_any=0 line name
  while IFS= read -r line; do
    name="${line%%|*}"
    case "$wanted" in
      *" $name "*) printf '%s\n' "$line"; found_any=1 ;;
    esac
  done < <(lk_targets)

  local target known
  for target in "$@"; do
    known=0
    while IFS= read -r line; do
      [ "${line%%|*}" = "$target" ] && known=1
    done < <(lk_targets)
    [ "$known" = 1 ] || { orch_err "lockkit: unknown target '$target'"; return 2; }
  done
  [ "$found_any" = 1 ] || return 2
}

lk_master() {
  local rel
  rel="$(lk_config_scalar master)"
  [ -n "$rel" ] || { orch_err "lockkit: config missing top-level master"; return 2; }
  printf '%s/%s\n' "$ORCH_ROOT" "$rel"
}

lk_assert_config() {
  [ -f "$LOCKKIT_CONFIG" ] || { orch_err "lockkit: config missing: $LOCKKIT_CONFIG"; return 2; }
  orch_schema_assert "$LOCKKIT_CONFIG" "lockkit/v1" || return 2
}

lk_repo_dirty() {
  local root="$1"
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  [ -n "$(git -C "$root" status --porcelain 2>/dev/null)" ]
}

lk_show_target() {
  local name="$1" root="$2"
  printf '== lockkit:%s (%s) ==\n' "$name" "$root"
}

lk_check_one() {
  local master="$1" name="$2" root="$3" script_rel="$4" lock_rel="$5" verify_rel="${6:-}"
  local root_abs script lock rc=0
  root_abs="$(lk_expand "$root")"
  script="$root_abs/$script_rel"
  lock="$root_abs/$lock_rel"
  lk_show_target "$name" "$root_abs"

  [ -d "$root_abs" ] || { orch_err "lockkit:$name root missing: $root_abs"; return 1; }
  [ -f "$master" ] || { orch_err "lockkit: master missing: $master"; return 1; }
  [ -f "$script" ] || { orch_err "lockkit:$name script missing: $script_rel"; rc=1; }
  [ -f "$lock" ] || { orch_err "lockkit:$name lock missing: $lock_rel"; rc=1; }
  [ -x "$script" ] || { orch_err "lockkit:$name script not executable: $script_rel"; rc=1; }
  if [ "$rc" = 0 ] && ! cmp -s "$master" "$script"; then
    orch_err "lockkit:$name vendored script drifted from master (repair: orchestrator lockkit write $name)"
    rc=1
  fi
  if [ "$rc" = 0 ]; then
    ( cd "$root_abs" && bash "$script_rel" check ) || rc=1
  fi
  if [ "$rc" = 0 ] && [ -n "$verify_rel" ]; then
    if [ -f "$root_abs/$verify_rel" ]; then
      ( cd "$root_abs" && bash "$verify_rel" ) || rc=1
    else
      orch_err "lockkit:$name configured verifier missing: $verify_rel"
      rc=1
    fi
  fi
  return "$rc"
}

lk_diff_one() {
  local master="$1" name="$2" root="$3" script_rel="$4" lock_rel="$5"
  local root_abs script rc=0
  root_abs="$(lk_expand "$root")"
  script="$root_abs/$script_rel"
  lk_show_target "$name" "$root_abs"
  if [ ! -f "$script" ]; then
    orch_err "lockkit:$name script missing: $script_rel"
    return 1
  fi
  if cmp -s "$master" "$script"; then
    printf 'script: OK (matches master)\n'
  else
    printf 'script: DRIFT\n'
    diff -u "$master" "$script" || true
    rc=1
  fi
  if [ -x "$script" ]; then
    ( cd "$root_abs" && bash "$script_rel" check ) || rc=1
  else
    orch_err "lockkit:$name script not executable: $script_rel"
    rc=1
  fi
  [ -f "$root_abs/$lock_rel" ] || rc=1
  return "$rc"
}

lk_write_one() {
  local master="$1" name="$2" root="$3" script_rel="$4" lock_rel="$5"
  local root_abs script
  root_abs="$(lk_expand "$root")"
  script="$root_abs/$script_rel"
  lk_show_target "$name" "$root_abs"
  mkdir -p "$(dirname "$script")"
  cp "$master" "$script" || return 1
  chmod +x "$script" || return 1
  ( cd "$root_abs" && bash "$script_rel" write ) || return 1
  if git -C "$root_abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$root_abs" diff -- "$script_rel" "$lock_rel" || true
  fi
}

lk_check_unique_ids() {
  local selected="$1" seen="" dup=0 line name root script lock verify root_abs id
  while IFS='|' read -r name root script lock verify; do
    [ -n "$name" ] || continue
    root_abs="$(lk_expand "$root")"
    [ -f "$root_abs/$lock" ] || continue
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      case " $seen " in
        *" $id "*) orch_err "lockkit: duplicate id '$id' across targets (ids are globally unique until tuple-key registry support lands)"; dup=1 ;;
        *) seen="$seen $id" ;;
      esac
    done < <(grep -vE '^(schema:|#|[[:space:]]*$)' "$root_abs/$lock" | awk '{print $1}')
  done <<< "$selected"
  [ "$dup" = 0 ]
}

lk_run() {
  local allow_dirty=0
  if [ "${1:-}" = "--allow-dirty" ]; then allow_dirty=1; shift; fi
  local mode="${1:-}"; shift || true
  if [ "${1:-}" = "--allow-dirty" ]; then allow_dirty=1; shift; fi
  case "$mode" in check|write|diff) ;; -h|--help|help|"") lk_usage; return 2 ;; *) orch_err "lockkit: unknown mode '$mode'"; lk_usage; return 2 ;; esac
  lk_assert_config || return $?

  local master line name root script lock verify rc=0
  master="$(lk_master)" || return $?
  [ -f "$master" ] || { orch_err "lockkit: master missing: $master"; return 1; }
  local selected root_abs
  selected="$(lk_selected_targets "$@")" || return $?

  if [ "$mode" = "write" ]; then
    while IFS='|' read -r name root script lock verify; do
      [ -n "$name" ] || continue
      root_abs="$(lk_expand "$root")"
      [ -d "$root_abs" ] || { orch_err "lockkit:$name root missing: $root_abs"; return 1; }
      if lk_repo_dirty "$root_abs" && [ "$allow_dirty" != 1 ]; then
        orch_err "lockkit:$name write refused: target repo has uncommitted changes"
        return 1
      elif lk_repo_dirty "$root_abs"; then
        orch_warn "lockkit:$name writing into a dirty repo because --allow-dirty was explicit"
      fi
    done <<< "$selected"
  fi

  while IFS='|' read -r name root script lock verify; do
    [ -n "$name" ] || continue
    case "$mode" in
      check) lk_check_one "$master" "$name" "$root" "$script" "$lock" "$verify" || rc=1 ;;
      diff)  lk_diff_one  "$master" "$name" "$root" "$script" "$lock" || rc=1 ;;
      write) lk_write_one "$master" "$name" "$root" "$script" "$lock" || rc=1 ;;
    esac
  done <<< "$selected"
  if [ "$mode" = "check" ]; then
    lk_check_unique_ids "$selected" || rc=1
  fi
  return "$rc"
}

lk_run "$@"
