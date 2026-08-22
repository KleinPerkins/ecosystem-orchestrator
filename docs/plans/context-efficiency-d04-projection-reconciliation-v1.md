# Context Efficiency D-04 — Global capability projection reconciliation

**Version:** v1
**Status:** ACCEPTED — 2026-08-22
**Date:** 2026-08-22
**Owning repository:** `KleinPerkins/ecosystem-orchestrator` (`~/dev/personal/ecosystem-orchestrator`)
**Owner:** Skills/orchestrator/CPP owners; LD operator
**Plan-type:** standard
**Program milestone:** D-04, “Reconcile global capability projections only through the standard lifecycle.”
**Authority:** [`KleinPerkins/dev` Context Efficiency Program v2, Release 1.1 / D-04](https://github.com/KleinPerkins/dev/blob/618da97572a6cca9fb48ed10c2f724a893e74d1c/_ops/plans/context-efficiency-program-v2.md#release-11--reduce-capability-discovery); [ADR 0001](../adr/0001-single-sanctioned-cpp-edge-writer.md); `~/dev/OPERATING-MANUAL.md` §10h
**Baseline:** Skills `origin/main` `f5a028b1e2a53e46496ea4818b003ca872ac23a8`; CPP `origin/main` `247cd170b4c179d2157894e170bb404c7a2452a4`; orchestrator `origin/main` `10ebdecc784efc255f902966bd1654b581aac92d`
**Review provenance:** Grounded against freshly fetched owner refs, D-01 evidence, merged D-02/D-03 implementations, origin-blob comparisons, the live registry/status matrix, lockkit checks, full payload consistency, zero-link checks, and current CLI implementation. Bugbot review is required before operator acceptance.

This DRAFT is planning-only. It authorizes no `approve`, `cpp-sync`, registry, lock, Skills, CPP, client-projection, or rollback mutation. Plan acceptance, flavor-2 supply-chain approval, and cpp-sync execution are separate named operator gates.

**Changelog**
- v1 (2026-08-22) — Define the final Release 1.1 reconciliation lane, bind the 13 D-02-stale CPP payloads and eight flavor-2 re-pins, and fail closed on live preflight drift outside that set.

## 1. Purpose and boundary

D-02 reduced 14 global Skills descriptions and one local plugin-governor description. Thirteen of the changed global skills are enrolled and vendored into CPP. Their Skills `origin/main` `SKILL.md` blobs are now newer than the corresponding CPP `origin/main` blobs.

D-04 reconciles those 13 projections only through the existing capability lifecycle:

1. WF1 re-pins the eight changed flavor-2 payload digests after explicit supply-chain approval.
2. WF2 uses one authorized `orchestrator cpp-sync --execute` invocation to deliver the current owner payloads through the orchestrator's governed CPP Regime B path.
3. Read-only proofs establish lockkit parity, owner-source-to-CPP consistency, client projection parity, and INV-zero-link.

`KleinPerkins/ecosystem-orchestrator` remains the single sanctioned ld→CPP edge writer. Skills and CPP never name or write each other directly. CPP keeps real vendored copies; `orchestrator consistency` proves parity instead of replacing them with symlinks.

## 2. Authority, prerequisites, and live-verified state

### 2.1 Exact authority binding

| Authority | Exact live ref | Result |
|---|---|---|
| Dev program | Dev `origin/main` `618da97572a6cca9fb48ed10c2f724a893e74d1c`; program-plan blob `d452a49a1f4e0eac579947a9a853637138966706` | D-04 is the final Release 1.1 lane and follows `D-01 → D-02 + D-03 → D-04`. |
| D-01 evidence | `_ops/evidence/context-efficiency/capability-discovery-inventory-v1.json` blob `f1aef037b70ef6f2c03b31d03c73efdf73525b0f` | `capability-discovery-inventory/v1`, `PASS`, 248 rows, 28 Skills-eligible rows, and 35 CPP-eligible rows. |
| D-02 | Skills `origin/main` `f5a028b1e2a53e46496ea4818b003ca872ac23a8` | Merged implementation; 14 global skill descriptions plus one local plugin-governor description changed. |
| D-03 | CPP `origin/main` `247cd170b4c179d2157894e170bb404c7a2452a4` | Merged M2A implementation; 12 CPP-native quiver descriptions changed and CPP control-plane skills became project-scoped. |
| Edge writer | Orchestrator `origin/main` `10ebdecc784efc255f902966bd1654b581aac92d` | Current CLI, registry, relationship, lockkit, consistency, and Regime A/B contracts. |

These are authoring pins, not permission to trust stale refs later. Every implementation session fetches all owner remotes first. If an `origin/main` advances, the executor inspects the complete delta and continues only when ownership, file maps, gates, and lifecycle behavior remain materially unchanged; otherwise this plan is superseded before mutation.

### 2.2 Origin-first authoring verification

The canonical Skills checkout rejected a direct fetch because it is a guarded primary tree, so authoring used a fresh disposable read-only clone for the remote comparison. CPP, Dev, and orchestrator were fetched in place; all comparisons used `origin/main:<path>` blobs, never working-tree payload files.

```bash
git clone --no-checkout --single-branch --branch main \
  git@github.com:KleinPerkins/skills.git \
  /tmp/context-efficiency-d04-skills-verify-20260822071942
git -C /tmp/context-efficiency-d04-skills-verify-20260822071942 \
  switch --detach origin/main
git -C ~/dev/affirm/src/card-platform-product fetch --prune origin main
git -C ~/dev/personal/ecosystem-orchestrator fetch --prune origin main
git -C ~/dev fetch --prune origin main

git -C /tmp/context-efficiency-d04-skills-verify-20260822071942 \
  diff --name-status \
  f78b9c4f6aa211a07a06cc5e92e63ee9a2ca5f01..\
f5a028b1e2a53e46496ea4818b003ca872ac23a8
git -C ~/dev/affirm/src/card-platform-product \
  diff-tree --no-commit-id --name-status -r \
  247cd170b4c179d2157894e170bb404c7a2452a4
```

A content-safe Python probe loaded `parse_frontmatter` and `normalize_description` from the freshly fetched Skills `origin/main` implementation, read each side with `git show origin/main:<path>`, and printed only IDs, blob short-hashes, normalized character counts, flavor, approval state, and registry state. No description text was printed or persisted.

Observed authoring result:

```text
Skills origin/main:       f5a028b1e2a53e46496ea4818b003ca872ac23a8
Skills canonical HEAD:    f78b9c4f6aa211a07a06cc5e92e63ee9a2ca5f01
CPP origin/main:          247cd170b4c179d2157894e170bb404c7a2452a4
orchestrator origin/main: 10ebdecc784efc255f902966bd1654b581aac92d
D-02 changed descriptors: 14 global + 1 local
D-04 drifted descriptors: 13
Flavor-2 re-pins:         8
```

### 2.3 Exact 13-payload D-04 set

Git blob IDs are content-addressed and comparable across repositories. Every row below is `state: enrolled`, is present in CPP, and has unequal Skills/CPP `SKILL.md` blobs.

| ID | Skills `origin/main` blob / chars | CPP `origin/main` blob / chars | Flavor | Approval state | Registry state |
|---|---:|---:|---:|---|---|
| `agent-route` | `9ce2237f384e` / 292 | `b4b9fe57e91f` / 654 | 1 | not required | enrolled |
| `algorithmic-art` | `9b842a794349` / 227 | `634f6fa42e4e` / 324 | 2 | re-pin required | enrolled |
| `capability` | `3b447c94079f` / 285 | `f0a5c3e7d1b5` / 727 | 1 | not required | enrolled |
| `claude-api` | `de191ca480d7` / 268 | `494e282c892b` / 1,068 | 2 | re-pin required | enrolled |
| `doc-coauthoring` | `723e22b97b5b` / 250 | `a5a69839ef4a` / 428 | 2 | re-pin required | enrolled |
| `internal-comms` | `eb2de200f08d` / 209 | `56ea935b74f3` / 329 | 2 | re-pin required | enrolled |
| `pdf` | `19651e277aeb` / 233 | `d3e046a5ae10` / 437 | 2 | re-pin required | enrolled |
| `plan-refine` | `c55e927cec3f` / 290 | `b158cb77990c` / 1,060 | 1 | not required | enrolled |
| `pr-steward` | `d661b9a305a7` / 299 | `4a7a40830d7c` / 898 | 1 | not required | enrolled |
| `prompt-architect` | `fc812d722502` / 256 | `6a7bb8e04e79` / 534 | 2 | re-pin required | enrolled |
| `skill-creator` | `0f297e4ff937` / 245 | `65b3a402dbd0` / 319 | 2 | re-pin required | enrolled |
| `swarm` | `83111c048dee` / 295 | `d6e994e11b75` / 625 | 1 | not required | enrolled |
| `xlsx` | `b97bad87fa2f` / 300 | `a4159256803b` / 948 | 2 | re-pin required | enrolled |

The 13 normalized descriptions total 3,449 characters in Skills and 8,351 characters in CPP. D-04 changes no wording; those values are parity targets inherited from D-02.

The eight flavor-2 IDs are exactly:

```text
algorithmic-art
claude-api
doc-coauthoring
internal-comms
pdf
prompt-architect
skill-creator
xlsx
```

Recomputing each current payload digest from the fresh Skills ref showed all eight `approved_digest` pins drifted. `orchestrator status --matrix --json` reported `approval_state=drifted` and `next_action=approve` for those eight; the other five reported `approval_state=not-required`.

### 2.4 Correctly excluded D-02 changes

| ID | Skills origin evidence | Why excluded from D-04 |
|---|---|---|
| `save-game` | Global blob `d5afa00bc65c`; 296 characters | Absent from `config/registry.yml` and absent from `cpp/quiver/skills/save-game`; D-04 does not enroll it. |
| `continual-learning` | Local blob `2a9c508e5826`; 300 characters | `local/plugins/continual-learning`; local scope is never WF1-enrolled or CPP-vendored. |

“Excluded” here means excluded from the D-04 projection set, not necessarily registry `state: excluded`.

### 2.5 Lockkit parity is legitimately green

The lock normalizer hashes canonical fields from each capability's `meta.yml`; it is not a `SKILL.md` payload-content lock. D-02 changed descriptions only, so unchanged lock bytes are expected.

```bash
bash /tmp/context-efficiency-d04-skills-verify-20260822071942/.github/scripts/eco-lock.sh check
# eco-lock: OK (.eco-registry.lock in parity)

bin/orchestrator.sh lockkit check skills
# exit 0; verify-skills: OK (global + local + lock + capability-local)
```

The first command used the fresh Skills `origin/main` checkout. The second used the configured canonical Skills checkout and also proved lockkit normalizer parity. No `write` verb ran.

### 2.6 Mandatory stale-local-source precondition

The orchestrator reads `source_skills_local: ~/dev/capabilities/skills`, not a remote Git object. That canonical checkout is clean but stale:

```text
local HEAD/main: f78b9c4f6aa211a07a06cc5e92e63ee9a2ca5f01
local origin/main: f5a028b1e2a53e46496ea4818b003ca872ac23a8
HEAD...origin/main: 0 ahead, 2 behind
origin/main ancestor of HEAD: no
HEAD ancestor of origin/main: yes
```

Running `orchestrator consistency` before this fast-forward is invalid D-04 evidence: the stale source made eleven changed descriptions appear clean. M0 must first advance the canonical Skills checkout by an ordinary governed fast-forward, then prove `HEAD == origin/main`. Pointing `relationship.yml` at a temporary clone or worktree is not an authorized substitute.

### 2.7 Registry comment discrepancy

`config/registry.yml` has a stale header comment describing `agent-route` as not meaningful as a CPP copy. The live item says `state: enrolled`, `orchestrator status` reports `agent-route enrolled vendored`, and the CPP payload exists. Live registry state and status are authoritative. D-04 does not edit the comment; every implementation preflight must query status rather than infer state from prose.

### 2.8 D-03 non-interference

D-03 changed these 12 CPP-native quiver descriptions:

```text
affirm-brand
council
cpp-onboard
feature-explainer-video
natprd
notion-notes-to-doc
quickhost
quickhost-example
quiver-field-guide
regenerable-asset
team-intro-email
upward-comms-review
```

Their intersection with the 13 D-04 IDs is empty. D-03 did not edit any orchestrator-marked delegated payload, `VENDORED.md`, eco manifest, or eco reconciler.

### 2.9 Live preflight deltas that currently block M2

The 13-description set and eight flavor-2 set match the expected D-04 debt exactly. Full live lifecycle checks exposed additional state that the descriptor-only comparison did not:

1. Against fresh Skills `origin/main`, `orchestrator consistency` reports non-description drift inside two D-04 payloads: five additional `agent-route` files and `swarm/tests/test_bootstrap.sh`. These bytes predate D-02 and would travel with full-payload re-vendoring. They require explicit review as part of the cpp-sync GO; D-04 must not imply it ships descriptions only.
2. The full enrolled-fleet consistency run also reports unrelated drift for `local-jobs` and `subagent-orchestration`. Because `cpp-sync` is registry-wide, M2 would not be limited to the 13 D-04 IDs while those remain drifted. D-04 does not absorb them; they must reach parity through their owner lane before cpp-sync GO.
3. Full consistency reports pre-existing enrollment warnings for global `save-game`, `verification-before-completion`, and `snow-kit` being absent from the registry. D-04 records but does not enroll, exclude, or demote them.
4. `orchestrator zero-link global` passes 12 of the 13 fresh masters but currently rejects `skill-creator` because `eval-viewer/generate_review.py` contains the ordinary file-extension literal `.cpp`. Skills' own zero-link regex deliberately excludes dot-prefixed file extensions, while the orchestrator regex does not. This blocks current cpp-sync preflight. D-04 does not change either scanner; the owning lifecycle must resolve the disagreement before cpp-sync GO.
5. All 13 current CPP payloads pass `orchestrator zero-link cpp`.

These are M0 stop conditions, not reasons to widen D-04. Plan acceptance may precede their resolution; execution may not.

### 2.10 Exact authoring command ledger

The following content-safe commands produced §§2.3–2.9 after the fetch/clone commands in §2.2:

```bash
SKILLS_VERIFY=/tmp/context-efficiency-d04-skills-verify-20260822071942
SKILLS_LOCAL="$HOME/dev/capabilities/skills"
CPP_ROOT="$HOME/dev/affirm/src/card-platform-product"
ORCH_ROOT="$HOME/dev/personal/ecosystem-orchestrator"

git -C "$SKILLS_LOCAL" rev-parse HEAD main origin/main
git -C "$SKILLS_LOCAL" rev-list --left-right --count HEAD...origin/main
git -C "$CPP_ROOT" rev-parse HEAD main origin/main
git -C "$ORCH_ROOT" rev-parse origin/main

python3 - "$SKILLS_VERIFY" "$CPP_ROOT" <<'PY'
import importlib.util
import subprocess
import sys
from pathlib import Path

skills, cpp = map(Path, sys.argv[1:3])
ids = """
agent-route algorithmic-art capability claude-api doc-coauthoring
internal-comms pdf plan-refine pr-steward prompt-architect
skill-creator swarm xlsx
""".split()
spec = importlib.util.spec_from_file_location(
    "inventory", skills / "scripts/skill-description-inventory.py"
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def git(root, *args, binary=False):
    value = subprocess.check_output(["git", "-C", str(root), *args])
    return value if binary else value.decode().strip()

for skill_id in ids:
    source = f"global/skills/{skill_id}/SKILL.md"
    target = f"quiver/skills/{skill_id}/SKILL.md"
    values = []
    for root, path in ((skills, source), (cpp, target)):
        raw = git(root, "show", f"origin/main:{path}", binary=True)
        parsed = module.parse_frontmatter(raw, path)
        chars = len(module.normalize_description(parsed["description"]))
        blob = git(root, "rev-parse", f"origin/main:{path}")[:12]
        values.extend((blob, chars))
    print(skill_id, *values)
PY

cd "$ORCH_ROOT"
. ./lib/common.sh
. ./lib/registry.sh
. ./lib/payload.sh
for id in \
  agent-route algorithmic-art capability claude-api doc-coauthoring \
  internal-comms pdf plan-refine pr-steward prompt-architect \
  skill-creator swarm xlsx
do
  current="$(payload_content_digest "$SKILLS_VERIFY/global/skills/$id")"
  approved="$(reg_journal_raw "$id" approved_digest)"
  printf '%s\t%.12s\t%.12s\n' "$id" "$current" "$approved"
done

bin/orchestrator.sh status
bin/orchestrator.sh doctor
bin/orchestrator.sh lockkit check skills
```

For fresh-source `status --matrix` and consistency, authoring generated an ephemeral copy of `config/relationship.yml` with only `source_skills_local` and `source_skills_global` pointed at `SKILLS_VERIFY`, exported it as `ORCH_CONFIG`, ran the commands below, and deleted it in the same shell:

```bash
TMP_RELATIONSHIP="$(mktemp "${TMPDIR:-/tmp}/d04-relationship.XXXXXX")"
trap 'rm -f "$TMP_RELATIONSHIP"' EXIT
awk -v local="$SKILLS_VERIFY" -v global="$SKILLS_VERIFY/global" \
  'BEGIN { FS=OFS=": " }
   $1=="source_skills_local"  { $2=local }
   $1=="source_skills_global" { $2=global }
   { print }' \
  config/relationship.yml >"$TMP_RELATIONSHIP"

ORCH_CONFIG="$TMP_RELATIONSHIP" bin/orchestrator.sh status --matrix --json
ORCH_CONFIG="$TMP_RELATIONSHIP" bin/orchestrator.sh consistency \
  agent-route algorithmic-art capability claude-api doc-coauthoring \
  internal-comms pdf plan-refine pr-steward prompt-architect \
  skill-creator swarm xlsx
ORCH_CONFIG="$TMP_RELATIONSHIP" bin/orchestrator.sh consistency
```

The targeted consistency result contained all 13 `SKILL.md` drifts plus the additional `agent-route`/`swarm` files in §2.9. The full result additionally named `local-jobs`, `subagent-orchestration`, and the three registry omissions. The per-ID zero-link loop was the command in §8.2; it returned 12/13 source passes, 13/13 CPP passes, and the exact `skill-creator` blocker in §2.9.

## 3. Scope and non-goals

### 3.1 In scope after the named gates

- Fast-forward the canonical clean Skills checkout to its freshly fetched `origin/main` before any digest or payload action.
- Re-pin current payload digests for the exact eight flavor-2 IDs through `orchestrator approve <id>`.
- Deliver the exact 13 enrolled payloads through the standard registry-driven `orchestrator cpp-sync --execute` path after unrelated registry-wide drift is absent.
- Let CPP's normal Regime B checks, `@affirm-cpp-bot` CODEOWNER approval, and native auto-squash govern payload/manifest landing.
- Prove lockkit parity, exact owner-source/CPP consistency, client projection parity, CPP control-plane non-interference, and INV-zero-link.
- Record content-safe exact refs, blobs/digests, counts, commands, PR URLs, checks, and results.

### 3.2 Out of scope

- No new enrollment, exclusion, demotion, rename, capability, scope, exposure, kind, or registry item.
- No description edit; D-02 and D-03 own wording.
- No `meta.yml`, generated `.eco-registry.lock`, lock writer, parser, verifier, or normalizer edit.
- No direct or manual CPP vendoring, payload copy, manifest edit, client-link edit, or CPP `_ops/` / `.github/` change.
- No new ADR, router, registry, installer, reconciliation channel, daemon, dependency, performance SLA, or analytics store.
- No changes to non-D-04 IDs. Existing `local-jobs`, `subagent-orchestration`, registry-omission, or zero-link-scanner debt remains in its owner lane.
- No Release 2 client-closure expansion; D-04 proves only the parity needed to close Release 1.1.

## 4. Design and lifecycle mechanism

### 4.1 One existing mechanism per proof

| D-04 proof | Existing mechanism | Pass rule |
|---|---|---|
| Lockkit parity | `bin/orchestrator.sh lockkit check skills` plus Skills `.github/scripts/eco-lock.sh check` | Both exit 0 against the same freshly fetched Skills commit; no generated lock changes. |
| Owner source ↔ CPP payload | Cross-origin blob map plus `bin/orchestrator.sh consistency <13 ids>` | Every expected payload file is byte-equal; no orphan, missing file, or armed symlink. |
| Client projection parity | Re-run accepted D-01 capture/validate flow; run CPP `_ops/bin/cpp-doctor.sh` | The 13 IDs retain identity/exposure/eligibility, report the D-02 counts in §2.3, resolve to current approved bytes, and CPP doctor is healthy. |
| INV-zero-link | `bin/orchestrator.sh zero-link global <master>` and `zero-link cpp <payload>` for each ID | All 26 checks exit 0 with no forbidden-side token. |
| CPP boundary | Exact Regime B PR diffs | Only orchestrator-owned `quiver/<category>/<id>` payloads and the one manifest may change; CPP control-plane paths are absent. |

No proof substitutes for another. Lockkit green does not prove payload bytes. Payload consistency does not prove client exposure. Installed-file presence does not prove client discovery.

### 4.2 WF1: flavor-2 supply-chain re-approval

After M0 is green and the supply-chain approval GO names all eight IDs, run exactly:

```bash
for id in \
  algorithmic-art claude-api doc-coauthoring internal-comms \
  pdf prompt-architect skill-creator xlsx
do
  bin/orchestrator.sh approve "$id"
done
```

`approve` computes current shared-content digests from the canonical Skills checkout and updates only the eight records' approval/journal fields. Review the exact registry diff, commit normally, and open one ordinary orchestrator Regime A DRAFT PR. Do not arm auto-merge. Wait for its required check and governed merge before WF2.

The five flavor-1 IDs need no digest re-pin:

```text
agent-route capability plan-refine pr-steward swarm
```

### 4.3 WF2: one authorized sync invocation, actual Regime B shape

After the merged WF1 commit is refreshed locally and the cpp-sync execution GO is given, invoke only:

```bash
bin/orchestrator.sh cpp-sync --execute
```

Current code does not batch all payloads into one CPP PR. One `cpp-sync --execute` invocation runs `lib/vendor.sh --execute` per eligible ID, then opens one atomic manifest PR. The governed result is therefore one execution cohort of per-ID Regime B payload PRs plus one manifest PR. The executor must record every PR and may not collapse this into a false “single CPP PR” claim.

The executor never manually calls `gh pr merge`, `--auto`, or bot approval. Regime B behavior is internal to the sanctioned orchestrator path; CPP's checks and bot governance decide landing. Partial landing is not completion.

### 4.4 Client projection parity

After every payload PR and the manifest PR are on CPP `origin/main`:

1. refresh CPP and run `_ops/bin/cpp-doctor.sh` read-only;
2. reproduce the accepted D-01 capture/validate process from Dev `origin/main`;
3. filter the resulting content-safe rows to the 13 D-04 IDs;
4. require each normalized count to equal §2.3 and each installed/source digest to resolve to the current approved projection;
5. require ID, exposure, eligibility, and client cohort to remain unchanged except for D-02's reduced description digest/count; and
6. diff all other rows against the accepted D-01 baseline, allowing only separately merged D-03 effects and rejecting any new D-04-caused change.

Do not store raw descriptions or raw client context. Record only canonical catalog digests, installed/source digests, counts, IDs, root classes, and pass/fail.

## 5. Milestones

### M0 — Establish the minimum viable reconciliation preflight

Objective: bind every later action to current owner refs and prove a 13-ID-only lifecycle is possible before mutation.

- Fetch Dev, Skills, orchestrator, and CPP origins.
- Require clean canonical Skills and CPP trees and correct remote identities.
- Fast-forward canonical Skills to `origin/main`; require `HEAD == origin/main` before digest computation.
- Confirm D-02 and D-03 implementation ancestry and re-enumerate the 15 D-02 descriptor changes.
- Re-run the origin-blob verifier and require exactly 13 enrolled/present unequal CPP descriptors plus the two exclusions.
- Run fresh `status --matrix --json`, targeted and full `consistency`, `lockkit check skills`, Skills `eco-lock.sh check`, `doctor`, and per-ID zero-link checks.
- Confirm live `agent-route` enrollment from status, not the stale comment.
- Capture the complete payload-level delta, including non-description files inside the 13 IDs.
- Require no unrelated enrolled payload drift that a registry-wide cpp-sync would propagate.
- Require the current `skill-creator` zero-link preflight blocker resolved through its owner lifecycle.

**Definition of done:** current refs and content-safe evidence support exactly the authorized 13-ID cohort, all preflight blockers are absent, and no production or registry mutation has occurred.

### M1 — Re-pin the eight flavor-2 payloads through WF1

Prerequisites: M0 green and explicit supply-chain approval GO naming all eight IDs.

- Create a fresh governed orchestrator worktree/branch from current `origin/main`.
- Run only the eight `approve` calls in §4.2.
- Prove no state, reason, enrollment, non-target record, relationship, lock, or code change.
- Run repository tests, lockkit checks, doc-warden, diff checks, and Bugbot.
- Open one DRAFT Regime A registry PR, unarmed.
- Wait for the ordinary required check and governed merge; record exact head/merge and changed registry blob.

**Definition of done:** merged registry authority pins the eight exact current payload digests and no WF2 action has run.

### M2 — Re-propagate the 13 payloads through WF2

Prerequisites: merged M1 commit refreshed locally, M0 repeated against current refs, and explicit cpp-sync execution GO.

- Re-run the non-mutating cpp-sync preflight and inspect the complete plan.
- Require no payload diff outside the 13 IDs and no delete-propagation.
- Run one `orchestrator cpp-sync --execute`.
- Record each per-ID Regime B payload PR and the atomic manifest PR.
- Require every PR diff to remain inside CPP's orchestrator-owned data plane.
- Wait for CPP's own checks, bot approval, and native governed merge. Do not manually approve, arm, mark ready, or merge.
- Refresh CPP `origin/main` only after every expected merge is observed.

**Definition of done:** all 13 current owner payloads and the corresponding manifest state are on CPP `origin/main`; no CPP control-plane or non-D-04 payload byte changed.

### M3 — Prove parity and publish the content-safe handoff

Prerequisites: M2 complete on CPP `origin/main`.

- Run targeted `orchestrator consistency` for all 13 IDs and require clean.
- Re-run full consistency and compare with the M0 baseline; D-04 must introduce no new drift.
- Run lockkit and fresh Skills eco-lock checks; require green with unchanged generated lock.
- Run all 26 per-ID INV-zero-link checks; require green.
- Run CPP `_ops/bin/cpp-doctor.sh`; require healthy.
- Re-run and validate the accepted D-01 inventory flow; require §4.4 parity.
- Prove no CPP `_ops/` or `.github/` path, non-target payload, source description, `meta.yml`, or second installer changed.
- Add one content-safe completion record to the D-04 execution handoff: exact owner refs/blobs, registry merge, all CPP PRs/merges/checks, per-ID counts/digests, command exits, client root classes, and rollback refs. Store no description text or private client context.

**Definition of done:** all three D-04 parity proofs and INV-zero-link are green, evidence is durable and content-safe, and Release 1.1 can hand off to Release 2.

## 6. Operator gates

| Gate | Exact authority required | What remains forbidden without it |
|---|---|---|
| A — Plan acceptance | Operator accepts this DRAFT plan through normal plan governance | Any D-04 implementation or reconciliation mutation |
| B — Flavor-2 supply-chain approval GO | Explicit GO naming `algorithmic-art`, `claude-api`, `doc-coauthoring`, `internal-comms`, `pdf`, `prompt-architect`, `skill-creator`, and `xlsx`, bound to the fresh M0 refs/digests | Every `orchestrator approve` call and registry PR |
| C — CPP sync execution GO | Explicit GO bound to the merged M1 registry commit, current Skills/CPP refs, exact dry-run cohort, resolved M0 blockers, and rollback map | `orchestrator cpp-sync --execute` and every CPP delivery side effect |

No gate implies the next one. A changed ref, digest, ID set, payload file map, zero-link result, or unrelated cpp-sync diff revokes the affected GO and returns to M0.

## 7. Acceptance criteria

### 7.1 This planning PR

- Status remains `DRAFT`; the plan is indexed once as DRAFT.
- The diff contains only this plan and `docs/plans/README.md`.
- The authoring baseline uses fetched owner refs and origin blobs.
- Live deltas in §2.9 are disclosed rather than relabeled green.
- Doc-warden, repository tests, `git diff --check`, and Bugbot have no unresolved in-scope finding.
- The PR is DRAFT, unarmed, and unmerged.

### 7.2 Later D-04 completion

- Exactly 13 enrolled payloads in §2.3 are reconciled; no non-D-04 ID changes.
- Exactly eight flavor-2 current digests are re-approved through a merged Regime A registry PR.
- Every expected Regime B payload/manifest PR is merged through CPP's own governed path.
- `orchestrator consistency <13 ids>` is clean against freshly fetched owner/CPP refs.
- Skills `eco-lock.sh check` and orchestrator `lockkit check skills` are green with unchanged generated lock.
- Post-sync D-01 rows report the §2.3 reduced Skills counts and unchanged identity/exposure/eligibility.
- CPP doctor is healthy and client links resolve through the existing manifest/reconciler contract.
- Every source and CPP payload passes INV-zero-link.
- No CPP control-plane byte, manual payload, generated lock, second writer, or second installer appears.
- The completion record names exact commits, blobs/digests, PRs, checks, client evidence, and rollback refs without raw description text.

## 8. Verification commands

### 8.1 Origin/ref and stale-source preflight

```bash
set -euo pipefail
DEV_ROOT="$HOME/dev"
SKILLS_ROOT="$HOME/dev/capabilities/skills"
ORCH_ROOT="$HOME/dev/personal/ecosystem-orchestrator"
CPP_ROOT="$HOME/dev/affirm/src/card-platform-product"

git -C "$DEV_ROOT" fetch --prune origin main
git -C "$SKILLS_ROOT" fetch --prune origin main
git -C "$ORCH_ROOT" fetch --prune origin main
git -C "$CPP_ROOT" fetch --prune origin main

git -C "$DEV_ROOT" remote get-url origin
git -C "$SKILLS_ROOT" remote get-url origin
git -C "$ORCH_ROOT" remote get-url origin
git -C "$CPP_ROOT" remote get-url origin

test -z "$(git -C "$SKILLS_ROOT" status --porcelain=v1)"
test -z "$(git -C "$CPP_ROOT" status --porcelain=v1)"
git -C "$SKILLS_ROOT" rev-list --left-right --count HEAD...origin/main

# Run the workspace's governed worktree/guard entrypoint before this canonical
# source update. If the guard does not authorize the fast-forward, stop.
git -C "$SKILLS_ROOT" merge --ff-only origin/main
test "$(git -C "$SKILLS_ROOT" rev-parse HEAD)" = \
  "$(git -C "$SKILLS_ROOT" rev-parse origin/main)"
```

Do not reset, rebase, force, stash, or repoint `relationship.yml` to make this pass.

### 8.2 Read-only lifecycle proof

Run from a clean current orchestrator worktree:

```bash
bin/orchestrator.sh status --matrix --json
bin/orchestrator.sh doctor
bin/orchestrator.sh lockkit check skills
bash "$SKILLS_ROOT/.github/scripts/eco-lock.sh" check
bin/orchestrator.sh consistency \
  agent-route algorithmic-art capability claude-api doc-coauthoring \
  internal-comms pdf plan-refine pr-steward prompt-architect \
  skill-creator swarm xlsx
bin/orchestrator.sh consistency

for id in \
  agent-route algorithmic-art capability claude-api doc-coauthoring \
  internal-comms pdf plan-refine pr-steward prompt-architect \
  skill-creator swarm xlsx
do
  bin/orchestrator.sh zero-link global "$SKILLS_ROOT/global/skills/$id"
  bin/orchestrator.sh zero-link cpp "$CPP_ROOT/quiver/skills/$id"
done
```

The targeted consistency command must pass after M2. The full command is a scope/differential check: pre-existing out-of-scope warnings are recorded at M0 and may not be silently changed by D-04.

### 8.3 CPP and client proof

```bash
git -C "$CPP_ROOT" fetch --prune origin main
test "$(git -C "$CPP_ROOT" rev-parse HEAD)" = \
  "$(git -C "$CPP_ROOT" rev-parse origin/main)"
bash "$CPP_ROOT/_ops/bin/cpp-doctor.sh"
```

Then run the accepted D-01 `capture` and `validate` commands from Dev `origin/main` with a fresh same-session content-safe client catalog, using the exact owner roots above. The post-D-04 report must print only IDs, path/root classes, digests, counts, exposure, eligibility, and results.

### 8.4 Plan and implementation PR hygiene

```bash
"/Users/laurence.duggan/dev/_ops/bin/doc-warden.sh" check \
  "$(git rev-parse --show-toplevel)"
bash tests/run-tests.sh
git diff --check
git diff --name-status origin/main...HEAD
git status --short --branch
```

The plan PR changed-file set is exactly:

```text
docs/plans/README.md
docs/plans/context-efficiency-d04-projection-reconciliation-v1.md
```

## 9. Rollout and rollback

Roll out only in this order:

1. accept this plan;
2. repeat M0 and resolve every blocker outside D-04;
3. obtain Gate B;
4. create and govern the exact eight-record Regime A approval PR;
5. refresh its merged commit and repeat M0;
6. obtain Gate C;
7. run one `cpp-sync --execute` cohort;
8. wait for every Regime B payload PR and the manifest PR;
9. run M3; and
10. publish the content-safe handoff.

Before M1 merge, rollback is closing the DRAFT registry PR and deleting its branch through normal worktree cleanup. After M1 merge but before WF2, use an ordinary governed revert PR for the exact registry approval commit.

For a landed CPP payload:

1. preview `bin/orchestrator.sh rollback <id>` against the trusted `last_synced_cpp_sha`;
2. obtain the ordinary rollback authorization;
3. execute `bin/orchestrator.sh rollback --execute <id>`;
4. let the resulting CPP Regime B PR pass its own checks and bot gate;
5. restore manifest/client convergence through the standard orchestrator/CPP paths; and
6. rerun consistency, lockkit, zero-link, CPP doctor, and D-01 client parity.

Rollback every landed member of a failed cohort; do not leave a partial projection and call it complete. Never reset, force-push, hand-copy a payload, edit a manifest/lock, or repair client links manually.

## 10. Risks and stop conditions

| Risk | Control / stop |
|---|---|
| Canonical Skills remains at pre-D-02 bytes. | M0 requires governed fast-forward and `HEAD == origin/main` before digest or payload action. |
| A flavor-2 pin still names old content. | Gate B and the eight explicit `approve` calls; any ninth ID or mismatched digest stops. |
| Registry-wide cpp-sync would propagate unrelated drift. | Full consistency and dry-run scope proof must show no out-of-scope change; otherwise stop and resolve through the other owner's lane. |
| Full-payload re-vendoring carries non-description bytes in `agent-route` or `swarm`. | Bind the exact full payload delta to Gate C; do not describe M2 as description-only. |
| `skill-creator` fails the orchestrator zero-link scanner on `.cpp`. | Resolve scanner/source disagreement outside D-04; no cpp-sync while the sanctioned preflight is red. |
| Stale comment is mistaken for enrollment authority. | Use live `status --matrix`; comment never overrides the item record. |
| D-03 native edits are mistaken for delegated debt. | Recompute exact intersection; any overlap or delegated-payload edit stops. |
| Multiple Regime B PRs land partially. | Treat the cohort incomplete until all payloads and manifest are observed on CPP main; rollback landed members on failure. |
| Client cache or installed-file presence hides stale discovery. | Fresh D-01 catalog capture plus CPP doctor; current-chat recognition is not proof. |

Stop immediately on the D-04 charter's exact forbidden conditions:

- manual CPP vendoring;
- generated-lock editing; or
- a second installer channel.

Also stop on dirty/unknown owner roots, stale or materially moved authority, unknown IDs, new enrollment/exclusion/demotion, unexpected payload/control-plane paths, unresolved zero-link failure, red required checks, missing named GO, or inability to prove rollback.

## 11. Zero-context executor pickup

### Repositories and identities

| Role | Path | Remote / identity |
|---|---|---|
| Program and D-01 evidence | `~/dev` | `KleinPerkins/dev`; read-only for D-04 |
| Skills owner source | `~/dev/capabilities/skills` | `KleinPerkins/skills`; canonical source must be current |
| Orchestrator and this plan | `~/dev/personal/ecosystem-orchestrator` | `KleinPerkins/ecosystem-orchestrator`; local `KleinPerkins <49759187+KleinPerkins@users.noreply.github.com>` |
| CPP consumer | `~/dev/affirm/src/card-platform-product` | `Affirm/card-platform-product`; separately governed and excluded from Dev worktree flow |

Before any orchestrator-repo mutation, run:

```bash
cd "$HOME/dev/personal/ecosystem-orchestrator"
"$HOME/dev/_ops/bin/dev-worktree.sh" ensure
```

Follow the printed `move_agent_to_root` instruction. Use one writer per tree, normal hooks, and a fresh branch from current `origin/main`. Never update git config, skip hooks, push to `main`, force-push, mark ready, arm auto-merge, or merge.

### Ordered execution

1. Read this complete plan, the current program D-04 row, `AGENTS.md`, `README.md`, `config/relationship.yml`, `config/registry.yml`, `config/lockkit.yml`, ADR 0001, and each owner repo's policy.
2. Fetch every owner origin and reproduce §2. No working-tree payload comparison is authoritative.
3. Complete M0, including canonical Skills fast-forward, full consistency, and zero-link. Stop if the exact 13-ID-only cohort is not possible.
4. Ask for Gate B using the exact eight IDs and current short digests.
5. After Gate B, run the eight `approve` calls, open the DRAFT Regime A registry PR, run checks/Bugbot, and hold for governed merge.
6. Refresh the exact M1 merge and repeat M0.
7. Ask for Gate C using the complete dry-run plan, full payload file map, expected CPP PR cohort, and rollback refs.
8. After Gate C, run only `bin/orchestrator.sh cpp-sync --execute`; do not call per-ID `vendor` manually.
9. Observe all Regime B PRs through CPP's own path. Do not intervene in merge/approval automation.
10. Complete M3 and publish the content-safe D-04 handoff.

No later step may infer a gate from an earlier approval. If a session ends, the next executor starts again at origin-first M0.
