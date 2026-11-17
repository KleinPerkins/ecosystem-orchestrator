# ecosystem-orchestrator

Cross-workspace **ecosystem orchestrator** (reorg-v2 + the capability-lifecycle paradigm).
This is the **single place** the relationship between the personal/home workspace (ld) and the governed
downstream consumer (cpp = `Affirm/card-platform-product`) is defined (**INV-zero-link**): no ld artifact
and no cpp artifact names the other side; only this repo does. It also owns narrow per-consumer shims
such as the google-kit pointer for chaos-labs, so those routes are configured here rather than by hand.

Two contained workflows with a hard boundary — a registration change never auto-triggers a sync:

- **WF1 — registration + enforcement.** Maintain a trustworthy registry of global capabilities and the
  active layer that keeps it honest. Decoupled from delivery.
- **WF2 — independent sync to cpp.** Read the registry and propagate enabled enrolled capabilities into
  cpp's data plane via ONE governed auto-merge PR per run (ADR 0002).

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
| `cpp-sync` | DRY-RUN: preflight every enrolled id, build the ONE combined change locally, report what that PR would contain |
| `cpp-sync --execute` | open ONE cpp PR with every vendor + delete-propagation change and the matching manifest update (auto-merge on green) |
| `vendor [--execute] <id>` | one enrolled capability, same preflight as `cpp-sync`: its payload + its manifest row in one PR |
| `delete [--execute] <id>` | remove one orchestrator-marked payload: the removal + its manifest row in one PR |
| `rollback [--execute] <id>` | restore `quiver/<cat>/<id>` from `last_synced_cpp_sha` through a governed data-plane PR |
| `quarantine <id> -- <reason>` | close in-flight orchestrator PRs, mark excluded, remove the payload + its manifest row in one PR |
| `chaos-shim-sync [--execute]` | write/repair the configured chaos-labs google-kit pointer/env shim; dry-run by default |

**One PR per run (ADR 0002).** Related capability changes ship together: one `cpp-sync --execute`
produces a single cpp PR (branch `orchestrator/vendor/sync-<timestamp>`) holding every changed
payload, every removal, and the manifest, so cpp never sees a capability without its manifest row or
a manifest row without its files. A run with nothing to change opens nothing. `--execute` refuses
while any orchestrator PR is still open in cpp (they all rewrite the manifest): let it merge, or close
it, then re-run.

