# ecosystem-orchestrator

Private cross-workspace **ecosystem orchestrator** (reorg-v2 + the capability-lifecycle paradigm).
This is the **single place** the relationship between the personal/home workspace (ld) and the governed
downstream consumer (cpp = `Affirm/card-platform-product`) is defined (**INV-zero-link**): no ld artifact
and no cpp artifact names the other side; only this repo does. It also owns narrow per-consumer shims
such as the google-kit pointer for chaos-labs, so those routes are configured here rather than by hand.

Two contained workflows with a hard boundary — a registration change never auto-triggers a sync:

- **WF1 — registration + enforcement.** Maintain a trustworthy registry of global capabilities and the
  active layer that keeps it honest. Decoupled from delivery.
- **WF2 — independent sync to cpp.** Read the registry and propagate enabled enrolled capabilities into
  cpp's data plane via governed auto-merge PRs.

Canonical end-state doc: `~/dev/OPERATING-MANUAL.md` §10h. The cpp-side mechanics live under cpp
governance (`_ops/bin/eco-capability-reconcile.sh`, `_ops/runbooks/eco-capability-sync.md`).

## Command contract (`bin/orchestrator.sh <verb>`)

**WF1 — enrollment (mutate `config/registry.yml`, the sole enrollment SoT):**

| Verb | What it does |
| --- | --- |
| `enroll <id> -- <reason>` | mark a global capability `state: enrolled` (eligible for `cpp-sync`) |
| `exclude <id> -- <reason>` | mark `state: excluded` (a later `cpp-sync` delete-propagates any cpp payload) |
| `demote <id> -- <reason>` | mark `state: demoted` (global→local; delete-propagates from cpp) |
| `approve <id>` | compute the current shared-content digest and pin `approved_digest` for flavor-2 sync |
| `status` | per-id registry state + cpp presence (plain view) |
| `status --matrix [--json]` | live matrix: registry, lock, digest approval, cpp payload/manifest, open PR, journal, next action |
| `repair` | run doctor/self-heal, refresh derivable journal fields from observed cpp main, then print the matrix |
| `reconcile` | **authority** check: committed `.eco-registry.lock` vs `registry.yml` (registry wins) |
| `lockkit check|write|diff [target...]` | verify or propagate the shared metadata-lock normalizer to capability repos |
| `doctor` | read-only health: registry presence, enrollment-drift, lock parity, WF2 auto-merge preconditions |
| `consistency [<id>]` | master ↔ cpp-payload byte-equality (Decision-A compensating control) |

*Rename = `exclude old` → `enroll new` → `cpp-sync` (delete old payload + vendor new).*
*Registry journal fields are a cache. `.eco-registry.lock` remains normalized `meta.yml` parity only; status and
repair label malformed or stale journal state instead of treating it as authority.*

**WF2 — sync to cpp:**

| Verb | What it does |
| --- | --- |
| `cpp-sync` | DRY-RUN: preflight every enrolled id, report the vendor/delete/manifest plan |
| `cpp-sync --execute` | vendor the ok set → delete-propagate de-enrolled → ONE atomic manifest PR (auto-merge on green) |
| `rollback [--execute] <id>` | restore `quiver/<cat>/<id>` from `last_synced_cpp_sha` through a governed data-plane PR |
| `quarantine <id> -- <reason>` | close in-flight per-id/manifest PRs, mark excluded, delete-propagate, regenerate manifest |
| `chaos-shim-sync [--execute]` | write/repair the configured chaos-labs google-kit pointer/env shim; dry-run by default |

`enabled_kinds` (in `config/relationship.yml`) gates which kinds are cpp-vendorable.
Preflight = WF1 `lockkit check` + `reconcile` · kind ∈ `enabled_kinds` · translated kind ∈ cpp's live enum and kind==shelf(category) · zero-link
clean · local cpp-integrity GREEN · flavor-2 `approved_digest` matches the current shared-content digest.
A non-empty block set aborts before any push, so a mixed approved/blocked enrolled set never partially opens
payload PRs. `cpp-sync --execute` opens async auto-merge PRs; `last_synced_cpp_sha` is refreshed only from
observed cpp main by `repair`, not by PR creation.

The manifest keeps active delivery and prune ownership separate: `items` is exactly the current
preflight-clean active set, while `owned_ids` is the sorted union of active ids, fixed orchestrator
tooling, currently marked (`VENDORED.md`) cpp payloads, and the prior manifest's active/owned ids.
Removed ownership remains as a historical tombstone: cpp laptops have no acknowledgement channel and
may sync arbitrarily late, so automatic expiry would recreate dangling links. The namespace is bounded
to fixed tooling, marked payloads, and ids this writer previously emitted as active or owned;
cpp-native and foreign-quiver ids are never inferred. Payloads and links are eventually deleted while
their non-operative ownership tombstones keep late prune safe.

