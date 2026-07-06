#!/usr/bin/env bash
# tests/test_tool_descriptor_payload.sh — hermetic fixture for payload_emit_tool_descriptor
# (DESIGN-ONLY, AWA dual-goal v2 Part 4; see docs/tool-descriptor-cpp-sync-design.md). Mirrors
# tests/test_google_kit_payload.sh's shape for the mcp-parity triad, but for kind:tool.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

. "$ROOT/lib/payload.sh"

MASTER="$TMP/master"
mkdir -p "$MASTER"
cat > "$MASTER/meta.yml" <<'EOF'
schema: kp-capability/v1
id: awa
kind: tool
flavor: 2
scope: global
owner: KleinPerkins
install: install.sh
post_mgmt: none
shape: release-descriptor
sync_policy: record-only
expose: cursor claude codex
provenance_source: "github.com/KleinPerkins/awa"
provenance_ref: "11e962ff1e9227579eb711d2732c4dd12280fc2a"
provenance_trust: "vetted"
EOF
cat > "$MASTER/tool.yml" <<'EOF'
schema: kp-tool/v1
id: awa
name: Agent Worktree Automation (release pointer)
scope: global
shape: release-descriptor
sync_policy: record-only
entrypoint: install.sh
description: >-
  Source-tracked pointer/descriptor to the pinned KleinPerkins/awa engine release.
release:
  repo: github.com/KleinPerkins/awa
  ref: v1.0.1
  commit: 11e962ff1e9227579eb711d2732c4dd12280fc2a
EOF

DST="$TMP/dst"
mkdir -p "$DST"
payload_emit_tool_descriptor "$DST" awa
payload_emit_vendored_md     "$DST" awa
payload_emit_cpp_meta        "$DST" awa "$MASTER" ""

for f in README.md VENDORED.md meta.yml; do
  [ -f "$DST/$f" ] || { echo "missing tool descriptor payload file: $f"; exit 1; }
done

# The triad matches the mcp descriptor exactly (3 files) — no separate translated tool.yml.
extra="$(find "$DST" -type f ! -name README.md ! -name VENDORED.md ! -name meta.yml)"
[ -z "$extra" ] || { echo "tool descriptor payload emitted unexpected extra files:"; printf '%s\n' "$extra"; exit 1; }

grep -q '^kind: tool$' "$DST/meta.yml" || { echo "translated meta.yml did not map kind:tool -> tool"; exit 1; }

# Zero-link: no ld tokens (repo path, ref, commit, host paths, noreply email) anywhere in the payload
# — the master's meta.yml/tool.yml above deliberately carry the exact tokens forbidden-ld.txt bans,
# proving payload_emit_tool_descriptor cannot leak them by construction (it reads no master fields).
ld_re='KleinPerkins/[A-Za-z0-9_.-]+|kp-mcp|ecosystem-orchestrator|/Users/laurence\.duggan|/dev/capabilities|~/dev|49759187\+KleinPerkins|ld-stuff'
hits="$(grep -REnI "$ld_re" "$DST" || true)"
[ -z "$hits" ] || { echo "ld token leaked into tool descriptor payload:"; printf '%s\n' "$hits"; exit 1; }

# Belt-and-suspenders: the specific pinned commit/ref from the fixture master must never appear.
hits="$(grep -RnI '11e962f\|ab9ae0b\|github\.com/KleinPerkins' "$DST" || true)"
[ -z "$hits" ] || { echo "pinned release provenance leaked into tool descriptor payload:"; printf '%s\n' "$hits"; exit 1; }

# Idempotent: a second run against the same inputs is byte-identical (consistency.sh's regen-and-cmp
# contract).
DST2="$TMP/dst2"
mkdir -p "$DST2"
payload_emit_tool_descriptor "$DST2" awa
payload_emit_vendored_md     "$DST2" awa
payload_emit_cpp_meta        "$DST2" awa "$MASTER" "$(cat "$DST/meta.yml")"
diff -q "$DST/README.md"   "$DST2/README.md"
diff -q "$DST/VENDORED.md" "$DST2/VENDORED.md"
diff -q "$DST/meta.yml"    "$DST2/meta.yml"

# Not wired: build_payload()'s kind dispatch in lib/vendor.sh must still be mcp-only (design-only
# guard — this function exists but is not on the active cpp-sync path yet).
grep -qE '^\s*if \[ "\$mk" = "mcp" \]; then\s*$' "$ROOT/lib/vendor.sh" \
  || { echo "vendor.sh kind dispatch changed shape; re-check payload_emit_tool_descriptor is still unwired"; exit 1; }
grep -q 'payload_emit_tool_descriptor' "$ROOT/lib/vendor.sh" \
  && { echo "payload_emit_tool_descriptor must NOT be wired into vendor.sh yet (design-only, Part 4)"; exit 1; }

echo "test_tool_descriptor_payload: OK"
