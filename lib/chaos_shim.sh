#!/usr/bin/env bash
# lib/chaos_shim.sh — orchestrator-owned google-kit shim delivery for chaos-labs.
#
# DRY-RUN by default. --execute writes only the configured shim/env files in the configured
# chaos-labs target; it never copies personal doc-style profile bytes.
set -uo pipefail
CS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$CS_LIB_DIR/common.sh"

EXECUTE=0
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --execute) EXECUTE=1 ;;
    --target) TARGET="${2:-}"; shift ;;
    -*) orch_err "chaos-shim-sync: unknown flag: $1"; exit 2 ;;
    *) orch_err "chaos-shim-sync: unexpected arg: $1"; exit 2 ;;
  esac
  shift
done

target_root="$(orch_expand "${TARGET:-$(orch_cfg_get chaos_labs_root)}")"
shim_rel="$(orch_cfg_get chaos_labs_shim_path)"
env_rel="$(orch_cfg_get chaos_labs_env_path)"
shim_rel="${shim_rel:-scripts/setup/google-kit-shim.sh}"
env_rel="${env_rel:-config/google-kit.env.example}"

[ -n "$target_root" ] || { orch_err "chaos-shim-sync: chaos_labs_root is not configured"; exit 2; }

emit_shim() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

config_dir="${GOOGLE_KIT_CONFIG_DIR:-$HOME/Library/Application Support/google-kit}"
export GOOGLE_KIT_CONFIG_DIR="$config_dir"
styles_dir="$GOOGLE_KIT_CONFIG_DIR/doc-styles"
mkdir -p "$styles_dir"

if [ -n "${GOOGLE_KIT_DOC_STYLES_SEED_DIR:-}" ] && [ -d "$GOOGLE_KIT_DOC_STYLES_SEED_DIR" ]; then
  for src in "$GOOGLE_KIT_DOC_STYLES_SEED_DIR"/*.json; do
    [ -f "$src" ] || continue
    dst="$styles_dir/$(basename "$src")"
    if [ ! -f "$dst" ]; then
      cp "$src" "$dst"
      chmod 600 "$dst" 2>/dev/null || true
    fi
  done
fi

if command -v google-kit >/dev/null 2>&1; then
  google-kit bootstrap || true
fi

printf 'GOOGLE_KIT_CONFIG_DIR=%s\n' "$GOOGLE_KIT_CONFIG_DIR"
EOF
}

emit_env() {
  cat <<'EOF'
# Source this from local scripts that need google-kit.
# Keep real profile JSON in the user-level google-kit config dir, not in this repository.
export GOOGLE_KIT_CONFIG_DIR="${GOOGLE_KIT_CONFIG_DIR:-$HOME/Library/Application Support/google-kit}"
# Optional private seed directory, managed outside this repository:
# export GOOGLE_KIT_DOC_STYLES_SEED_DIR="$HOME/.config/google-kit-doc-styles-seed"
EOF
}

if [ "$EXECUTE" != 1 ]; then
  orch_log "chaos-shim-sync DRY-RUN: would write $target_root/$shim_rel and $target_root/$env_rel"
  exit 0
fi

[ -d "$target_root" ] || { orch_err "chaos-shim-sync: target root missing: $target_root"; exit 1; }
mkdir -p "$target_root/$(dirname "$shim_rel")" "$target_root/$(dirname "$env_rel")" || exit 1
emit_shim > "$target_root/$shim_rel" || exit 1
chmod +x "$target_root/$shim_rel" || exit 1
emit_env > "$target_root/$env_rel" || exit 1
orch_log "chaos-shim-sync wrote $shim_rel and $env_rel"
