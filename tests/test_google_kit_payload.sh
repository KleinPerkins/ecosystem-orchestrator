#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

. "$ROOT/lib/payload.sh"

emit_meta() {
  local dir="$1" id="$2" kind="$3"
  mkdir -p "$dir"
  cat > "$dir/meta.yml" <<EOF
schema: kp-capability/v1
id: $id
kind: $kind
flavor: 1
scope: global
owner: KleinPerkins
install: install.sh
post_mgmt: none
EOF
}

MASTER="$TMP/master"
DST="$TMP/dst"
emit_meta "$MASTER" google-kit mcp
mkdir -p "$DST"
payload_emit_mcp_descriptor "$DST" google-kit
payload_emit_vendored_md "$DST" google-kit
payload_emit_cpp_meta "$DST" google-kit "$MASTER" ""

for f in \
  README.md \
  SUITE.md \
  VENDORED.md \
  meta.yml \
  templates/blank-style-profile.json \
  scripts/install-google-kit-suite.sh \
  guards/doc-styles-deny-patterns.txt
do
  [ -f "$DST/$f" ] || { echo "missing google-kit suite payload file: $f"; exit 1; }
done

[ -x "$DST/scripts/install-google-kit-suite.sh" ] || { echo "google-kit installer is not executable"; exit 1; }
grep -q '"named_styles": {}' "$DST/templates/blank-style-profile.json" || { echo "blank template missing named_styles"; exit 1; }
grep -q '\*\*/doc-styles/\*\*' "$DST/guards/doc-styles-deny-patterns.txt" || { echo "doc-styles deny pattern missing"; exit 1; }

ld_re='KleinPerkins/[A-Za-z0-9_.-]+|kp-mcp|ecosystem-orchestrator|/Users/laurence\.duggan|/dev/capabilities|49759187\+KleinPerkins'
hits="$(grep -REnI "$ld_re" "$DST" || true)"
[ -z "$hits" ] || { echo "ld token leaked into google-kit payload:"; printf '%s\n' "$hits"; exit 1; }

personal_re='Laurence|profiles/laurence|prefilled|source_doc_id": "[^"]+|template_doc_id": "[^"]+'
hits="$(grep -REnI "$personal_re" "$DST" || true)"
[ -z "$hits" ] || { echo "personal doc-style bytes leaked into google-kit payload:"; printf '%s\n' "$hits"; exit 1; }

OTHER="$TMP/other"
emit_meta "$TMP/other-master" smoke-kit mcp
mkdir -p "$OTHER"
payload_emit_mcp_descriptor "$OTHER" smoke-kit
payload_emit_vendored_md "$OTHER" smoke-kit
payload_emit_cpp_meta "$OTHER" smoke-kit "$TMP/other-master" ""
[ ! -e "$OTHER/SUITE.md" ] || { echo "suite overlay should be google-kit only"; exit 1; }

SHARED="$TMP/shared"
mkdir -p "$SHARED/doc-styles" "$SHARED/templates"
printf '# shared\n' > "$SHARED/SKILL.md"
printf '{"name":"personal"}\n' > "$SHARED/doc-styles/default.json"
printf '{"name":"blank"}\n' > "$SHARED/templates/blank-style-profile.json"
list="$(payload_shared_list "$SHARED")"
printf '%s\n' "$list" | grep -q '^templates/blank-style-profile.json$' || { echo "blank template should remain shareable"; exit 1; }
if printf '%s\n' "$list" | grep -q 'doc-styles'; then
  echo "payload_shared_list included live doc-styles content"
  exit 1
fi

echo "test_google_kit_payload: OK"
