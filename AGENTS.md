# ecosystem-orchestrator

This repository is the single sanctioned bridge between the home workspace (ld) and Affirm's
governed `card-platform-product` repo (cpp). Agents and operators use it to maintain the global
capability enrollment registry (WF1), run health and consistency checks, and deliver ld-agnostic
payloads into cpp's data plane via governed PRs (WF2). Do not hand-vendor into cpp, edit cpp's
control plane (`_ops/`, `.github/`), or duplicate relationship facts elsewhere — invoke
`bin/orchestrator.sh` verbs and treat `config/relationship.yml` as the ld↔cpp relationship
source of truth. PRs **in this repo** follow Regime A (plain open, no auto-merge at create); cpp
PRs opened by `lib/vendor.sh` follow Regime B (README § PR authoring). Each orchestrator run ships as
ONE cpp PR carrying its payloads, removals, and manifest update together (ADR 0002).

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
