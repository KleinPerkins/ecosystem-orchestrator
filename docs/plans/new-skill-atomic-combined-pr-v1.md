# New-skill atomic vendor — one combined payload + manifest PR

**Version:** v1
**Status:** DRAFT
**Date:** 2026-08-24
**Owning repository:** `KleinPerkins/ecosystem-orchestrator` (`~/dev/personal/ecosystem-orchestrator`)
**Owner:** Orchestrator/CPP owners; LD operator
**Plan-type:** standard
**Program milestone:** Post–Context Efficiency Release 2 follow-up, filed at C-03 closure.
**Authority:** [`KleinPerkins/dev` Context Efficiency Release 2 closure plan](https://github.com/KleinPerkins/dev/blob/main/_ops/plans/context-efficiency-release2-closure-v1.md); [ADR 0001 — single sanctioned cpp-edge writer](../adr/0001-single-sanctioned-cpp-edge-writer.md)
**Baseline:** orchestrator `origin/main` `14726ed31e2fa9bd3a508adcdcf7b8a67ec78674`; CPP `origin/main` `9f32215c0325b84fcf0325d0efe859fe858438e3`
**Motivating incident:** the first brand-new-skill vendor (`save-game`) split into payload PR #737 + manifest PR #738 in CPP; neither could merge independently without breaking CPP `main`, and it took a manual combined PR (#740) to land safely.

This DRAFT is planning-only. It authorizes no orchestrator code, `cpp-sync`, `vendor`, registry, lock, or client-projection mutation. Implementation is a separate governed orchestrator PR after this plan is `ACCEPTED`.

**Changelog**
- v1 (2026-08-24) — Establish the follow-up to make brand-new-skill vendoring emit ONE atomic payload + manifest CPP PR.

## 1. Problem

When the orchestrator vendors a capability into CPP it produces Regime B PR(s). Today `cpp-sync` / `vendor` for a **brand-new** skill (one not previously in the CPP capability manifest) can emit **two** PRs:

1. a **payload** PR (the vendored `SKILL.md` + files under the skill's CPP path), and
2. a **manifest** PR (regenerating `eco-capability-manifest.yml` to add the new `owned_id` + `item`).

For a brand-new skill these two are **mutually dependent** and neither is independently safe:

- **Manifest-first, payload-absent:** the CPP reconciler (`eco-capability-reconcile.sh`) sees a manifest entry whose payload is not fully present on disk, trips `SKILL_MUTATION_READY=0`, and **skips ALL ecosystem skill link operations** — a fleet-wide degradation, not a local one.
- **Payload-first, manifest-absent:** the payload lands but no manifest entry exists, so the reconciler never links it and CPP idempotency / bootstrap counts drift (the `save-game` split broke `test_bootstrap_idempotency.sh` until its expected link total was derived dynamically).

The split therefore has **no safe independent merge order** for a brand-new skill; only a hand-assembled combined PR lands cleanly. Every prior skill (e.g. `claude-api`) landed as a single combined PR precisely because it co-changed payload + manifest atomically.

## 2. Desired behavior

For a **brand-new** skill (no existing CPP manifest `owned_id`), `orchestrator cpp-sync --execute` and `orchestrator vendor <id>` MUST emit **exactly one** Regime B CPP PR containing **both** the vendored payload **and** the regenerated manifest, so the PR is atomic and CPP `main` is never left in the degraded in-between state.

For an **existing** skill (payload refresh / re-pin with no manifest-membership change), current behavior is unchanged: a payload-only PR is safe because the manifest entry already exists.

## 3. Acceptance criteria

- **A0.** `vendor <new-id>` and `cpp-sync --execute` (when the sync set includes ≥1 brand-new id) produce a single CPP PR whose diff includes both the payload files and the manifest regeneration for that id.
- **A1.** A payload-only or manifest-only PR is never opened for a brand-new id.
- **A2.** Existing-id payload refreshes remain single payload PRs (no manifest churn), unchanged from today.
- **A3.** A regression test asserts the combined-PR shape for a synthetic brand-new id (fails against the pre-fix split behavior).
- **A4.** The `SKILL_MUTATION_READY` degradation window is unreachable for a brand-new vendor by construction (the manifest entry and its payload always land in the same PR).
- **A5.** Zero-link, lockkit parity, and `consistency` proofs remain green.

## 4. Out of scope

- How **existing**-skill payload refreshes are batched.
- Any change to the CPP-owned reconciler / bootstrap (this is orchestrator-side PR assembly only).
- Multi-skill batching policy beyond "a sync set containing a brand-new id lands that id's payload + manifest together."

## 5. Notes

Filed as the Context Efficiency Release 2 C-03 tracked follow-up. It is **not** required for Release 2 closure — the `save-game` vendor already landed safely via the manual combined PR #740. This plan hardens the path so future brand-new-skill vendors are atomic and safe by construction, closing the gap between the orchestrator's automated PR-splitting and the atomic co-landing every prior skill relied on.
