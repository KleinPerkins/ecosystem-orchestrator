# `kind: tool`, `shape: snapshot` cpp-sync — design + wiring (M5-B)

Status: **IMPLEMENTED (2026-07-31)**. `payload_emit_tool_snapshot` (`lib/payload.sh`) is wired into
`lib/vendor.sh`'s `build_payload()` dispatch and `lib/consistency.sh`'s regen-and-cmp path. Sibling
to `docs/tool-descriptor-cpp-sync-design.md` (`shape: release-descriptor`, e.g. `awa`) — read that
doc first for the shared background (Standalone System Packages, why a tool's runtime generally
can't be vendored, the mcp precedent).

## How `shape: snapshot` differs from `shape: release-descriptor`

Both are Standalone System Packages (a separately governed release repo owns install/repair/doctor).
They differ in what their Global Capability Binding shelf carries:

| | `shape: release-descriptor` (e.g. `awa`) | `shape: snapshot` (e.g. `operator-voice`) |
|---|---|---|
| Shelf carries | a **pointer** (`tool.yml` pins repo/ref/commit) | a **payload/** directory of real runtime bytes |
| Install mechanism | clone the pinned release repo, run its `install.sh` | run `install.sh` directly against the embedded `payload/` — no clone, no access to the private SSP repo at all |
| What cpp can get vendored | discoverability only (a README naming no upstream path) | the **actual working bytes** a generic reconciler can install from |
| Why | the release repo/ref/commit are ld-only provenance (forbidden-ld tokens); nothing to vendor that isn't a leak | the shelf's `payload/` is *already* zero-link-clean — produced upstream by the SSP's own `runtime.payload` allowlist (`.py`/`.md`/`.json`/`.toml` only, no db/keychain/env/key files, personal-data-free by construction) before it ever reaches the shelf |

`operator-voice`'s build plan (§8.1) is explicit about why: it is "not an AWA-style pointer-only
downstream package... a deterministic, personal-data-free portable runtime payload generated from
that same release so the orchestrator can vendor working bytes into a governed downstream product
repo without exposing the private SSP repo or any operator data."

## The wiring

`payload_emit_tool_snapshot(dst, id, master)`:

1. Requires `master/payload/` to exist (fails loud otherwise — a `shape: snapshot` master with no
   payload is a shelf-authoring bug, not a case to silently degrade).
2. Copies `master/payload/*` verbatim into `dst/` — the file tree is already the exact allowlisted,
   zero-link-clean snapshot the upstream SSP produced (`payload-manifest.json` + the package tree).
3. Regenerates `dst/README.md`, parameterized ONLY by `<id>` — same safety-by-construction property
   as `payload_emit_tool_descriptor` (reads no field from the master, so it structurally cannot leak
   an upstream path even if one were present).
4. Does **not** copy the shelf's own `tool.yml` (carries `release: {repo, ref, commit}` — forbidden-ld
   tokens) or `meta.yml` (carries `provenance_source`/`provenance_ref`) — those are ld-management
   surface, exactly like the release-descriptor case. `VENDORED.md` + the translated `meta.yml` come
   from the same shared triad functions every other kind uses.

`build_payload()` dispatches on `shape` (not bare `kind: tool`), because a future non-SSP `kind:
tool` master (an ordinary vendorable script/binary shelf with no separate release repo and no
`payload/`) should keep the normal `payload_shared_list` tar path — that path is exactly wrong for a
snapshot master (it would tar the shelf's `tool.yml`/`README.md`, the ld-leaking files, and never
touch `payload/`'s actual bytes at their real relative paths).

`consistency.sh` gained the matching regen-and-cmp branch (mirrors its `kind: mcp` treatment): it
regenerates the expected payload into a tmpdir via the same `payload_emit_tool_snapshot` call and
byte-compares the file set against what's actually vendored in cpp, rather than the default
shared-content diff (which only makes sense when the master and the payload are the same tree).

## What still gates `operator-voice` specifically before any of this vendors for real

Independent of this wiring, landing `operator-voice` in cpp requires, in order:

1. `config/registry.yml`'s `operator-voice` record to move from `excluded` to `enrolled` (WF1) — a
   deliberate pre-GA gate, not a technical blocker; this design does not flip it.
2. If `flavor: 2` gating applies the same way it does for `awa`, `orchestrator approve
   operator-voice` pins an `approved_digest` that must match the shelf's current
   `payload_digest` at sync time (`preflight_supply_chain`).
3. `orchestrator cpp-sync` (dry-run) — should show `operator-voice` in the `OK` set, producing
   `quiver/tooling/operator-voice/` (real runtime bytes + `README.md` + `VENDORED.md` + `meta.yml`,
   `kind: tool`).
4. `orchestrator cpp-sync --execute` opens the governed vendor PR — landing depends on cpp's OWN
   integrity engine + `@affirm-cpp-bot` CODEOWNER approval, per `vendor.sh`'s existing Decision B
   (native `gh pr merge --auto --squash`, no admin bypass on the routine path).
5. Separately, inside cpp, a generic `kind: tool` install/repair reconciler must exist to actually
   consume `quiver/tooling/operator-voice/` on a PM's laptop (`docs` cross-reference: this is the
   cpp-governed control-plane exception described in the build plan's M5 §13 step 3 — authored
   INSIDE cpp, under cpp's own governance, never by this repo).

This document covers only the orchestrator-side vendoring mechanism (steps 3-4's *mechanism*, not
the registry/approval gates in 1-2, which are deliberate operator decisions with their own timeline).