The cpp reconciler is table-driven for the Phase-2 routing set: `skill` directory links to all tools,
`mcp` is record-first, `sub-agent` links `<id>.md` into agent homes, `rule` links `<id>.mdc` into Cursor
rules only, and `tool` is record-only. `rule sub-agent tool` are enabled after cpp PR #170 merged green.
For `google-kit`, the mcp payload is still source-free but now includes a small suite overlay:
`SUITE.md`, a blank document-style starter template, a local bootstrap script, and guard-pattern docs.
It deliberately excludes personal profile JSON; real `doc-styles/` remain local config.

**Self-management:** `install` (Cursor `sessionStart` hook + launchd agent), `self-heal`, `vendor` /
`delete` (the per-id edge primitives `cpp-sync` calls), `zero-link`.

## What do I run when?

| Situation | Run | Where it acts |
| --- | --- | --- |
| Repair the local skill symlinks on LD's machine | `make eco-sync` (in `~/dev`) | ld home tool dirs only |
| Add/remove a global capability to/from the cpp sync set | `orchestrator enroll\|exclude\|demote <id>` | `registry.yml` only (no delivery) |
| Push enrolled capabilities into cpp | `orchestrator cpp-sync --execute` | ld → cpp governed PRs |
| A PM sets up / refreshes their cpp clone | `/cpp-bootstrap` or `/cpp-sync` (in cpp) | the PM's laptop (cpp-owned reconciler) |
| Repair chaos-labs google-kit discovery | `orchestrator chaos-shim-sync --execute` | configured chaos-labs shim files only |

## Layout

```
bin/orchestrator.sh        CLI (verbs above)
lib/registry.sh            read/write config/registry.yml (eco-registry/v1)
lib/selfmanage.sh          install + cpp-sync (preflight, vendor, delete-propagate, manifest)
lib/vendor.sh              the single sanctioned ld->cpp edge writer (per-id payload PR)
lib/manifest.sh            the one atomic data-plane manifest PR (eco-manifest/v1)
lib/status.sh              status matrix and JSON output
lib/recovery.sh            rollback and quarantine recovery verbs
lib/chaos_shim.sh          google-kit pointer/env shim delivery for chaos-labs
lib/payload.sh             payload generators (shared by vendor + consistency + manifest)
lib/consistency.sh         master <-> cpp payload byte-equality (Decision-A control)
lib/reconcile.sh           orchestrator-side registry<->lock authority
lib/lockkit.sh             shared eco-lock normalizer propagation/check/diff
config/registry.yml        enrollment SoT (eco-registry/v1)
config/relationship.yml    THE ld<->cpp relationship (sources, cpp target, enabled_kinds, denylist)
config/lockkit.yml         eco-lock master/target inventory (no cpp target)
config/forbidden-*.txt     zero-link token definitions
templates/eco-lock/        master copy of the self-contained consumer lock writer
```

## Safety

The laptop is the only PR author/committer (holds creds). GitHub Actions are signal/validation only and
never hold secrets. The cpp **control** plane (`_ops/`, `.github/`) is never touched by the orchestrator;
only the cpp **data** plane (`quiver/<cat>/<id>` payloads + the one manifest file) is written. Delete-
propagation is bounded to orchestrator-owned payloads (the `VENDORED.md` marker) minus a denylist;
downstream link prune additionally requires the id in manifest `owned_ids`. Born-compliant: LOCAL
noreply identity + identity-guard / data-guard / session-lock pre-commit hooks.

Pull requests are protected by runnerless v3 verification.

G4 informational proof evidence: the runnerless recipe now exercises the shell regression wrapper
and fails when the shared payload helper invariant is broken.

## PR authoring — two delivery regimes

These are separate delivery regimes. The create-time --auto prohibition applies ONLY to
fleet-governed repos, NEVER to cpp vendoring PRs opened by this orchestrator.

### Regime A — Fleet-governed repos

Applies to repos gated by `pr-automation / verify`: `KleinPerkins/skills`, this orchestrator,
and eligible KleinPerkins fleet repos.

- **Never arm auto-merge at PR create.** Enabling `gh pr merge --auto` before the required Check
  has registered drives the PR into an unreconcilable pending state (it never runs) and deadlocks
  the PR.
- **Correct sequence:** open a plain PR with **no** auto-merge → let `pr-automation / verify` run
  and pass → merge via the reviewer App or operator action (the reviewer App may arm native squash
  auto-merge only after the Check is green).
- Protected paths (`.github`, `CODEOWNERS`) stay owner-approval-only and are never auto-approved.

### Regime B — Cpp data-plane / WF2 / Decision B

Applies to `Affirm/card-platform-product` vendoring PRs opened by `lib/vendor.sh` and manifest PRs
from `lib/manifest.sh`.

- **`--auto --squash` at PR create IS correct.** Decision B: routine landing relies on cpp's
  server-side required checks plus `@affirm-cpp-bot` CODEOWNER auto-approval
  (`cpp-auto-approve.yml`) — not the fleet reviewer App.
- **Gate:** local cpp-integrity must be GREEN before push; auto-merge waits for cpp's own checks
  and bot approval.

G4 requiredness proof evidence: this head restores `lib/payload.sh` byte-for-byte after the
deliberate failure seed and proves `repo.ecosystem-orchestrator.m3-verify` permits merge.
