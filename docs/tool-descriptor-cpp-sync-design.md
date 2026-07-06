# `kind: tool` cpp-sync discoverability — design (Phase 2, design-only)

Status: **design-only**. `payload_emit_tool_descriptor` (`lib/payload.sh`) is implemented and
tested but **not wired** into `lib/vendor.sh`'s active `build_payload()` dispatch. No cpp PR is
opened by this design; Decision D2 ("AWA cpp delivery stays discoverability-only, no cpp-sync yet")
is not lifted by this change.

## Why this exists

AWA (`global/tools/awa`, `kind: tool`, `flavor: 2`, `shape: release-descriptor`) is the first
**Standalone System Package (SSP)** capability: a tool whose entire runtime — install, repair,
doctor, kernel, engine — lives in its own separately governed repository
(`KleinPerkins/awa`). The global shelf entry is a **record-only pointer**: it clones the pinned
ref and runs the checkout's own `install.sh`; it vendors nothing itself.

`kind: mcp` already has this exact problem (an MCP server's runtime can't be vendored into cpp
either — its source carries forbidden-ld tokens) and already has a solved discoverability path:
`payload_emit_mcp_descriptor` writes a clean, ld-agnostic `README.md`; `payload_emit_vendored_md` +
`payload_emit_cpp_meta` (kind-aware, shared) round out the triad. `payload_emit_tool_descriptor`
mirrors that exact pattern for `kind: tool` release-descriptor masters.

## Why the runtime still can't be vendored today

`build_payload()` (`lib/vendor.sh`) currently has one special case:

```bash
if [ "$mk" = "mcp" ]; then
  emit_mcp_descriptor "$dst"          # descriptor mode
else
  ( cd "$MASTER" && payload_shared_list "$MASTER" | tar -cf - -T - ) | ( cd "$dst" && tar -xf - )
fi
```

For `kind: tool`, that `else` branch would tar AWA's shelf files (`README.md`, `install.sh`,
`meta.yml`, `tool.yml`) verbatim into cpp. `meta.yml` carries `provenance_source: github.com/
KleinPerkins/awa` and `tool.yml` carries `release: {repo: github.com/KleinPerkins/awa, ref, commit}`
plus prose that names the repo — all forbidden-ld tokens (`config/forbidden-ld.txt`:
`KleinPerkins/[A-Za-z0-9_.-]+`). `orch_zero_link cpp "$DST"` in `vendor.sh` would trip and abort
before any push — a real safety net, but a hard failure, not a deliberate discoverability shape.

## The future wiring (NOT done by this change)

A later, separately-reviewed PR would extend the dispatch:

```bash
SHAPE="$(awk -F': *' '/^shape:/{print $2; exit}' "$MASTER/meta.yml" 2>/dev/null)"
if [ "$mk" = "mcp" ]; then
  emit_mcp_descriptor "$dst"
elif [ "$mk" = "tool" ] && [ "$SHAPE" = "release-descriptor" ]; then
  payload_emit_tool_descriptor "$dst" "$ID"
else
  ( cd "$MASTER" && payload_shared_list "$MASTER" | tar -cf - -T - ) | ( cd "$dst" && tar -xf - )
fi
```

Gated gate for shape (not bare `kind: tool`) because a future non-SSP `kind: tool` master
(ordinary vendorable script/binary shelf, no separate release repo) should keep the normal tar path.

## What still gates AWA specifically before any of that matters

Independent of this design, AWA cannot reach `build_payload()` via `cpp-sync` today:

- AWA is `flavor: 2`, so `preflight_supply_chain` (`lib/selfmanage.sh`) requires a registry
  `approved_digest`. `config/registry.yml`'s `awa` record carries none — `orchestrator approve awa`
  has deliberately not been run. Preflight blocks with `supply-chain: awa flavor-2 is missing
  approved_digest`, before `vendor.sh` (and therefore before this design's dispatch point) ever runs.
- This PR does **not** run `orchestrator approve awa` — that stays a distinct, deliberate future
  step per the plan ("`orchestrator approve awa` after digest stable; cpp-sync when D2 lifted").

## Sequence to actually lift D2 (future, out of scope here)

1. AWA's `KleinPerkins/awa` release digest/pin stabilizes.
2. `orchestrator approve awa` (pins `approved_digest`; still no vendor, no PR).
3. The `build_payload()` dispatch above is added in its own reviewed PR (tested against this
   function + `tests/test_tool_descriptor_payload.sh`).
4. `orchestrator cpp-sync` (dry-run) — should now show `awa` in the `OK` set, producing a
   `quiver/tooling/awa/` discoverability payload (`README.md` + `VENDORED.md` + `meta.yml`,
   `kind: tool`) — record-only, matching `sync_policy: record-only` in AWA's shelf `meta.yml`.
5. `orchestrator cpp-sync --execute` opens the governed vendor PR.

Runtime install for cpp PMs is unaffected by any of the above and stays:
`git clone KleinPerkins/awa && ./install.sh`.
