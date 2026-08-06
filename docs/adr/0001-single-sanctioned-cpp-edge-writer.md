# ADR 0001: single sanctioned cpp edge writer
Status: draft — 2026-08-06

## Decision

Only `KleinPerkins/ecosystem-orchestrator` may write the ld→cpp data-plane edge. Per-id
payload delivery runs through `lib/vendor.sh`; the atomic manifest runs through `lib/manifest.sh`;
both are invoked by `bin/orchestrator.sh` (WF2). No agent, skill, operator script, or other
repository may hand-vendor into `Affirm/card-platform-product`.

## Why

The ld↔cpp relationship is governed by **INV-zero-link**: no ld artifact names cpp and no cpp
artifact names ld; the relationship exists only in this repo (`config/relationship.yml`). A single
sanctioned writer is the enforcement point for that invariant plus the WF1/WF2 gates that precede
any push.

**Alternative: agents or operators hand-vendor into cpp.** Rejected. Bypasses enrollment
(`config/registry.yml`), zero-link scanning (`config/forbidden-ld.txt`, `orch_zero_link` in
`lib/vendor.sh`), flavor-2 `approved_digest` preflight, and local cpp-integrity. Past incidents
and the operating manual treat ad-hoc affirm/ writes as out-of-band and unsafe.

**Alternative: symlink dedup (ld master = cpp copy).** Rejected and retired (Decision A, recorded
in `config/relationship.yml`). Routine cpp git operations write through symlinks into the global
source of truth; master bytes and vendored payload bytes are intentionally different shapes.
Integrity is enforced by `orchestrator consistency` (`lib/consistency.sh`), not by collapsing
copies.

**Alternative: upstream capability repos (e.g. `KleinPerkins/skills`) push directly to cpp.**
Rejected. Skill and MCP masters carry forbidden-ld tokens; cpp payloads must be self-sufficient
and ld-agnostic. Descriptor modes (`kind: mcp`, `kind: tool` release-descriptor) exist precisely
because the runtime cannot be tarred verbatim (see `docs/tool-descriptor-cpp-sync-design.md`).

**Chosen option:** a dedicated orchestrator with explicit Regime B PR authoring for cpp
(`lib/vendor.sh` enables native auto-merge only after local integrity is GREEN) and a hard
forbidden-path list for cpp's control plane (`_ops/`, `.github/`). This matches live wiring:
`cpp_merge_mode: auto-squash` in `config/relationship.yml`, zero references to ld from cpp
payloads, and cpp-side consumption via `_ops/bin/eco-capability-reconcile.sh` on PM laptops.

## Consequences

**Enables:** registry-driven WF2 (`cpp-sync`), bounded delete-propagation, one atomic manifest
(`eco-manifest/v1`), compensating master↔payload consistency checks, and a clear audit trail of
every cpp data-plane change (orchestrator branch prefix `orchestrator/vendor`).

**Forecloses:** hand edits under `affirm/src/card-platform-product/quiver/` from ld agents,
symlink shortcuts, and any second writer of the ld↔cpp edge. Extending delivery to new kinds or
targets requires changing this repo and, when cpp routing changes, a cpp-governed reconciler PR —
not a parallel vendoring path.

**Must remain true:** `config/relationship.yml` stays the sole relationship definition;
`lib/vendor.sh` / `lib/manifest.sh` stay the only cpp data-plane mutators; cpp control plane
paths stay untouched; fleet PRs in this repo follow Regime A (no `--auto` at create — see
README § PR authoring).

**Deferred / follow-on:** per-capability enrollment and `approved_digest` pins remain WF1 operator
actions; lifting specific ids (e.g. AWA) is independent of this ADR. Status may move to
`accepted` once this prose lands and operators confirm no alternate writer paths remain in
practice.
