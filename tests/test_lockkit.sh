#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.name "KleinPerkins"
  git -C "$repo" config user.email "49759187+KleinPerkins@users.noreply.github.com"
}

emit_install() {
  local dir="$1"
  cat > "$dir/install.sh" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "$dir/install.sh"
}

emit_meta() {
  local dir="$1" id="$2" kind="$3" scope="$4"
  mkdir -p "$dir"
  cat > "$dir/meta.yml" <<EOF
schema: kp-capability/v1
id: $id
kind: $kind
flavor: 1
scope: $scope
owner: KleinPerkins
install: install.sh
EOF
  [ "$kind" = "tool" ] && {
    printf 'shape: descriptor-only\nsync_policy: record-only\n' >> "$dir/meta.yml"
    printf 'id: %s\nshape: descriptor-only\nsync_policy: record-only\n' "$id" > "$dir/tool.yml"
  }
  [ "$kind" = "skill" ] && printf '# %s\n' "$id" > "$dir/SKILL.md"
  [ "$kind" = "rule" ] && printf '# %s\n' "$id" > "$dir/$id.mdc"
  [ "$kind" = "sub-agent" ] && printf '# %s\n' "$id" > "$dir/$id.md"
  emit_install "$dir"
}

emit_verifier() {
  local repo="$1" rel="$2"
  mkdir -p "$repo/$(dirname "$rel")"
  cat > "$repo/$rel" <<'EOS'
#!/usr/bin/env bash
exit 0
EOS
  chmod +x "$repo/$rel"
}

commit_all() {
  local repo="$1" msg="${2:-fixture}"
  git -C "$repo" add .
  git -C "$repo" commit -q -m "$msg"
}

SKILLS="$TMP/skills"
MCP="$TMP/mcp"
SHELVES="$TMP/shelves"
init_repo "$SKILLS"
init_repo "$MCP"
init_repo "$SHELVES"
emit_meta "$SKILLS/global/skills/foo" foo skill global
emit_meta "$SKILLS/local/skills/bar" bar skill local
emit_meta "$MCP/google-kit" google-kit mcp global
emit_meta "$SHELVES/global/skills/shelf-foo" shelf-foo skill global
emit_meta "$SHELVES/global/rules/rule-one" rule-one rule global
emit_meta "$SHELVES/local/sub-agents/agent-one" agent-one sub-agent local
emit_meta "$SHELVES/local/tools/tool-one" tool-one tool local
emit_verifier "$SKILLS" ".github/scripts/verify-skills.sh"
emit_verifier "$MCP" ".github/scripts/verify-capabilities.sh"
emit_verifier "$SHELVES" ".github/scripts/verify-skills.sh"
commit_all "$SKILLS" "initial skills"
commit_all "$MCP" "initial mcp"
commit_all "$SHELVES" "initial shelves"

CFG="$TMP/lockkit.yml"
cat > "$CFG" <<EOF
schema: lockkit/v1
master: templates/eco-lock/eco-lock.sh
targets:
  - name: skills
    root: $SKILLS
    script: .github/scripts/eco-lock.sh
    lock: .eco-registry.lock
    verify: .github/scripts/verify-skills.sh
  - name: flat-mcp
    root: $MCP
    script: .github/scripts/eco-lock.sh
    lock: .eco-registry.lock
    verify: .github/scripts/verify-capabilities.sh
  - name: shelves
    root: $SHELVES
    script: .github/scripts/eco-lock.sh
    lock: .eco-registry.lock
    verify: .github/scripts/verify-skills.sh
EOF

LK=(env LOCKKIT_CONFIG="$CFG" bash "$ROOT/lib/lockkit.sh")
REPAIR_CMD="bash .github/scripts/eco-lock.sh write && git add .eco-registry.lock"

"${LK[@]}" write
commit_all "$SKILLS" "lockkit initial"
commit_all "$MCP" "lockkit initial"
commit_all "$SHELVES" "lockkit initial"
"${LK[@]}" check
grep -q 'shelf=rules' "$SHELVES/.eco-registry.lock" || { echo "shelf records missing from lock"; exit 1; }
grep -q 'source_path=global/rules/rule-one' "$SHELVES/.eco-registry.lock" || { echo "source_path missing from lock"; exit 1; }

