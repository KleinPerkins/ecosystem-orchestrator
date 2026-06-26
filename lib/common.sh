#!/usr/bin/env bash
# lib/common.sh — shared helpers for the ecosystem orchestrator. Source it; do not execute.
# Dependency-free (flat-YAML config). Reused by bin/orchestrator.sh.

ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"     # .../lib
ORCH_ROOT="$(cd "$ORCH_LIB_DIR/.." && pwd)"                          # repo root
ORCH_CONFIG="$ORCH_ROOT/config/relationship.yml"
ORCH_FORBIDDEN_DIR="$ORCH_ROOT/config"

orch_log()  { printf '[orch] %s\n' "$*"; }
orch_warn() { printf '[orch] WARN %s\n' "$*" >&2; }
orch_err()  { printf '[orch] ERROR %s\n' "$*" >&2; }

# orch_expand <path> — expand a leading ~ to $HOME.
orch_expand() { case "$1" in "~/"*) printf '%s\n' "$HOME/${1#"~/"}" ;; "~") printf '%s\n' "$HOME" ;; *) printf '%s\n' "$1" ;; esac; }

# orch_cfg_get <key> — read a flat "key: value" from relationship.yml (strips quotes/comments).
orch_cfg_get() {
  awk -v k="$1" '
    /^[[:space:]]*#/ { next }
    { line=$0; sub(/[[:space:]]*#.*$/, "", line)
      if (match(line, /^[A-Za-z0-9_]+:[[:space:]]*/)) {
        key=line; sub(/:.*$/, "", key)
        if (key==k) { val=line; sub(/^[A-Za-z0-9_]+:[[:space:]]*/, "", val); gsub(/^"|"$/, "", val); print val; exit }
      } }' "$ORCH_CONFIG"
}

orch_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

# orch_backup_outoftree <src-dir> <label> — tar.gz <src> into the configured backup dir; prints path.
orch_backup_outoftree() {
  local src="$1" label="${2:-backup}" ts dir
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$(orch_expand "$(orch_cfg_get backup_dir)")"; [ -n "$dir" ] || dir="$HOME/.reorg-archives"
  mkdir -p "$dir"
  local out="$dir/${label}-${ts}.tar.gz"
  ( cd "$(dirname "$src")" && tar -czf "$out" "$(basename "$src")" )
  printf '%s\n' "$out"
}

# orch_zero_link <mode:global|cpp> <path> — assert payload contains zero tokens of the OTHER side.
# Reads ERE fragments from config/forbidden-<other>.txt. Exit 0 clean, 1 violation.
orch_zero_link() {
  local mode="$1" scan="$2" tokfile other
  case "$mode" in
    global) tokfile="$ORCH_FORBIDDEN_DIR/forbidden-cpp.txt"; other="cpp" ;;
    cpp)    tokfile="$ORCH_FORBIDDEN_DIR/forbidden-ld.txt";  other="ld"  ;;
    *) orch_err "zero-link mode must be global|cpp"; return 2 ;;
  esac
  [ -f "$tokfile" ] || { orch_err "missing token file $tokfile"; return 2; }
  [ -e "$scan" ] || { orch_err "path not found: $scan"; return 2; }
  local re; re="$(grep -vE '^[[:space:]]*(#|$)' "$tokfile" | paste -sd '|' -)"
  [ -n "$re" ] || { orch_err "no tokens in $tokfile"; return 2; }
  local hits
  hits="$(grep -REnI --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=.venv \
            --exclude-dir=.pytest_cache --exclude-dir=node_modules "$re" "$scan" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    orch_err "zero-link VIOLATION ($other tokens in a $mode payload):"
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    return 1
  fi
  return 0
}
