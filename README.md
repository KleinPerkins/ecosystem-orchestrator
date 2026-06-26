# ecosystem-orchestrator

Private cross-workspace **ecosystem orchestrator** (reorg-v2). This is the **single place** the
relationship between the personal/home workspace (ld) and the governed downstream consumer workspace
(cpp = `Affirm/card-platform-product`) is defined (**INV-zero-link**). No ld artifact and no cpp
artifact names the other side; only this repo does.

## What it does

- **Vendors** an ld-agnostic, self-sufficient copy of a global capability (a `global/<id>` skill or an
  mcp) into the cpp **quiver** via an **LD-authored governed PR** (squash auto-merge; admin-merge per
  cpp's control-plane flow; never direct-push), with full discoverability integration.
- **Propagates deletes** the same way (a governed deletion PR that removes the vendored copy + its
  index/ownership/alias entries) when a global capability is retired from its master.
- **Dedups** on LD's machine by replacing the cpp vendored copy with a symlink to the master (teammates
  keep a real copy).
- **Enforces zero-link** on every payload (`forbidden-cpp.txt` / `forbidden-ld.txt`).
- **Installs/sync/self-heals itself** (ORCH-C) and fires from triggers (session-start hook, launchd,
  Actions-on-push).

## Layout

```
bin/orchestrator.sh        CLI: vendor | delete | sync | self-heal | install | zero-link | doctor
lib/common.sh              shared helpers (config reader, logging, out-of-tree backup)
config/relationship.yml    THE ld<->cpp relationship (sources, cpp target, quiver, branch, merge mode)
config/forbidden-cpp.txt   tokens that reveal cpp (forbidden in an ld/global payload)
config/forbidden-ld.txt    tokens that reveal ld (forbidden in a cpp payload)
```

## Safety

Laptop is the only PR author/committer (holds creds). GitHub Actions are signal/validation only and
never hold secrets. cpp control plane (`_ops/`, `.github/`) is never touched; only `quiver/` is written.
Born-compliant: LOCAL noreply identity + identity-guard/data-guard/session-lock pre-commit hooks.
