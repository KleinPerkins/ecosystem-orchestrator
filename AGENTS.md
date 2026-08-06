# ecosystem-orchestrator

<!-- TODO: author — one paragraph summarizing this repository's role for agents and operators -->

## Structural routing (reconstructed skeleton — not semantic prose)

| Concern | Location |
|---|---|
| Enrollment SoT | `config/registry.yml` |
| ld↔cpp relationship (**INV-zero-link**) | `config/relationship.yml` |
| Sanctioned cpp data-plane writer | `lib/vendor.sh`, `lib/manifest.sh` |
| Plans index | `docs/plans/README.md` |
| ADR index | `docs/adr/README.md` |

**Cross-repo authority:** `~/dev/OPERATING-MANUAL.md` §10h (when in-repo docs disagree with §10, §10 wins)

<!-- doc-warden:begin -->
## Documentation governance

This repo's documentation structure is governed by `doc-warden`.

| Artifact type | Location |
|---|---|
| Plans | `docs/plans/` — index at `docs/plans/README.md` |
| ADRs | `docs/adr/` — index at `docs/adr/README.md` |
| Runbooks | `docs/runbooks/` |
| Glossary | `docs/GLOSSARY.md` (created when genuine terminology ambiguity arises) |

**Policy:** `~/dev/_ops/doc-warden/POLICY.md`
**Engine:** `~/dev/_ops/bin/doc-warden.sh check ecosystem-orchestrator` (read-only health check)
<!-- doc-warden:end -->
