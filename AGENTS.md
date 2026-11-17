# ecosystem-orchestrator

This repository is the single sanctioned bridge between the home workspace (ld) and Affirm's
governed `card-platform-product` repo (cpp). Agents and operators use it to maintain the global
capability enrollment registry (WF1), run health and consistency checks, and deliver ld-agnostic
payloads into cpp's data plane via governed PRs (WF2). Do not hand-vendor into cpp, edit cpp's
control plane (`_ops/`, `.github/`), or duplicate relationship facts elsewhere — invoke
`bin/orchestrator.sh` verbs and treat `config/relationship.yml` as the ld↔cpp relationship
source of truth. PRs **in this repo** follow Regime A (automatic originating-account independent review,
exact hosted CI and Chaos Scheduler App-only native squash; agents never merge or arm auto-merge); cpp
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

## Repository CI and delivery

The accepted G1 transition supersedes this repository's obsolete runnerless controller policy.
Use the two fixture-only GitHub Actions groups and exact-run `ci-required` aggregate. Preserve
all real relationship/registry/lockkit values and held work. CI never reconciles a real consumer.
Automatically obtain fresh independent originating-account review with `scripts/local_review.py`,
then create the ready PR with `scripts/create_review_pr.py` and publish its unedited review receipt
prefixed with `<!-- g1-review-receipt:v1 -->`. Prefer an enrolled same-account cloud route when
available; otherwise use the qualified local adapter. Repeat after head/base/trusted policy changes.
The operator is not the technical reviewer. Initial owner-only admission, merged-main CI,
qualified enrollment, App readiness and control cutover precede activation. Agents cannot manually
merge, manipulate native auto-merge, bypass checks or restart the retired controller.
Only Chaos Scheduler App4217367 owns ordinary approval and native squash delivery. The accepted
local-receipt trust and concurrent-writer limitations remain; source preparation is not activation.

Independent review must examine workflow, dispatcher, suite inventory, assertion meaning and
failure propagation whenever CI/tests/governance change. Reject no-op or omitted verification,
fabricated measurements and weakened failure handling. The App authenticates exact Actions
run/producer/revision/output binding; the contract hash is not independent test-execution
attestation. Required meaningful full-suite hosted execution remains mandatory. Accepted
Q07/Q11/Q16 permits reviewed automatic CI/governance changes without a human technical
reviewer, blanket trusted-main CI byte pin or new owner-only CI-refresh gate. Preserve this
operational trust boundary and report its limits honestly.

The qualified local creator host is ARM macOS with executable `/opt/homebrew/bin/gh`.
The creator preflight must refuse clearly before any writes when that trusted binary is
absent. Hosted Linux adapter tests use fixtures; they do not enroll a production creator
on Linux, Intel macOS or another executable layout. Do not infer such portability.
