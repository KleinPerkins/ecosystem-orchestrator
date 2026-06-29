#!/usr/bin/env bash
# lib/registry.sh — reader for config/registry.yml (schema eco-registry/v1), the SOLE enrollment SoT
# (B1a). Replaces config/managed-items.txt + its `# excluded:` parsing. Source it; do not execute.
#
# registry.yml is a block-YAML list of minimal records:
#   items:
#     - id: <id>
#       state: enrolled | excluded | demoted
#       reason: "<freeform>"
#       kind: <kind>            # OPTIONAL fallback — used ONLY after the master is gone
#       cpp_category: <cat>     # OPTIONAL fallback — used ONLY after the master is gone
#
# While the master exists, kind/flavor/scope/expose are read LIVE from its meta.yml; the pinned
# kind/cpp_category here are a delete-after-master-gone fallback so the orchestrator can still locate
# and remove a stranded cpp payload. Journal/digest fields are follow-on-plan scope (eco-registry/v1
# ignores unknown keys, so the follow-on can add them without a major bump — see Follow-on plan).
#
# Dependency-free awk parsing (matches the orchestrator's flat-config philosophy). ids + state are
# bare kebab/word tokens (never quoted); reason may be quoted (surrounding quotes stripped on read).
REG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=common.sh
. "$REG_LIB_DIR/common.sh"

reg_file() { printf '%s\n' "${ORCH_REGISTRY:-$ORCH_ROOT/config/registry.yml}"; }

# reg_ids [state] — print every record id, one per line; with [state], only matching records.
reg_ids() {
  local want="${1:-}" f; f="$(reg_file)"; [ -f "$f" ] || return 0
  awk -v want="$want" '
    /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
      if (id != "" && (want=="" || st==want)) print id
      id=$0; sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/, "", id); gsub(/[[:space:]]/,"",id); st=""
      next
    }
    /^[[:space:]]*state:[[:space:]]*/ { st=$0; sub(/^[[:space:]]*state:[[:space:]]*/,"",st); gsub(/[[:space:]]/,"",st) }
    END { if (id != "" && (want=="" || st==want)) print id }
  ' "$f"
}

# reg_field <id> <field> — print a record's field value (surrounding double-quotes stripped). Empty
# when the id or field is absent.
reg_field() {
  local id="$1" field="$2" f; f="$(reg_file)"; [ -f "$f" ] || return 0
  awk -v want="$id" -v fld="$field" '
    /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
      cur=$0; sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/,"",cur); gsub(/[[:space:]]/,"",cur)
      inrec=(cur==want); next
    }
    inrec && $0 ~ ("^[[:space:]]*" fld ":[[:space:]]*") {
      v=$0; sub("^[[:space:]]*" fld ":[[:space:]]*","",v)
      sub(/[[:space:]]*$/,"",v); sub(/^"/,"",v); sub(/"$/,"",v)
      print v; exit
    }
  ' "$f"
}

reg_state()        { reg_field "$1" state; }
reg_reason()       { reg_field "$1" reason; }
reg_kind()         { reg_field "$1" kind; }
reg_cpp_category() { reg_field "$1" cpp_category; }

# reg_has <id> — true if the id has any record (any state).
reg_has() { [ -n "$(reg_state "$1")" ]; }

# reg_assert_schema — fail loud if registry.yml's schema major is incompatible (P0-3).
reg_assert_schema() {
  local f; f="$(reg_file)"; [ -f "$f" ] || { orch_err "registry missing: $f"; return 1; }
  orch_schema_assert "$f" "eco-registry/v1"
}

# reg_set <id> <state> [reason] — upsert a record's state + reason (B1b writer). Replaces the target
# record's state:/reason: in place (preserving any other fields it carries, e.g. pinned kind/
# cpp_category) or appends a new record when the id is unknown. Atomic via a tmpfile rename. The
# `items:` list MUST stay comment-free (records only) for this to be safe — enforced by convention.
reg_set() {
  local id="$1" state="$2" reason="${3:-}" f tmp
  [ -n "$id" ] && [ -n "$state" ] || { orch_err "reg_set: usage: reg_set <id> <state> [reason]"; return 2; }
  case "$state" in enrolled|excluded|demoted) : ;; *) orch_err "reg_set: invalid state '$state' (enrolled|excluded|demoted)"; return 2 ;; esac
  f="$(reg_file)"; [ -f "$f" ] || { orch_err "registry missing: $f"; return 1; }
  tmp="$(mktemp)" || return 1
  awk -v id="$id" -v st="$state" -v rs="$reason" '
    function emit() { print "  - id: " id; print "    state: " st; print "    reason: \"" rs "\"" }
    /^[[:space:]]*-[[:space:]]*id:[[:space:]]*/ {
      cur=$0; sub(/^[[:space:]]*-[[:space:]]*id:[[:space:]]*/,"",cur); gsub(/[[:space:]]/,"",cur)
      if (cur==id) { found=1; inrec=1; emit(); next } else { inrec=0; print; next }
    }
    inrec && /^[[:space:]]*(state|reason):/ { next }   # drop the old state/reason of the target record
    { print }
    END { if (!found) emit() }
  ' "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$f"
}
