#!/usr/bin/env bash
# tests/test_tool_snapshot_payload.sh — hermetic fixture for payload_emit_tool_snapshot
# (kind:tool, shape:snapshot; wired 2026-07-31 M5-B; see docs/tool-snapshot-cpp-sync-design.md).
# Mirrors tests/test_tool_descriptor_payload.sh's shape for the sibling release-descriptor case.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

. "$ROOT/lib/payload.sh"

# Fixture master mirrors global/tools/operator-voice's real shape: a shelf with ld-leaking
# README.md/tool.yml/meta.yml at its root, and a payload/ dir carrying the actual (already
# zero-link-clean) runtime snapshot — exactly the split payload_emit_tool_snapshot must respect.
MASTER="$TMP/master"
mkdir -p "$MASTER/payload/operator_voice/runtime"
cat > "$MASTER/meta.yml" <<'EOF'
schema: kp-capability/v1
id: operator-voice
kind: tool
flavor: 2
scope: global
owner: KleinPerkins
install: install.sh
post_mgmt: none
shape: snapshot
sync_policy: portable-payload-snapshot
expose: cursor claude codex
provenance_source: "github.com/KleinPerkins/operator-voice"
provenance_ref: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
provenance_trust: "vetted"
payload_digest: "fixturedigest0000000000000000000000000000000000000000000000000"
payload_version: "0.1.1"
EOF
cat > "$MASTER/tool.yml" <<'EOF'
schema: kp-tool/v1
id: operator-voice
name: Operator Voice Toolkit (portable-payload snapshot binding)
scope: global
shape: snapshot
sync_policy: portable-payload-snapshot
entrypoint: install.sh
description: >-
  GCB to the Operator Voice Toolkit SSP at github.com/KleinPerkins/operator-voice.
release:
  repo: github.com/KleinPerkins/operator-voice
  ref: main
  commit: deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
EOF
cat > "$MASTER/README.md" <<'EOF'
# operator-voice GCB

See github.com/KleinPerkins/operator-voice for the SSP source.
EOF
cat > "$MASTER/payload/operator_voice/__init__.py" <<'EOF'
__version__ = "0.1.1"
EOF
cat > "$MASTER/payload/operator_voice/runtime/requirements.json" <<'EOF'
{"schema": "runtime-requirements/v1", "install_requires": ["cryptography>=48.0.1,<49.0"]}
EOF
cat > "$MASTER/payload/payload-manifest.json" <<'EOF'
{"schema": "payload-manifest/v1", "version": "0.1.1", "digest": "fixturedigest0000000000000000000000000000000000000000000000000", "file_count": 2, "files": ["operator_voice/__init__.py", "operator_voice/runtime/requirements.json"]}
EOF

DST="$TMP/dst"
mkdir -p "$DST"
payload_emit_tool_snapshot "$DST" operator-voice "$MASTER"
payload_emit_vendored_md   "$DST" operator-voice
payload_emit_cpp_meta      "$DST" operator-voice "$MASTER" ""

# Exactly the payload/ tree contents (flattened, no payload/ prefix) plus the triad — never the
# master's own README.md/tool.yml verbatim, never a translated tool.yml.
for f in README.md VENDORED.md meta.yml operator_voice/__init__.py operator_voice/runtime/requirements.json payload-manifest.json; do
  [ -f "$DST/$f" ] || { echo "missing expected snapshot payload file: $f"; exit 1; }
done
extra="$(cd "$DST" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)"
expected="$(printf '%s\n' README.md VENDORED.md meta.yml operator_voice/__init__.py operator_voice/runtime/requirements.json payload-manifest.json | LC_ALL=C sort)"
[ "$extra" = "$expected" ] || { echo "snapshot payload file set mismatch:"; echo "got:"; echo "$extra"; echo "want:"; echo "$expected"; exit 1; }

grep -q '^kind: tool$' "$DST/meta.yml" || { echo "translated meta.yml did not map kind:tool -> tool"; exit 1; }