`enabled_kinds` (in `config/relationship.yml`) gates which kinds are cpp-vendorable.
Preflight = WF1 `lockkit check` (incl. each capability repo's verifier, e.g. `verify-skills`) + `reconcile` · kind ∈ `enabled_kinds` · translated kind ∈ cpp's live enum and kind==shelf(category) · zero-link
clean per payload · local cpp-integrity GREEN on the combined tree · flavor-2 `approved_digest` matches the current shared-content digest.
Fail closed: a non-empty block set, or any capability that fails to build or trips zero-link, aborts
the whole run before anything is committed or pushed, and a RED integrity gate refuses the push — a
mixed set never partially ships. `cpp-sync --execute` opens one async auto-merge PR; `last_synced_cpp_sha`
is refreshed only from observed cpp main by `repair`, not by PR creation.

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

**Self-management:** `install` (Cursor `sessionStart` hook + launchd agent), `self-heal`, `zero-link`.

## What do I run when?

| Situation | Run | Where it acts |
| --- | --- | --- |
| Repair the local skill symlinks on LD's machine | `make eco-sync` (in `~/dev`) | ld home tool dirs only |
| Add/remove a global capability to/from the cpp sync set | `orchestrator enroll\|exclude\|demote <id>` | `registry.yml` only (no delivery) |
| Push enrolled capabilities into cpp | `orchestrator cpp-sync --execute` | ld → cpp, one governed PR per run |
| A PM sets up / refreshes their cpp clone | `/cpp-bootstrap` or `/cpp-sync` (in cpp) | the PM's laptop (cpp-owned reconciler) |
| Repair chaos-labs google-kit discovery | `orchestrator chaos-shim-sync --execute` | configured chaos-labs shim files only |

## Layout

```
bin/orchestrator.sh        CLI (verbs above)
lib/registry.sh            read/write config/registry.yml (eco-registry/v1)
lib/selfmanage.sh          install + cpp-sync / per-id vendor preflight, then one vendor.sh call
lib/vendor.sh              the single sanctioned ld->cpp edge writer (ONE PR: payloads + removals + manifest)
lib/manifest.sh            data-plane manifest generator (eco-manifest/v1), staged into vendor.sh's PR
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

Repository CI uses two permanent standard GitHub Actions groups: `registry-discovery` and
`payload-delivery`. Every original shell fixture suite runs exactly once. The first group also
runs source-owned CI, independent-review, PR-origin capture and App-gate regression tests.
The fail-closed `ci-required` aggregate binds both measurements to one exact revision, run,
attempt, workflow and PR base/head tuple. CI uses read-only checkout and disposable fixture
state; it never invokes a real downstream sync. Local checks do not establish hosted success.

The App authenticates the exact Actions producer/run, revision, base/head and bound output.
The contract hash binds the reported inputs; it does not independently attest that candidate
workflow/dispatcher code executed every test. Automatic independent content review examines
those implementations and their test meaning before the exact tuple can be admitted.
Review must reject no-op jobs, omitted suites, fabricated measurements, weakened failure
propagation or tests stripped of meaningful assertions. All 12 substantive shell fixture
suites and the complete assigned Python inventory remain required in actual hosted CI.

The accepted Q07/Q11/Q16 route permits automatic review and App delivery of CI/governance
changes. It adds no human technical reviewer or immutable CI-definition refresh gate.
Local receipt provenance uses the accepted operational trust model; reviewer false negatives
and privileged forgery remain possible. This does not waive meaningful CI. Candidate CI is
an untrusted review subject, and stale/failed/skipped observed evidence continues to refuse.

## PR authoring — two delivery regimes

These are separate delivery regimes. The create-time --auto prohibition applies ONLY to
fleet-governed repos, NEVER to cpp vendoring PRs opened by this orchestrator.

### Regime A — This repository's CI and App delivery

The accepted G1 transition replaces this repository's retired runnerless controller with
meaningful standard hosted CI and Chaos Scheduler App4217367. Historical `.github/pr-*`
markers remain inert retained evidence, not an operational dependency or a reason to restart
the retired controller. This transition changes no other repository's delivery authority.

- The authoring agent automatically captures fresh independent review under the same Codex
  account as PR creation, using a qualified enrolled cloud route when available, otherwise
  the qualified local adapter. A separate creation-origin witness and the unedited review
  receipt bind the account, repository ID1281300995 and exact base/head/policy tuple.
  Repeat review after head, current base or trusted policy changes. Unknown origin or
  unavailable matching review blocks that PR; the operator is not the technical reviewer.
- Use `scripts/local_review.py`, then `scripts/create_review_pr.py`, then publish the unedited
  review receipt prefixed with `<!-- g1-review-receipt:v1 -->`. Open verified work ready.
  The enrolled local creator route requires ARM macOS with executable
  `/opt/homebrew/bin/gh`. Missing/non-executable trusted CLI fails before account access,
  journals or network writes. Linux hosted CI uses fixtures and does not qualify a Linux
  or Intel production creator route. Other creator layouts need separate qualification.
- Only the qualified Chaos Scheduler App approves the exact head and requests native squash
  or eligible native squash auto-merge. Agents never merge, pre-arm or cancel auto-merge,
  bypass checks, weaken protections or manufacture review. Current review, exact CI and
  strict native protections must pass before every App write.
- Initial automation admission is owner/admin-only. PR104 intentionally admitted source
  implementation with the producer registry disabled/empty, separating initial code admission
  from trusted account enrollment. The final bootstrap admits the actual runtime-verified
  WORK producer and this repository's capture/creation/instruction hashes; no foreign producer
  or private account details are copied. It pins App4217367 installation144433991.
- Source enrollment does not activate the App. Preserve control preimages and complete current
  merged-main CI, successor controls and read-only trusted-main App qualification before
  setting `REVIEWER_APP_ENABLED=true`. The flag stays OFF through the final bootstrap.
  That completes initial source/producer admission; ordinary changes then use automatic
  originating-account review and App-only native squash, without human technical review.
- Q16 local receipts are operational trust, not provider attestation or anti-forgery proof.
  The accepted concurrent-writer race remains: another privileged actor can arm auto-merge
  between the final null read and App approval. App-only delivery is an authorization rule,
  not atomic exclusion of other writers; observed prearmed or unknown state still refuses.

### Regime B — Cpp data-plane / WF2 / Decision B

Applies to `Affirm/card-platform-product` PRs opened by `lib/vendor.sh` (payloads, removals, and the
`lib/manifest.sh` manifest update, always together in one PR).

- **`--auto --squash` at PR create IS correct.** Decision B: routine landing relies on cpp's
  server-side required checks plus `@affirm-cpp-bot` CODEOWNER auto-approval
  (`cpp-auto-approve.yml`) — not the fleet reviewer App.
- **Gate:** local cpp-integrity must be GREEN before push; auto-merge waits for cpp's own checks
  and bot approval.

Historical G4 runnerless proof remains in Git history; it does not qualify current CI/App delivery.
