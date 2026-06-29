#!/usr/bin/env bash
# lib/common.sh — shared helpers for the ecosystem orchestrator. Source it; do not execute.
# Dependency-free (flat-YAML config). Reused by bin/orchestrator.sh.

ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"     # .../lib
ORCH_ROOT="$(cd "$ORCH_LIB_DIR/.." && pwd)"                          # repo root
ORCH_CONFIG="$ORCH_ROOT/config/relationship.yml"
ORCH_FORBIDDEN_DIR="$ORCH_ROOT/config"

orch_log()  { printf '[orch] %s\n' "$*" >&2; }
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

# orch_canonical_noreply — the canonical KleinPerkins GitHub noreply (LD authors cpp PRs as this).
# Self-contained (the orchestrator is private + the relationship owner, so ld tokens are allowed here).
orch_canonical_noreply() { printf '%s\n' "49759187+KleinPerkins@users.noreply.github.com"; }

# orch_schema_assert <file> <name/vMAJOR> — assert <file>'s `schema:` declares the expected schema
# name + MAJOR version (P0-3). Forward-compatible by contract: readers IGNORE unknown keys, so only
# the schema name + major are checked here; a minor bump or extra optional fields are tolerated. Used
# for every versioned eco artifact (eco-registry/v1, eco-manifest/v1, eco-lock/v1) so an incompatible
# schema bump fails loud instead of being silently mis-parsed. Returns 0 on match, 1 (+log) otherwise.
orch_schema_assert() {
  local file="$1" want="$2" got name_want maj_want name_got maj_got
  [ -f "$file" ] || { orch_err "schema-assert: file missing: $file"; return 1; }
  got="$(awk -F': *' '/^schema:/{print $2; exit}' "$file" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
  name_want="${want%/*}"; maj_want="${want##*/}"
  name_got="${got%/*}";  maj_got="${got##*/}"
  if [ "$name_got" != "$name_want" ] || [ "$maj_got" != "$maj_want" ]; then
    orch_err "schema mismatch in $file: got '$got', want major-compatible '$want'"
    return 1
  fi
  return 0
}

orch_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
  else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

# orch_guard_rmrf <dir> — return 0 ONLY if <dir> is a safe rm -rf target: a non-empty, absolute path
# with at least two segments, and neither "/" nor $HOME. Callers MUST gate any rm -rf on this so a
# mis-expanded/empty config value can never delete a top-level dir or the whole home.
orch_guard_rmrf() {
  local d="${1:-}"
  case "$d" in
    ""|"/"|"."|"./"|"/.") orch_err "refusing rm -rf on unsafe path '$d'"; return 1 ;;
    /*) : ;;
    *) orch_err "refusing rm -rf on non-absolute path '$d'"; return 1 ;;
  esac
  [ "$d" = "$HOME" ] && { orch_err "refusing rm -rf on \$HOME"; return 1; }
  case "${d#/}" in */*) : ;; *) orch_err "refusing rm -rf on a top-level path '$d'"; return 1 ;; esac
  return 0
}

# orch_backup_outoftree <src-dir> <label> — tar.gz <src> into the configured backup dir. Prints the
# archive path ON SUCCESS ONLY; returns non-zero (printing nothing) if tar fails or the archive can't
# be verified, so a caller can treat a successful backup as a hard precondition before any mutation.
orch_backup_outoftree() {
  local src="$1" label="${2:-backup}" ts dir out rc
  [ -e "$src" ] || { orch_err "backup: source missing: $src"; return 2; }
  ts="$(date +%Y%m%d-%H%M%S)"
  dir="$(orch_expand "$(orch_cfg_get backup_dir)")"; [ -n "$dir" ] || dir="$HOME/.reorg-archives"
  mkdir -p "$dir" || { orch_err "backup: cannot create $dir"; return 2; }
  out="$dir/${label}-${ts}.tar.gz"
  ( cd "$(dirname "$src")" && tar -czf "$out" "$(basename "$src")" ); rc=$?
  if [ "$rc" -ne 0 ]; then orch_err "backup: tar failed (rc=$rc) for $src"; rm -f "$out"; return 1; fi
  if ! tar -tzf "$out" >/dev/null 2>&1 || [ ! -s "$out" ]; then
    orch_err "backup: archive unverifiable (corrupt/empty): $out"; rm -f "$out"; return 1
  fi
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
  # -r (not -R): never follow a symlink (e.g. a dedup symlink into the ld master) out of the payload.
  # -i: case-insensitive so CPP / KleinPerkins / Affirm casing variants can't slip a token past the gate.
  hits="$(grep -rEniI --exclude-dir=.git --exclude-dir=__pycache__ --exclude-dir=.venv \
            --exclude-dir=.pytest_cache --exclude-dir=node_modules "$re" "$scan" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    orch_err "zero-link VIOLATION ($other tokens in a $mode payload):"
    printf '%s\n' "$hits" | sed 's/^/    /' >&2
    return 1
  fi
  return 0
}
