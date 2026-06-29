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
# and remove a stranded cpp payload.
#
# Optional journal fields are machine-edited cache/state, not enrollment authority:
#   content_digest        64 lowercase hex digest last observed by approve/status/repair
#   approved_digest       64 lowercase hex digest approved for flavor-2 sync
#   last_synced_cpp_sha   hex-ish cpp main commit containing the payload
#   last_synced_at        UTC ISO-8601 timestamp when last_synced_cpp_sha was refreshed
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

reg_journal_raw() { reg_field "$1" "$2"; }

reg_journal_field_valid() {
  local field="$1" value="$2"
  [ -n "$value" ] || return 1
  case "$field" in
    content_digest|approved_digest) [[ "$value" =~ ^[0-9a-f]{64}$ ]] ;;
    last_synced_cpp_sha)            [[ "$value" =~ ^[0-9a-f]{7,40}$ ]] ;;
    last_synced_at)                 [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ;;
    *)                              orch_err "unknown registry journal field: $field"; return 2 ;;
  esac
}

reg_journal_get() {
  local id="$1" field="$2" value
  value="$(reg_journal_raw "$id" "$field")"
  reg_journal_field_valid "$field" "$value" >/dev/null 2>&1 && printf '%s\n' "$value"
}

reg_journal_invalid_fields() {
  local id="$1" field value
  for field in content_digest approved_digest last_synced_cpp_sha last_synced_at; do
    value="$(reg_journal_raw "$id" "$field")"
    [ -n "$value" ] || continue
    if ! reg_journal_field_valid "$field" "$value" >/dev/null 2>&1; then
      printf '%s=%s\n' "$field" "$value"
    fi
  done
}

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

_reg_journal_write() {
  local mode="$1" id="$2" field="$3" value="${4:-}" f tmp
  [ -n "$id" ] && [ -n "$field" ] || { orch_err "reg_journal_$mode: usage: <id> <field> [value]"; return 2; }
  case "$field" in content_digest|approved_digest|last_synced_cpp_sha|last_synced_at) : ;; *) orch_err "invalid journal field: $field"; return 2 ;; esac
  if [ "$mode" = "set" ] && ! reg_journal_field_valid "$field" "$value"; then
    orch_err "invalid $field value: $value"; return 2
  fi
  reg_has "$id" || { orch_err "registry id not found: $id"; return 1; }
  f="$(reg_file)"; tmp="$(mktemp)" || return 1
  REG_FILE="$f" REG_ID="$id" REG_FIELD="$field" REG_VALUE="$value" REG_MODE="$mode" python3 - <<'PY' > "$tmp" || { rm -f "$tmp"; return 1; }
import os, re, sys

path = os.environ["REG_FILE"]
want = os.environ["REG_ID"]
field = os.environ["REG_FIELD"]
value = os.environ["REG_VALUE"]
mode = os.environ["REG_MODE"]

lines = open(path).read().splitlines()
starts = []
for i, line in enumerate(lines):
    m = re.match(r"^(\s*)-\s*id:\s*([^#\s]+)\s*$", line)
    if m:
        starts.append((i, m.group(2)))

target = None
for pos, (start, rec_id) in enumerate(starts):
    if rec_id == want:
        end = starts[pos + 1][0] if pos + 1 < len(starts) else len(lines)
        target = (start, end)
        break

if target is None:
    sys.exit(3)

start, end = target
out = []
done = False
for i, line in enumerate(lines):
    if start < i < end and re.match(r"^\s*" + re.escape(field) + r":\s*", line):
        if mode == "set":
            out.append(f'    {field}: "{value}"')
        done = True
        continue
    if i == end and mode == "set" and not done:
        out.append(f'    {field}: "{value}"')
        done = True
    out.append(line)

if end == len(lines) and mode == "set" and not done:
    out.append(f'    {field}: "{value}"')

print("\n".join(out) + "\n", end="")
PY
  mv "$tmp" "$f"
}

reg_journal_set()   { _reg_journal_write set "$@"; }
reg_journal_clear() { _reg_journal_write clear "$@"; }
