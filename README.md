# ecosystem-orchestrator

Private cross-workspace **ecosystem orchestrator** (reorg-v2 + the capability-lifecycle paradigm).
This is the **single place** the relationship between the personal/home workspace (ld) and the governed
downstream consumer (cpp = `Affirm/card-platform-product`) is defined (**INV-zero-link**): no ld artifact
and no cpp artifact names the other side; only this repo does.

Two contained workflows with a hard boundary — a registration change never auto-triggers a sync:

- **WF1 — registration + enforcement.** Maintain a trustworthy registry of global capabilities and the
  active layer that keeps it honest. Decoupled from delivery.
- **WF2 — independent sync to cpp (Phase 1 = skill + mcp).** Read the registry and propagate enrolled
  capabilities into cpp's data plane via governed auto-merge PRs.

Canonical end-state doc: `~/dev/OPERATING-MANUAL.md` §10h. The cpp-side mechanics live under cpp
governance (`_ops/bin/eco-capability-reconcile.sh`, `_ops/runbooks/eco-capability-sync.md`).

## Command contract (`bin/orchestrator.sh <verb>`)

**WF1 — enrollment (mutate `config/registry.yml`, the sole enrollment SoT):**

| Verb | What it does |
| --- | --- |
| `enroll <id> -- <reason>` | mark a global capability `state: enrolled` (eligible for `cpp-sync`) |
| `exclude <id> -- <reason>` | mark `state: excluded` (a later `cpp-sync` delete-propagates any cpp payload) |
| `demote <id> -- <reason>` | mark `state: demoted` (global→local; delete-propagates from cpp) |
| `status` | per-id registry state + cpp presence (plain view) |
| `reconcile` | **authority** check: committed `.eco-registry.lock` vs `registry.yml` (registry wins) |
| `doctor` | read-only health: registry presence, enrollment-drift, lock parity, WF2 auto-merge preconditions |
| `consistency [<id>]` | master ↔ cpp-payload byte-equality (Decision-A compensating control) |

*Rename = `exclude old` → `enroll new` → `cpp-sync` (delete old payload + vendor new).*
*`rollback` / `quarantine` / `status --matrix` are **follow-on-plan scope** — not implemented here.*

**WF2 — sync to cpp:**

| Verb | What it does |
| --- | --- |
| `cpp-sync` | DRY-RUN: preflight every enrolled id, report the vendor/delete/manifest plan |
| `cpp-sync --execute` | vendor the ok set → delete-propagate de-enrolled → ONE atomic manifest PR (auto-merge on green) |

`enabled_kinds` (in `config/relationship.yml`) gates which kinds are cpp-vendorable (Phase 1 = `skill mcp`).
Preflight = kind ∈ `enabled_kinds` · translated kind ∈ cpp's live enum and kind==shelf(category) · zero-link
clean · local cpp-integrity GREEN · `preflight_supply_chain` (no-op stub, follow-on). A non-empty block set
aborts before any push.

**Self-management:** `install` (Cursor `sessionStart` hook + launchd agent), `self-heal`, `vendor` /
`delete` (the per-id edge primitives `cpp-sync` calls), `zero-link`.

## What do I run when?

| Situation | Run | Where it acts |
| --- | --- | --- |
| Repair the local skill symlinks on LD's machine | `make eco-sync` (in `~/dev`) | ld home tool dirs only |
| Add/remove a global capability to/from the cpp sync set | `orchestrator enroll\|exclude\|demote <id>` | `registry.yml` only (no delivery) |
| Push enrolled capabilities into cpp | `orchestrator cpp-sync --execute` | ld → cpp governed PRs |
| A PM sets up / refreshes their cpp clone | `/cpp-bootstrap` or `/cpp-sync` (in cpp) | the PM's laptop (cpp-owned reconciler) |

## Layout

```
bin/orchestrator.sh        CLI (verbs above)
lib/registry.sh            read/write config/registry.yml (eco-registry/v1)
lib/selfmanage.sh          install + cpp-sync (preflight, vendor, delete-propagate, manifest)
lib/vendor.sh              the single sanctioned ld->cpp edge writer (per-id payload PR)
lib/manifest.sh            the one atomic data-plane manifest PR (eco-manifest/v1)
lib/payload.sh             payload generators (shared by vendor + consistency + manifest)
lib/consistency.sh         master <-> cpp payload byte-equality (Decision-A control)
lib/reconcile.sh           orchestrator-side registry<->lock authority
config/registry.yml        enrollment SoT (eco-registry/v1)
config/relationship.yml    THE ld<->cpp relationship (sources, cpp target, enabled_kinds, denylist)
config/forbidden-*.txt     zero-link token definitions
```

## Safety

The laptop is the only PR author/committer (holds creds). GitHub Actions are signal/validation only and
never hold secrets. The cpp **control** plane (`_ops/`, `.github/`) is never touched by the orchestrator;
only the cpp **data** plane (`quiver/<cat>/<id>` payloads + the one manifest file) is written. Delete-
propagation is bounded to orchestrator-owned payloads (the `VENDORED.md` marker) minus a denylist. Born-
compliant: LOCAL noreply identity + identity-guard / data-guard / session-lock pre-commit hooks.