REPAIR="$TMP/repair-hint"
init_repo "$REPAIR"
emit_meta "$REPAIR/global/skills/repair-me" repair-me skill global
mkdir -p "$REPAIR/.github/scripts"
cp "$ROOT/templates/eco-lock/eco-lock.sh" "$REPAIR/.github/scripts/eco-lock.sh"
chmod +x "$REPAIR/.github/scripts/eco-lock.sh"
( cd "$REPAIR" && bash .github/scripts/eco-lock.sh write )
commit_all "$REPAIR" "repair hint initial"
printf 'expose: cursor\n' >> "$REPAIR/global/skills/repair-me/meta.yml"
if ( cd "$REPAIR" && bash .github/scripts/eco-lock.sh check ) >/tmp/lockkit-repair-hint.$$ 2>&1; then
  echo "eco-lock check should fail on stale lock"
  exit 1
fi
grep -Fq "$REPAIR_CMD" /tmp/lockkit-repair-hint.$$ || { echo "stale lock repair hint missing full command"; exit 1; }
rm -f "$REPAIR/.eco-registry.lock"
if ( cd "$REPAIR" && bash .github/scripts/eco-lock.sh check ) >/tmp/lockkit-missing-lock.$$ 2>&1; then
  echo "eco-lock check should fail when lock is missing"
  exit 1
fi
grep -Fq "$REPAIR_CMD" /tmp/lockkit-missing-lock.$$ || { echo "missing lock repair hint missing full command"; exit 1; }

before="$(git -C "$SKILLS" rev-parse HEAD)"
"${LK[@]}" write skills
after_status="$(git -C "$SKILLS" status --porcelain)"
[ -z "$after_status" ] || { echo "lockkit write was not byte-stable on clean skills fixture"; exit 1; }
[ "$before" = "$(git -C "$SKILLS" rev-parse HEAD)" ] || { echo "lockkit write unexpectedly committed"; exit 1; }

printf '\n# committed local drift\n' >> "$SKILLS/.github/scripts/eco-lock.sh"
commit_all "$SKILLS" "drift eco-lock"
if "${LK[@]}" check skills >/tmp/lockkit-check.$$ 2>&1; then
  echo "lockkit check should fail on committed script drift"
  exit 1
fi
"${LK[@]}" write skills >/tmp/lockkit-write.$$ 2>&1
cmp -s "$ROOT/templates/eco-lock/eco-lock.sh" "$SKILLS/.github/scripts/eco-lock.sh" || {
  echo "lockkit write did not restore the master script"
  exit 1
}

printf '\n# dirty working tree\n' >> "$MCP/google-kit/meta.yml"
if "${LK[@]}" write flat-mcp >/tmp/lockkit-dirty.$$ 2>&1; then
  echo "lockkit write should refuse dirty target repos"
  exit 1
fi
"${LK[@]}" --allow-dirty write flat-mcp >/tmp/lockkit-allow-dirty.$$ 2>&1

BAD="$TMP/bad-shelf"
init_repo "$BAD"
emit_meta "$BAD/global/rules/not-skill" not-skill skill global
mkdir -p "$BAD/.github/scripts"
cp "$ROOT/templates/eco-lock/eco-lock.sh" "$BAD/.github/scripts/eco-lock.sh"
chmod +x "$BAD/.github/scripts/eco-lock.sh"
if ( cd "$BAD" && bash .github/scripts/eco-lock.sh write ) >/tmp/lockkit-bad-shelf.$$ 2>&1; then
  echo "eco-lock should reject shelf-kind mismatch"
  exit 1
fi

UNKNOWN="$TMP/unknown-shelf"
init_repo "$UNKNOWN"
emit_meta "$UNKNOWN/global/widgets/widget-one" widget-one skill global
mkdir -p "$UNKNOWN/.github/scripts"
cp "$ROOT/templates/eco-lock/eco-lock.sh" "$UNKNOWN/.github/scripts/eco-lock.sh"
chmod +x "$UNKNOWN/.github/scripts/eco-lock.sh"
if ( cd "$UNKNOWN" && bash .github/scripts/eco-lock.sh write ) >/tmp/lockkit-unknown-shelf.$$ 2>&1; then
  echo "eco-lock should reject unknown shelves"
  exit 1
fi

DUP="$TMP/duplicate-id"
init_repo "$DUP"
emit_meta "$DUP/global/skills/dupe" dupe skill global
emit_meta "$DUP/local/rules/dupe" dupe rule local
mkdir -p "$DUP/.github/scripts"
cp "$ROOT/templates/eco-lock/eco-lock.sh" "$DUP/.github/scripts/eco-lock.sh"
chmod +x "$DUP/.github/scripts/eco-lock.sh"
if ( cd "$DUP" && bash .github/scripts/eco-lock.sh write ) >/tmp/lockkit-duplicate-id.$$ 2>&1; then
  echo "eco-lock should reject duplicate bare ids"
  exit 1
fi

echo "test_lockkit: OK"
