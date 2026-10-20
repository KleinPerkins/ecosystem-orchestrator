#!/usr/bin/env bash
# lib/manifest.sh — orchestrator data-plane MANIFEST generator (WF2/B5). Writes and stages
# quiver/tooling/eco-capability-sync/eco-capability-manifest.yml (schema eco-manifest/v1) inside the
# cpp tree that lib/vendor.sh is assembling. It never branches, commits, pushes, or opens a PR: the
# manifest always ships inside vendor.sh's ONE PR together with the payload changes it reflects
# (ADR 0002), so cpp main never lists an active item whose payload is absent.
#
#   manifest.sh --cpp-dir DIR [--keep-existing] [--drop ID]... [ID ...]
#     ID...            ids whose rows are (re)generated from their live master meta.yml.
#     (default)        cpp-sync: `items` is exactly ID... (full regeneration).
#     --keep-existing  per-id: carry every other existing row unchanged; only the named ids change.
#     --drop ID        with --keep-existing: remove ID's row (per-id delete).
#   `owned_ids` is always derived independently (see build_owned_ids). Category/scope/expose are read
#   LIVE from each master meta.yml. A byte-identical result stages nothing.
set -uo pipefail
MAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "$MAN_LIB_DIR/common.sh"
. "$MAN_LIB_DIR/payload.sh"

CPP_DIR="" KEEP_EXISTING=0; ids=(); drops=()
while [ $# -gt 0 ]; do
  case "$1" in
    --cpp-dir) CPP_DIR="${2:-}"; shift ;;
    --keep-existing) KEEP_EXISTING=1 ;;
    --drop) drops+=("${2:-}"); shift ;;
    -*) orch_err "unknown flag: $1"; exit 2 ;;
    *) ids+=("$1") ;;
  esac; shift
done
[ -n "$CPP_DIR" ] && [ -d "$CPP_DIR/.git" ] || {
  orch_err "usage: manifest.sh --cpp-dir DIR [--keep-existing] [--drop ID]... [ID ...] (DIR: the cpp tree vendor.sh is assembling)"
  exit 2
}
WORK="$CPP_DIR"

QUIVER="$(orch_cfg_get cpp_quiver_path)";            QUIVER="${QUIVER:-quiver}"
SRC_GLOBAL="$(orch_expand "$(orch_cfg_get source_skills_global)")"
SRC_MCP_LOCAL="$(orch_expand "$(orch_cfg_get source_mcp_local)")"
FIXED_OWNED="$(orch_cfg_get cpp_sync_denylist)"; FIXED_OWNED="${FIXED_OWNED:-eco-capability-sync}"
REL="$(orch_manifest_rel)"

resolve_master() {
  local d
  d="$(orch_resolve_skill_master "$SRC_GLOBAL" "$1" 2>/dev/null || true)"
  [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  if [ -n "$SRC_MCP_LOCAL" ] && [ -d "$SRC_MCP_LOCAL/$1" ]; then printf '%s\n' "$SRC_MCP_LOCAL/$1"; return 0; fi
  return 1
}

# Build id:category:scope:expose tuples for every id whose master resolves (skip the rest; vendor.sh
# already refused any id it could not build, this is defense-in-depth).
build_tuples() {
  local id m kind cat scope expose
  for id in "$@"; do
    m="$(resolve_master "$id" || true)"; [ -n "$m" ] || { orch_warn "manifest: skipping $id (no master)"; continue; }
    kind="$(awk -F': *' '/^kind:/{print $2; exit}' "$m/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"; kind="${kind:-skill}"
    cat="$(payload_cpp_category_for_kind "$kind")" || { orch_warn "manifest: skipping $id (kind $kind is not cpp-vendorable)"; continue; }
    scope="$(awk -F': *' '/^scope:/{print $2; exit}' "$m/meta.yml" 2>/dev/null | tr -d '"' | tr -d "'" | tr -d '[:space:]')"; scope="${scope:-global}"
    expose="$(payload_expose_norm "$m")"
    printf '%s:%s:%s:%s\n' "$id" "$cat" "$scope" "$expose"
  done
}

# existing_tuples <manifest_text> — the prior manifest's item rows as id:category:scope:expose tuples,
# in the exact shape payload_emit_manifest re-renders byte-for-byte.
existing_tuples() {
  printf '%s\n' "$1" | awk '
    function flush() { if (id != "") printf "%s:%s:%s:%s\n", id, cat, scope, expose; id="" }
    function val(line, key) { sub("^[[:space:]]*" key ":[[:space:]]*", "", line); gsub(/[[:space:]]/, "", line); return line }
    /^items:[[:space:]]*$/ { in_items=1; next }
    !in_items { next }
    /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ { flush(); v=$0; sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", v); gsub(/[[:space:]]/, "", v); id=v; cat=scope=expose=""; next }
    /^[[:space:]]*category:/ { cat=val($0, "category"); next }
    /^[[:space:]]*scope:/    { scope=val($0, "scope"); next }
    /^[[:space:]]*expose:/ {
      v=$0; sub(/^[[:space:]]*expose:[[:space:]]*\[/, "", v); sub(/\].*$/, "", v)
      gsub(/,/, " ", v); gsub(/[[:space:]]+/, " ", v); sub(/^ /, "", v); sub(/ $/, "", v); expose=v; next
    }
    END { flush() }
  '
}

# The manifest separates active delivery (`items`) from prune authorization (`owned_ids`).
# Ownership is intentionally bounded to four sources:
#   1. fixed orchestrator tooling ids;
#   2. this generation's active items;
#   3. cpp payloads carrying the orchestrator's VENDORED.md marker — in the working tree OR on the base
#      commit, so a payload removed in this same change keeps its tombstone; and
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
    git -C "$WORK" ls-tree -r --name-only HEAD -- "$QUIVER" 2>/dev/null | awk -v q="$QUIVER/" '
      index($0, q) == 1 { n=split(substr($0, length(q) + 1), p, "/"); if (n == 3 && p[3] == "VENDORED.md") print p[2] }
    '
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

# --- main flow ------------------------------------------------------------------------------------
mkdir -p "$(dirname "$WORK/$REL")"
EXISTING=""; [ -f "$WORK/$REL" ] && EXISTING="$(cat "$WORK/$REL")"

TUPLES="$(build_tuples ${ids[@]+"${ids[@]}"})"
if [ "$KEEP_EXISTING" = 1 ]; then
  named=" ${ids[*]+${ids[*]}} ${drops[*]+${drops[*]}} "
  KEPT="$(existing_tuples "$EXISTING" | awk -F: -v named="$named" 'NF && index(named, " " $1 " ") == 0')"
  TUPLES="$(printf '%s\n%s\n' "$KEPT" "$TUPLES")"
fi
TUPLES="$(printf '%s\n' "$TUPLES" | awk 'NF' | LC_ALL=C sort)"

OWNED_IDS="$(build_owned_ids "$TUPLES" "$EXISTING" | paste -sd' ' -)"
# Intentional word-split of the newline tuple list into positional args.
IFS=$'\n' read -r -d '' -a _tarr < <(printf '%s\0' "$TUPLES")
payload_emit_manifest "$WORK/$REL" "$OWNED_IDS" "$EXISTING" "${_tarr[@]+"${_tarr[@]}"}"
git -C "$WORK" add "$REL"
