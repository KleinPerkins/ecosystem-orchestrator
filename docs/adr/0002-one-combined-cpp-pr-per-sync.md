# ADR 0002: one combined cpp PR per sync run
Status: draft — 2026-10-20

## Decision

Every orchestrator delivery to cpp ships as ONE pull request. `cpp-sync --execute` puts every
vendored capability, every removal, and the matching `eco-capability-manifest.yml` update into a
single commit on one branch. Per-id `vendor <id>` and `delete <id>` ship that one capability's files
together with its own manifest row. If any capability in the run fails preflight, payload build, or
zero-link, or the combined tree fails cpp integrity, nothing is pushed. `lib/manifest.sh` becomes a
stage-only generator that can no longer open a PR of its own.

## Why

On 2026-10-20 the per-capability PR shape broke cpp twice. Each payload PR and the separate manifest
PR auto-merged independently; cpp requires branches to be up to date with main and its checks take
about 26 minutes, so landing order was effectively random:

- cpp #1055 (swarm) merged at 10:30Z and #1054 (subagent-orchestration) at 11:43Z. The new swarm
  accepts only the v2 `model-tiers.json` that subagent-orchestration ships, so `/swarm` in cpp was
  broken for 1h13m.
- For the algorithmic-art removal, #1061 deleted the files and #1062 updated the manifest. cpp's
  reconciler skips every skill install when the manifest lists an active skill whose files are
  missing, so #1061 failed cpp's swarm-reconciliation test until #1062 landed; landing first would
  have made every PM's `/cpp-sync` skip all installs in the gap.

The 2026-08-24 draft plan `new-skill-atomic-combined-pr-v1` covered only brand-new skills; these
incidents show refreshes of existing capabilities and removals carry the same hazard.

Alternatives considered:

- **Keep per-capability PRs and add ordering or dependency metadata.** Rejected: it needs a
  dependency graph someone must maintain, and it still cannot force order — cpp's auto-merge lands
  whichever PR finishes checks first; strict serialization would cost ~26 minutes per capability.
- **Stack the PRs (each based on the previous).** Rejected: cpp is squash-only with auto-deleted
  head branches, which breaks stacked bases, and it is still N × 26 minutes.
- **Hand-assemble a combined PR when needed (what cpp #740 did for save-game).** Rejected:
  hand-vendoring is forbidden (ADR 0001).
- **Chosen: one combined PR.** One squash commit moves cpp main from one consistent state to the
  next, so atomicity holds by construction with no grouping metadata. Checked against cpp's rules
  (read-only, 2026-10-20): Laurence is a code owner of every path, the `cpp-auto-approve` workflow has
  no file-count or path-count limit for LD-authored PRs, `_ops/POLICY.md` requires only squash-only
  merges plus the required checks, and cpp's sync runbook already describes the data-plane change as
  "a governed quiver PR".

## Consequences

**What changes.**

- `lib/vendor.sh` is the only code that opens cpp PRs. `--sync` (used by `cpp-sync`) vendors the
  preflight-clean set, removes every other orchestrator-marked (`VENDORED.md`) payload computed
  against the freshly fetched cpp tree, and regenerates the manifest — one branch, one commit, one
  integrity run on the combined tree, one PR. Per-id mode changes one capability plus only its own
  manifest row; every other row is carried unchanged.
- Per-id `vendor <id>` can now activate a capability (its manifest row ships with it), so it runs the
  same preflight as `cpp-sync` first: lockkit check (incl. `verify-skills`), registry reconcile,
  enrolled state, `enabled_kinds`, and the flavor-2 `approved_digest` check.
- Removal touches only orchestrator-marked payloads and never the fixed tooling ids; a payload
  removed in the same change keeps its `owned_ids` tombstone (read from the base commit).
- **Fail closed.** A capability that cannot be built or trips zero-link aborts the whole run before
  anything is committed. A RED integrity gate refuses the push; any failing integrity check is RED
  (previously a tool exiting 2, as `make` does, was misread as "could not run").
- **Naming.** Branches: `orchestrator/vendor/sync-<timestamp>` for `cpp-sync`; per-id keeps
  `orchestrator/vendor/<id>-<timestamp>` and `orchestrator/vendor/rm-<id>-<timestamp>`. Titles:
  `feat(quiver): orchestrator sync (vendor: a, b; remove: c)` (counts only when that exceeds 120
  characters); per-id titles are unchanged. The PR body lists every vendored and removed capability
  and whether the manifest changed.
- **Idempotency and open PRs.** A run with no changes against cpp main is a no-op and opens nothing.
  `--execute` refuses while ANY orchestrator PR is open in cpp — including legacy per-capability PRs —
  because every orchestrator PR rewrites the shared manifest; if the open-PR list cannot be read, it
  also refuses. Wait for the open PR to merge (or close it), then re-run. `quarantine` stops the
  line: it closes every in-flight orchestrator PR, then ships the removal as the only PR; the next
  `cpp-sync --execute` re-delivers anything a closed PR carried.
- The status matrix treats an open `sync-*` PR as in flight for every id and points every
  payload/manifest mismatch at `cpp-sync --execute`.

**Enables.** cpp main never lists an active capability whose files are missing, never keeps an
active row for a removed payload, and receives co-dependent capability updates together. cpp runs its
checks once per sync instead of once per capability.

**Forecloses.** Landing one capability of a run independently of the others: one broken capability
holds the whole run until it is fixed or `exclude`d. Concurrent orchestrator PRs.

**Must remain true.** Every preflight and gate that existed before stays in force: lockkit check
(incl. each capability repo's verifier), registry reconcile, `enabled_kinds`, the cpp kind enum,
flavor-2 digest approval, zero-link per payload, the control-plane path guard, local cpp integrity
before push, and Regime B landing (native auto-merge on green; no admin bypass on the routine path).

**Follow-ups.** cpp's own runbook (`_ops/runbooks/eco-capability-sync.md`) still says the manifest
"can land before the payload"; that is now stale guidance and can be corrected in a cpp-governed PR
whenever convenient. The manifest's generated header comment is corrected here, so the next sync
carries a one-time comment-only manifest update. This decision absorbs the draft plan
`new-skill-atomic-combined-pr-v1`, now marked superseded in the plans index.
