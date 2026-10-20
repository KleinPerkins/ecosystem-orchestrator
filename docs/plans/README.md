# Plans

This directory contains multi-session plans for `ecosystem-orchestrator`.

**Governance:** `~/dev/_ops/doc-warden/POLICY.md` §2 (taxonomy), §9 (archival).
Plans are **byte-identical-forever** once their Status line reads `ACCEPTED` — no in-place edits
after approval. A revision is a new `{{slug}}-v2.md` with a `Supersedes:` pointer; the prior
version is never modified.

## Index

| Plan | Status | Date | Notes |
|---|---|---|---|
| [Context Efficiency D-04 — Global capability projection reconciliation](context-efficiency-d04-projection-reconciliation-v1.md) | ACCEPTED | 2026-08-22 | Release 1.1 final lane; accepted planning authority. Execution gated by separate flavor-2 approval (Gate B) and cpp-sync (Gate C) GOs. |
| [New-skill atomic vendor — one combined payload + manifest PR](../archive/plans/new-skill-atomic-combined-pr-v1.md) | SUPERSEDED | 2026-08-24 | Never accepted; absorbed by [ADR 0002](../adr/0002-one-combined-cpp-pr-per-sync.md) (2026-10-20), which makes every orchestrator cpp delivery ONE combined PR, not only brand-new skills. Archived. |

## Conventions

- Filename: `<slug>-vN.md` where `N` starts at `1`
- Status values: `DRAFT` → `ACCEPTED` → `SUPERSEDED` (tracked in the index row, NOT in the plan file itself after acceptance)
- A new version (`-v2`, `-v3`, …) is created when a material revision is needed post-acceptance; the prior version is immutable
- Draft plans may be edited in place before acceptance; accepted plans may not

## Archive

Superseded and retired plans that are no longer active but preserved for history live in
`docs/archive/plans/` (moved via `git mv`, not deleted).
