#!/usr/bin/env bash
# lib/payload.sh — payload generation helpers shared by vendor.sh + consistency.sh.
#
# Both the vendor side (writing into the cpp work-clone) and the consistency side (regenerating
# into a tmpdir for byte-comparison) MUST produce IDENTICAL payloads from identical inputs, so
# the generators live here and take their inputs explicitly. No global state, no `$WORK` / `$REL`
# coupling — callers pass in everything.
#
# Functions (all idempotent for fixed inputs):
#   payload_cpp_kind_for_kind <kp_kind>
#       Map a kp-capability/v1 kind onto cpp's CLOSED quiver meta `kind` enum.
#   payload_cpp_category_for_kind <kp_kind>
#       Map a kp kind onto a cpp quiver category dir name (skills, mcp, workflows, ...).
#   payload_emit_mcp_descriptor <dst_dir> <id>
#       Write the ld-agnostic discoverability README.md for a kind:mcp capability. For google-kit,
#       also writes the source-free suite bootstrap payload (blank template + installer/guard docs).
#   payload_emit_tool_descriptor <dst_dir> <id>
#       mcp-parity discoverability README.md for a kind:tool, shape:release-descriptor Standalone
#       System Package (e.g. AWA) whose runtime lives entirely in its own separately governed repo.
#       Wired into vendor.sh's build_payload() (2026-07-31, M5-B) — see
#       docs/tool-descriptor-cpp-sync-design.md for the original design + docs/tool-snapshot-cpp-sync-design.md
#       for the sibling shape:snapshot wiring below.
#   payload_emit_tool_snapshot <dst_dir> <id> <master_dir>
#       Vendors the ACTUAL portable runtime bytes for a kind:tool, shape:snapshot capability (e.g.
#       operator-voice) whose master carries a committed `payload/` directory (a deterministic,
#       personal-data-free snapshot produced upstream by the SSP's own release process — see
#       docs/tool-snapshot-cpp-sync-design.md). Unlike shape:release-descriptor, cpp gets WORKING
#       bytes, not just a discoverability pointer: `master_dir/payload/*` is copied verbatim (it is
#       already zero-link-clean by the upstream SSP's own payload-allowlist contract), and only the
#       ld-authored wrapper files (README.md; no tool.yml/meta.yml/install.sh — those are handled by
#       the shared triad functions or never carry a cpp-side equivalent) are regenerated ld-agnostic,
#       parameterized ONLY by <id> so this function itself can never leak an upstream path.
#   payload_emit_vendored_md <dst_dir> <id>
#       Write the generic VENDORED.md footer (capability-kind-agnostic).
#   payload_emit_cpp_meta <dst_dir> <id> <master_dir> <existing_cpp_meta_text>
#       Write the translated cpp-quiver meta.yml. `existing_cpp_meta_text` is the prior file's
#       contents (may be empty); we preserve the `created` date from it so a re-emit is byte-stable.

# Map a kp kind onto cpp's CLOSED quiver meta `kind` enum (must stay in lockstep with cpp's
# _ops/schemas/meta.schema.json: skill|workflow|sub-agent|mcp|tool|rule, additionalProperties:false).
# IDENTITY map over cpp's six LIVE kinds; FAIL-CLOSED (rc=1, prints nothing) for anything else.
# `asset|doc` are kp-only ENROLLMENT kinds that were RETIRED from cpp's quiver (reference material is
# not an executable shelf item); they are non-vendorable and must carry sync_policy:none upstream, so
# a call here with such a kind is a bug. Failing closed (instead of the old silent `*)->skill`
# default) prevents coercing a schema-invalid kind onto a cpp shelf, which would land a RED payload.
payload_cpp_kind_for_kind() {
  case "$1" in
    skill)              printf 'skill\n' ;;
    workflow)           printf 'workflow\n' ;;
    sub-agent|subagent) printf 'sub-agent\n' ;;
    mcp)                printf 'mcp\n' ;;
    tool|tooling)       printf 'tool\n' ;;
    rule)               printf 'rule\n' ;;
    *) printf 'payload_cpp_kind_for_kind: kind %s is not vendorable to cpp (cpp closed enum: skill|workflow|sub-agent|mcp|tool|rule; asset|doc are kp-only/retired)\n' "$1" >&2; return 1 ;;
  esac
}

