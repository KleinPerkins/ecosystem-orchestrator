---
{"approval":{"actor":"Laurence Duggan","date":"2026-11-06","review_sha256":"fabac1ef0a07ed64b2c34237c47f3e10113fa517bfca6859b739d0ae50916575"},"authority":"semantic","github_repository_id":1281300995,"id":"ADR-fad1df46-7dd3-5029-97f7-abc2643a0dfa-901673f6-bea3-56cb-8b23-20c2e7e4f8f2","lifecycle":"approved","mutability":"frozen_after_approval","provenance":[],"relations":[],"repository_key":"fad1df46-7dd3-5029-97f7-abc2643a0dfa","schema":"doc-warden/artifact/v2","supersedes":null,"type":"adr","version":1}
---
# ADR 0003: Agent-route downstream deferral

## Decision

Accept D1-A for the ecosystem discovery extraction and agent-route replacement retrofit: make no downstream payload, manifest, or registry changes in this task. Defer ecosystem-search and ecosystem-index downstream enrollment and any agent-route replacement or removal until their owners approve the corresponding recipient contract and delivery operation.

Preserve the global source scope of the new search skill and index tool. “Local for now” describes distribution, not a change to `scope: local`, exclusion, or registry demotion. Existing agent-route registry enrollment remains unchanged. This decision creates no version pin or hold and suspends no other sync. Any later agent-route refresh, removal, or broad sync carrying the changed source requires a new explicit D1 decision and the normal owner delivery gates.

The existing downstream agent-route payload remains a legacy deployment awaiting its own replacement or removal decision. Its source existence, enrollment, or client manifest does not establish runtime health, native qualification, or support for the new product.

## Why

Source delivery and downstream package acceptance are separate milestones. The source-backed index and its consumers require an explicitly approved portable package and recipient runtime contract before downstream enrollment. This no-change disposition lets bounded local preparation proceed without treating copied source or existing enrollment as package support.

`config/relationship.yml` remains the sole relationship authority. This ADR records the consumer disposition; it creates no alternate registry, writer, hold mechanism, or sync enforcement code.

## Consequences

- After S4 source delivery, local L1 preparation and separately approved activation may proceed without waiting for downstream rollout. Installation, primary-source promotion, managed-link changes, and native canaries still require their exact host-operation approval and applicable qualification evidence.
- Preserve shared legacy consumers and their dependencies until their exact host operation is approved. Do not silently invert the accepted S4 → L1 → L2 order. L2 retirement remains dependent on source delivery, qualified L1, and the verified shared-consumer disposition; curated inputs and unrelated settings remain protected.
- Packaging portability and writer-authority corrections remain separately scoped follow-ups. They are not prerequisites for this zero-delta disposition and are not authorized by it.
- This record grants no downstream enrollment, exclusion, demotion, replacement, removal, installation, automatic sync, or recipient implementation authority. A future changed distribution requires the relevant owner decisions and verified owner delivery.
- Canonical publication and verified merge complete this D1 record's delivery. They do not establish L1 qualification, L2 retirement, downstream rollout, or completion of the whole retrofit.

## Authority

This disposition implements D1 of the accepted Skills execution plan `PLAN-f7571d74-f495-5461-ae37-ed0e227347d5-2ad7b541-b2e5-59de-b7b0-8b72ee2c8d6a` v1 and ADR 0012, delivered by Skills PR #259 at `540ce90cfddc687687f4188a167e9c6cb6fe76e0`. Skills PR #260 delivered the source retrofit at `84bb2a8205edddd6ad12c719fc9e8fa558417659`; that source merge alone grants no installation or distribution authority.