# The vendored payload/operator_voice/__init__.py must be BYTE-IDENTICAL to the master's (verbatim
# copy of already-clean bytes), proving payload_emit_tool_snapshot doesn't rewrite runtime content.
diff -q "$MASTER/payload/operator_voice/__init__.py" "$DST/operator_voice/__init__.py"
diff -q "$MASTER/payload/operator_voice/runtime/requirements.json" "$DST/operator_voice/runtime/requirements.json"

# Zero-link: no ld tokens anywhere in the emitted payload — even though the fixture master's
# meta.yml/tool.yml/README.md deliberately carry every token forbidden-ld.txt bans, proving
# payload_emit_tool_snapshot copies ONLY payload/ (already clean upstream) and never the shelf's
# own ld-management files.
ld_re='KleinPerkins/[A-Za-z0-9_.-]+|kp-mcp|ecosystem-orchestrator|/Users/laurence\.duggan|/dev/capabilities|~/dev|49759187\+KleinPerkins|ld-stuff'
hits="$(grep -REnI "$ld_re" "$DST" || true)"
[ -z "$hits" ] || { echo "ld token leaked into tool snapshot payload:"; printf '%s\n' "$hits"; exit 1; }
hits="$(grep -RnI 'deadbeefdeadbeef\|github\.com/KleinPerkins' "$DST" || true)"
[ -z "$hits" ] || { echo "pinned release provenance leaked into tool snapshot payload:"; printf '%s\n' "$hits"; exit 1; }

# Missing payload/ must fail loud, not silently emit an empty/partial snapshot.
NOPAYLOAD="$TMP/nopayload"; mkdir -p "$NOPAYLOAD"
if payload_emit_tool_snapshot "$TMP/dst-fail" nopayload "$NOPAYLOAD" 2>/tmp/tsp-err.$$; then
  echo "payload_emit_tool_snapshot should fail when master has no payload/ dir"; exit 1
fi
grep -q 'no payload/ dir' /tmp/tsp-err.$$ || { echo "unexpected error message for missing payload/"; cat /tmp/tsp-err.$$; exit 1; }
rm -f /tmp/tsp-err.$$

# Idempotent: a second run against the same inputs is byte-identical (consistency.sh's regen-and-cmp
# contract, same as the mcp/release-descriptor triads).
DST2="$TMP/dst2"
mkdir -p "$DST2"
payload_emit_tool_snapshot "$DST2" operator-voice "$MASTER"
payload_emit_vendored_md   "$DST2" operator-voice
payload_emit_cpp_meta      "$DST2" operator-voice "$MASTER" "$(cat "$DST/meta.yml")"
diff -q "$DST/README.md"   "$DST2/README.md"
diff -q "$DST/VENDORED.md" "$DST2/VENDORED.md"
diff -q "$DST/meta.yml"    "$DST2/meta.yml"
diff -q "$DST/operator_voice/__init__.py" "$DST2/operator_voice/__init__.py"

# Wired (M5-B): build_payload()'s kind dispatch in lib/vendor.sh must call
# payload_emit_tool_snapshot for a snapshot-shape master.
grep -q 'payload_emit_tool_snapshot "\$dst" "\$ID" "\$MASTER"' "$ROOT/lib/vendor.sh" \
  || { echo "payload_emit_tool_snapshot is not wired into vendor.sh's build_payload() dispatch"; exit 1; }
grep -qE 'shape.*=.*snapshot' "$ROOT/lib/vendor.sh" \
  || { echo "vendor.sh build_payload() does not gate on shape:snapshot"; exit 1; }

# consistency.sh must dispatch kind:tool through the regen-and-cmp branch (not the default
# shared-content diff, which would be wrong for a snapshot master).
grep -q 'payload_emit_tool_snapshot' "$ROOT/lib/consistency.sh" \
  || { echo "consistency.sh does not call payload_emit_tool_snapshot in its kind:tool branch"; exit 1; }

echo "test_tool_snapshot_payload: OK"