# cpp quiver categories: skills mcp rules sub-agents tooling workflows. Map a kp kind onto one.
payload_cpp_category_for_kind() {
  case "$1" in
    skill)              printf 'skills\n' ;;
    workflow)           printf 'workflows\n' ;;
    mcp)                printf 'mcp\n' ;;
    sub-agent|subagent) printf 'sub-agents\n' ;;
    rule)               printf 'rules\n' ;;
    tool|tooling)       printf 'tooling\n' ;;
    *) printf 'payload_cpp_category_for_kind: kind %s is not vendorable to cpp (cpp shelves: skills|workflows|sub-agents|mcp|tooling|rules; asset|doc|data are kp-only/retired)\n' "$1" >&2; return 1 ;;
  esac
}

# payload_is_personal_doc_styles_path <relpath> — true for live/local doc-styles payloads that must
# never be vendored downstream. Generic starter templates are allowed when they live outside any
# `doc-styles/` runtime directory.
payload_is_personal_doc_styles_path() {
  case "$1" in
    doc-styles|doc-styles/*|*/doc-styles|*/doc-styles/*) return 0 ;;
    profiles/laurence|profiles/laurence/*|*/profiles/laurence|*/profiles/laurence/*) return 0 ;;
    *) return 1 ;;
  esac
}

payload_emit_google_kit_blank_style_profile() {
  cat <<'EOF'
{
  "schema": 1,
  "name": "blank-starter",
  "description": "Generic blank starter profile. Replace locally with operator-specific styles.",
  "named_styles": {},
  "document_style": {
    "documentFormat": {
      "documentMode": "PAGES"
    }
  },
  "template_doc_id": null,
  "source_doc_id": null
}
EOF
}

payload_emit_google_kit_suite() {
  local dst="$1"
  mkdir -p "$dst/templates" "$dst/scripts" "$dst/guards"

  cat > "$dst/SUITE.md" <<'EOF'
# google-kit suite bootstrap

This source-free package extends the MCP descriptor with the runnable bootstrap shape for a
future clone: MCP registration, CLI/bootstrap repair, utilities, and a generic document-style
starter template. It intentionally carries no operator-specific profile JSON.

## Planes

- Capability plane: google-kit code, operations, installer, repair paths, guard patterns, and the
  blank starter template.
- Personal-config plane: each operator's real style profiles under their local google-kit config
  directory. These files are created or repaired locally and must stay out of every repository.

## Local install contract

Run `scripts/install-google-kit-suite.sh` from this directory. It uses an explicit
`GOOGLE_KIT_CONFIG_DIR` when provided, otherwise a stable user-level config directory, then creates
only `doc-styles/blank-starter.json` from the generic template if no starter exists.

Operator-specific profile JSON is deliberately absent from this package.
EOF

  payload_emit_google_kit_blank_style_profile > "$dst/templates/blank-style-profile.json"

  cat > "$dst/guards/doc-styles-deny-patterns.txt" <<'EOF'
# Defense-in-depth patterns for downstream commit/data guards.
**/doc-styles/**
"named_styles"
"document_style"
"template_doc_id"
"source_doc_id"
EOF

  cat > "$dst/scripts/install-google-kit-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

suite_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
config_dir="${GOOGLE_KIT_CONFIG_DIR:-$HOME/Library/Application Support/google-kit}"
styles_dir="$config_dir/doc-styles"
starter="$styles_dir/blank-starter.json"

ensure_gitignored() {
  local path="$1" parent repo rel
  parent="$(dirname "$path")"
  mkdir -p "$parent"
  repo="$(git -C "$parent" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$repo" ] || return 0
  rel="${path#$repo/}"
  if git -C "$repo" check-ignore -q -- "$rel"; then
    return 0
  fi
  printf 'google-kit: refusing to write %s because it is inside a git worktree and is not ignored\n' "$path" >&2
  printf 'google-kit: add a narrow ignore rule for **/doc-styles/**, then rerun this installer\n' >&2
  return 1
}

mkdir -p "$styles_dir"
ensure_gitignored "$starter"
if [ ! -f "$starter" ]; then
  cp "$suite_dir/templates/blank-style-profile.json" "$starter"
  chmod 600 "$starter" 2>/dev/null || true
  printf 'google-kit: wrote blank starter profile: %s\n' "$starter"
else
  printf 'google-kit: starter profile already present: %s\n' "$starter"
fi

if command -v google-kit >/dev/null 2>&1; then
  GOOGLE_KIT_CONFIG_DIR="$config_dir" google-kit bootstrap || {
    printf 'google-kit: bootstrap command returned non-zero; profile starter remains installed\n' >&2
  }
else
  printf 'google-kit: CLI not found on PATH; install/repair the global google-kit CLI, then rerun bootstrap\n' >&2
fi

printf 'GOOGLE_KIT_CONFIG_DIR=%s\n' "$config_dir"
EOF
  chmod +x "$dst/scripts/install-google-kit-suite.sh"
}

# Emit the ld-agnostic discoverability descriptor for a `kind: mcp` capability. The MCP server's
# runtime cannot be vendored into cpp — its source tree carries forbidden-ld tokens (e.g. the
# `kp-mcp` workspace deps) and its launch command lives per-operator in ~/.cursor / ~/.codex /
# ~/.claude. We generate a clean README so the cpp side has a discoverable record of the
# capability and generic wiring guidance, with zero ld tokens.
payload_emit_mcp_descriptor() {
  local dst="$1" id="$2"
  cat > "$dst/README.md" <<EOF
# $id — MCP server (discoverability descriptor)

This directory is an **ld-agnostic discoverability descriptor** for the
\`$id\` MCP server, vendored by the ecosystem orchestrator. The server's
runtime lives outside this repository; this entry exists so agents and
operators can discover its existence, purpose, and per-machine wiring
shape without taking any dependency on upstream paths.

## What it is

\`$id\` is a Model Context Protocol (MCP) stdio server that exposes a
collection of tools to MCP-aware agent clients (Cursor, Codex, Claude).

## Per-machine wiring

Each operator wires the server into their MCP clients by writing the
non-secret launch command + args into:

- Cursor — \`~/.cursor/mcp.json\` (JSON; \`mcpServers.$id\`)
- Codex  — \`~/.codex/config.toml\` (TOML; \`[mcp_servers.$id]\`)
- Claude — \`~/.claude.json\` (JSON; \`mcpServers.$id\`, type: stdio)

Only \`command\` + \`args\` (and optional non-secret \`env\`) are written.
Tokens and credentials live in the operator's OS keychain and are NEVER
stored in any repo.

## Do not edit here

This descriptor is regenerated by the ecosystem orchestrator. Local
edits are overwritten on the next sync.
EOF
  if [ "$id" = "google-kit" ]; then
    payload_emit_google_kit_suite "$dst"
  fi
}

# Emit the ld-agnostic discoverability descriptor for a `kind: tool`, `shape: release-descriptor`
# capability — a Standalone System Package (SSP, per STANDALONE-SYSTEM-PARADIGM.md): a separately
# governed repository that installs/repairs/verifies itself end-to-end (its own `install.sh` with
# install|repair|doctor|check|uninstall verbs). AWA is the first instance (2026-07-05, dual-goal v2
# Part 4). Wired into vendor.sh's build_payload() (2026-07-31, M5-B) — see
# docs/tool-descriptor-cpp-sync-design.md.
#
# Mirrors payload_emit_mcp_descriptor exactly: the runtime cannot be vendored (its release repo path,
# ref, and commit are ld-only provenance — forbidden-ld tokens per config/forbidden-ld.txt), so this
# writes a clean README only. Deliberately parameterized ONLY by <id> (no fields are read from the
# master's meta.yml/tool.yml) so the output can never carry a leaked upstream path or pinned ref —
# the same safety-by-construction property payload_emit_mcp_descriptor already has. VENDORED.md
# (payload_emit_vendored_md) + the translated meta.yml (payload_emit_cpp_meta, already kind-aware via
# payload_cpp_kind_for_kind's tool|tooling->tool mapping) round out the same three-file triad the mcp
# descriptor produces — no separate translated tool.yml is emitted; the master's tool.yml release
# pin has no zero-link-safe cpp-side equivalent, by design.
payload_emit_tool_descriptor() {
  local dst="$1" id="$2"
  cat > "$dst/README.md" <<EOF
# $id — standalone tool release (discoverability descriptor)

This directory is an **ld-agnostic discoverability descriptor** for the
\`$id\` tool, vendored by the ecosystem orchestrator. \`$id\` ships as a
**Standalone System Package (SSP)**: a separately governed repository
that installs, repairs, and verifies itself end-to-end via its own
\`install.sh\` (\`install | --repair | --doctor | --check | --uninstall\`).
No part of that runtime — source, installer, or release pin — is
vendored here; only its existence and shape are recorded.

## What it is

\`$id\` is a self-contained standalone tool release. An operator obtains
it by cloning its release repository and running that repo's own
\`./install.sh\`. The exact repository and pinned ref are host-local
provenance and are intentionally absent from this descriptor; consult
the operator's tool-bootstrap runbook for the current pin.

## Per-machine wiring

Each operator installs \`$id\` locally via that repo's own installer,
which manages its own config, state, and any editor/agent hooks under
paths of its own choosing. Nothing here prescribes machine-local paths.

## Do not edit here

This descriptor is regenerated by the ecosystem orchestrator. Local
edits are overwritten on the next sync.
EOF
}

# Vendor the WORKING BYTES of a `kind: tool`, `shape: snapshot` capability — a Standalone System
# Package that (unlike shape:release-descriptor) publishes a deterministic, personal-data-free
# portable payload directly on its Global Capability Binding shelf (`master_dir/payload/`,
# operator-voice is the first instance). That `payload/` tree is produced upstream by the SSP's own
# release process (e.g. `operator_voice.runtime.payload.build_portable_payload`) against an
# allowlist that already excludes anything but source-shaped files, so it is zero-link-clean BEFORE
# it ever reaches this shelf — this function copies it verbatim rather than re-deriving it, and the
# caller's `orch_zero_link cpp` gate re-checks it anyway (defense in depth, not trust).
#
# What is NOT copied: everything else on the shelf (README.md, tool.yml, meta.yml, install.sh) is
# ld-management surface — tool.yml in particular carries the release repo/ref/commit (forbidden-ld
# tokens), exactly like the release-descriptor case. README.md is regenerated here, parameterized
# ONLY by <id> (mirrors payload_emit_tool_descriptor's safety-by-construction: this function reads
# no field from the master, so it cannot leak one). meta.yml/VENDORED.md come from the same shared
# triad functions every other kind uses.
payload_emit_tool_snapshot() {
  local dst="$1" id="$2" master="$3" src="$3/payload"
  [ -d "$src" ] || { printf 'payload_emit_tool_snapshot: %s has no payload/ dir (shape:snapshot requires one)\n' "$master" >&2; return 1; }
  ( cd "$src" && find . -type f | sed 's|^\./||' ) | while IFS= read -r f; do
    [ -n "$f" ] || continue
    mkdir -p "$dst/$(dirname "$f")"
    cp "$src/$f" "$dst/$f"
  done
  cat > "$dst/README.md" <<EOF
# $id — standalone tool release (portable payload snapshot)

This directory carries a **vendored, ld-agnostic portable payload
snapshot** for the \`$id\` tool, vendored by the ecosystem orchestrator.
\`$id\` ships as a **Standalone System Package (SSP)** whose Global
Capability Binding shelf publishes a deterministic, personal-data-free
snapshot of its runtime rather than only a discoverability pointer —
so, unlike a release-descriptor tool, the working bytes below are real
and directly installable by a generic \`kind: tool\` installer/repair
reconciler with no access to \`$id\`'s upstream release repository.

## What it is

A content-addressed snapshot of \`$id\`'s runtime source tree (see the
sibling \`payload-manifest.json\` for the exact file list + digest). No
part of this snapshot carries operator data, secrets, or upstream repo
provenance — those are excluded upstream, before the snapshot is ever
produced.

## Per-machine wiring

A generic reconciler installs from this directory exactly as it would
from any other \`kind: tool\` snapshot: verify the manifest digest, then
provision a runtime slot from these bytes. Nothing here prescribes
machine-local paths beyond the reconciler's own generic contract.

## Do not edit here

This snapshot is regenerated by the ecosystem orchestrator on every
sync. Local edits are overwritten on the next sync.
EOF
}

# payload_expose_norm <master_dir> — print the master's `expose:` as a normalized, sorted,
# space-separated tool list. ABSENT => all three tools (Decision D4: default-all-three for Phase 1).
# Accepts either flow form (`expose: cursor claude codex`) or inline-seq (`expose: [cursor, claude]`).
payload_expose_norm() {
  local mm="$1/meta.yml" raw
  raw="$(awk -F'expose:[[:space:]]*' '/^expose:/{print $2; exit}' "$mm" 2>/dev/null || true)"
  raw="$(printf '%s' "$raw" | tr -d '[]' | tr ',' ' ')"
  [ -n "$(printf '%s' "$raw" | tr -d '[:space:]')" ] || raw="cursor claude codex"
  printf '%s' "$raw" | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort -u | paste -sd' ' -
}

# payload_shared_list <dir> — relative paths of shared payload content, sorted.
#
# Git-backed masters use the repo's own ignore rules, so test/build artifacts generated during local
# verification (for example agent-route's fixture `.state/`) never leak into a cpp payload.
payload_shared_list() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  (
    cd "$dir" 2>/dev/null || exit 1
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
      git ls-files -c -o --exclude-standard -- .
    else
      find . -type f | sed 's|^\./||'
    fi | while IFS= read -r f; do
      [ -n "$f" ] || continue
      [ -f "$f" ] || continue
      case "$f" in
        meta.yml|install.sh|VENDORED.md|eco-capability-manifest.yml) continue ;;
        .git/*|*/.git/*|__pycache__/*|*/__pycache__/*|.state/*|*/.state/*|*.pyc) continue ;;
      esac
      if payload_is_personal_doc_styles_path "$f"; then continue; fi
      printf '%s\n' "$f"
    done | LC_ALL=C sort -u
  )
}

# payload_content_digest <dir> — stable SHA-256 fingerprint of a capability's NORMALIZED shared-content
# set (follow-on f1 / Decision G1). Uses payload_shared_list, so digest, consistency, and vendor emit
# are all based on the same git-ignore-aware payload file set. ANY change to a shared file
# (content edit, add, remove, OR rename) flips the digest: the hash is taken over a deterministic
# "<relpath>\n<file-sha256>\n" stream, so a move is caught as well as a content change. Prints the
# 64-char hex digest; returns 1 (printing nothing) if <dir> is missing. NOTE: for kind:mcp the master
# source is NOT what gets vendored (a descriptor is), so this is an upstream-source fingerprint only and
# the f3 supply-chain gate is scoped to flavor-2 (third-party-snapshot) masters, where it does match.
payload_content_digest() {
  local dir="$1"
  [ -d "$dir" ] || return 1
  _pcd_sha() {   # sha256 of stdin -> bare hex (portable across coreutils / macOS / openssl)
    if   command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    elif command -v shasum    >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
    else openssl dgst -sha256 | awk '{print $NF}'; fi
  }
  local stream
  stream="$( cd "$dir" 2>/dev/null && payload_shared_list "$dir" | while IFS= read -r f; do printf '%s\n' "$f"; _pcd_sha < "$f"; done )"
  printf '%s' "$stream" | _pcd_sha
  unset -f _pcd_sha
}

# payload_emit_manifest <dst_file> <owned_ids> <existing_text> <id:category:scope:expose>...
# Write the data-plane eco-capability-manifest.yml (schema eco-manifest/v1, meta-less so cpp's C0-C6
# engine never parses it). `items` is the active delivery set; `owned_ids` is the independently
# derived active-plus-historical-tombstone prune namespace. The body is the only diff-determining
# content; the `generated_at` stamp is PRESERVED from <existing_text> whenever the body is unchanged,
# so a no-op cpp-sync re-emits a BYTE-IDENTICAL file (git no-op -> no spurious manifest PR). Items
# arrive pre-sorted by the caller as `id:category:scope:space-joined-expose` tuples.
payload_emit_manifest() {
  local dst="$1" owned="$2" existing="$3"; shift 3
  local items="" tup id cat scope expose e o
  for tup in "$@"; do
    [ -n "$tup" ] || continue
    id="${tup%%:*}"; tup="${tup#*:}"
    cat="${tup%%:*}"; tup="${tup#*:}"
    scope="${tup%%:*}"; expose="${tup#*:}"
    local elist=""; for e in $expose; do elist="$elist, $e"; done; elist="${elist#, }"
    items="$items  - id: $id
    category: $cat
    scope: $scope
    expose: [$elist]
"
  done
  local ownseq="" ; for o in $owned; do ownseq="$ownseq, $o"; done; ownseq="[${ownseq#, }]"

  # Render the full file for a given generated_at. Static header via heredoc; the items block is
  # appended with printf so the file ends cleanly on the last item line (no stray trailing blank).
  _man_render() {
    cat <<EOF
schema: eco-manifest/v1
# eco-capability-manifest.yml — orchestrator-written DATA-plane file (B5). meta-LESS by design so
# cpp's quiver integrity engine + production-bar (which parse meta.yml only) never see it; it is
# consistency-excluded (lib/consistency.sh shared_list) so per-sync regen never breaks INV-master.
# Prune input for the cpp-side reconciler: items is the active set; owned_ids is the independently
# derived current-or-removed ownership set. The reconciler prunes only exact current-repo links
# authorized by owned_ids and independently refuses cpp-native or foreign-quiver links (B6
# defense-in-depth). Removed ownership remains as a bounded historical tombstone so laptop reconcilers
# that sync arbitrarily late can still prune dangling links; no cpp-native id is inferred into the set.
# Regenerated as one atomic PR per cpp-sync run, landing AFTER the per-id payload PRs (eventual
# consistency is safe: the reconciler warns-on-missing-payload and never hard-fails a not-yet-landed
# active item).
generated_at: "$1"
owned_ids: $ownseq
items:
EOF
    printf '%s' "$items"
  }
  # Preserve the prior generated_at iff EVERYTHING but that line is byte-identical (so a no-op sync
  # re-emits a byte-stable file -> git no-op -> no spurious manifest PR).
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ -n "$existing" ]; then
    local new_stripped old_stripped old_gen
    new_stripped="$(_man_render "__GEN__" | grep -v '^generated_at:')"
    old_stripped="$(printf '%s\n' "$existing" | grep -v '^generated_at:')"
    if [ "$new_stripped" = "$old_stripped" ]; then
      old_gen="$(printf '%s\n' "$existing" | awk -F'"' '/^generated_at:/{print $2; exit}')"
      [ -n "$old_gen" ] && now="$old_gen"
    fi
  fi
  _man_render "$now" > "$dst"
  unset -f _man_render
}

# Emit the generic VENDORED.md footer (capability-kind-agnostic).
payload_emit_vendored_md() {
  local dst="$1" id="$2"
  cat > "$dst/VENDORED.md" <<EOF
# Vendored capability: $id

This directory is a self-sufficient vendored copy managed by the ecosystem orchestrator.
Do not edit it here — changes are overwritten on the next sync. It carries no upstream paths.
EOF
}

# Translate the master kp-capability/v1 meta into cpp's CLOSED quiver meta schema.
# `existing_cpp_meta_text` is the prior cpp meta.yml content (may be empty on first vendor).
# `created` is preserved from existing when present (idempotent re-emit), else today.
# `updated` is derived from the master's meta (its updated, else its created, else today),
# NEVER `date`, so re-emitting an unchanged master yields byte-identical output.
payload_emit_cpp_meta() {
  local dst="$1" id="$2" master="$3" base_meta="${4:-}"
  local mm="$master/meta.yml"
  local kind cppkind owner title today kws created updated
  # awk on a missing file returns rc=2; under `set -e` a command-substitution failure aborts
  # the caller. Suffix each optional read with `|| true` so the assignment cleanly falls back
  # to the documented default.
  kind="$(awk -F': *' '/^kind:/{print $2; exit}'  "$mm" 2>/dev/null || true)";  kind="${kind:-skill}"
  cppkind="$(payload_cpp_kind_for_kind "$kind")"
  owner="$(awk -F': *' '/^owner:/{print $2; exit}' "$mm" 2>/dev/null || true)"; owner="${owner:-KleinPerkins}"
  today="$(date +%Y-%m-%d)"
  title="$(awk 'NF && /^# /{sub(/^# /,""); print; exit}' "$dst/SKILL.md" 2>/dev/null || true)"; title="${title:-$id}"
  kws="$(printf '%s' "$id" | tr '-' '\n' | awk 'NF{printf "\"%s\", ", $0}' | sed 's/, $//')"
  created="$(printf '%s\n' "$base_meta" | awk -F': *' '/^created:/{v=$2; gsub(/"/,"",v); print v; exit}' || true)"
  [ -n "$created" ] || created="$today"
  updated="$(awk -F': *' '/^updated:/{v=$2; gsub(/"/,"",v); print v; exit}' "$mm" 2>/dev/null || true)"
  [ -n "$updated" ] || updated="$(awk -F': *' '/^created:/{v=$2; gsub(/"/,"",v); print v; exit}' "$mm" 2>/dev/null || true)"
  [ -n "$updated" ] || updated="$created"
  cat > "$dst/meta.yml" <<EOF
id: $id
type: resource
status: stable
scope: team
owner: $owner
title: "$title"
kind: $cppkind
keywords: [$kws]
source: "vendored by the ecosystem orchestrator (self-sufficient copy)"
created: "$created"
updated: "$updated"
EOF
}
