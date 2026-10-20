# Architecture Decision Records (ADRs)

This directory contains Architecture Decision Records for `ecosystem-orchestrator`.

**Governance:** `~/dev/_ops/doc-warden/POLICY.md` §2 (taxonomy), §9 (archival).
ADRs are **byte-identical-forever** once their Status line reads `accepted` — no in-place edits
after acceptance, not even a status-bullet edit. Supersession is recorded only via a new ADR's
`Supersedes:` pointer and this index file's row update.

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| 0001-single-sanctioned-cpp-edge-writer.md | single sanctioned cpp edge writer | DRAFT | 2026-08-06 |
| 0002-one-combined-cpp-pr-per-sync.md | one combined cpp PR per sync run | DRAFT | 2026-10-20 |
| <!-- TODO: doc-warden will populate rows here via repair --> | | | |

## Conventions

Format (Nygard):
```markdown
# ADR <NNNN>: <title>
Status: <draft|accepted|superseded> — <date>

## Decision
## Why
## Consequences
```

- Numbering: 4-digit zero-padded sequential (`0001`, `0002`, …)
- Filename: `<NNNN>-<slug>.md`
- Status values: `draft` → `accepted` → `superseded`
- `Supersedes: ADR-NNNN` line added to the new ADR; old ADR is never modified
- The index row for a superseded ADR is updated to `superseded — <date>` (this index is mutable;
  the ADR file itself is not)
