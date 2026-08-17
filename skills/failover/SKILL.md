---
name: failover
description: >-
  Execute a disaster-recovery failover: regenerate the Phase-2 DR Terraform estate from current main,
  then a gated staged plan, a gated staged apply, triage of failures, and resolution of the GitOps
  POST-APPLY sentinels (ARCHITECTURE.md Mode 2). Triggered by the customer DR process, never on a
  hunch. Enforces the hard rule: NEVER trigger a pipeline (even plan_only) without explicit user
  approval, and apply is approved per tier. Use when asked to fail over or to stand the DR estate up
  for real.
---

# /agentic-dr:failover — stand the DR estate up for real (Mode 2)

Everything `/agentic-dr:dry-run` does, and then the cloud steps it refuses to take: a staged plan, a
staged apply, triage, and the sentinel resolution that lets the DR GitOps controller sync.

**This is triggered by the customer DR process (`profile/process.md`), never on a hunch.** Mode 1 is
reached first and trusted before this is reached at all. If the engineer has not named the DR process
step this run belongs to, ask before doing anything.

**Plugin root:** `${CLAUDE_PLUGIN_ROOT}` — this line is substituted, so that is a real absolute path.
Use it wherever the procedure below writes `<plugin-root>`.

## Procedure

1. **Run Phases 1–3** exactly as written in `${CLAUDE_PLUGIN_ROOT}/docs/build-procedure.md` — read it
   now, in full. It holds the golden rules, Phase-1 discovery and the build-plan approval gate, the
   Workflow fan-out, and the GitOps residue you own. Everything there applies here unchanged.
2. **Then run Phases 4–6 below**, in the main loop, tier by tier, in the order from
   `dependency-graph.md`. The Workflow can't pause for approvals — you carry the gates.

---

## Phase 4–6 — plan / apply / triage (gated)

- **Phase 4 — Plan (staged).** **[GATE]** ask, then `gh workflow run <DR pipeline> -f plan_only=true
  -f components_to_deploy="<this tier>"`. Watch with `gh run watch` / `gh run view`. **Human review of
  each plan is the real semantic gate** — the lint is only a tripwire (§10/§11). A green plan that
  wires the wrong region/subnet is a *failure*.
- **Phase 5 — Triage.** On any plan/apply failure, spawn a **`agentic-dr:dr-plan-validator`** (read-only) with the
  failing component + the `gh run` id. Route its verdict:
  - `route_to: builder` (`name-mismatch`, `module-input-mismatch`, `config-error`) → re-invoke the
    Workflow for that one root (resumable), re-plan.
  - `route_to: orchestrator` (`missing-upstream`) → fix apply order, not code; re-plan the tier.
  - `route_to: human` / `escalate_to_mode3: true` (`quota`, `prereq`, `region-capability`) → surface to
    the engineer; a region-parity / "won't come up" failure goes to **`/agentic-dr:fix <service>`**.
- **Phase 6 — Apply (staged).** **[GATE per tier]** Only after explicit approval, flip
  `plan_only=false` for that tier (the `dr` Environment's required-reviewers gate it again
  server-side). Tier order: hub/firewall → DNS → network-dependent workloads → the rest. After each
  apply, capture post-apply residue (firewall IP, hub IPs) back into `blackboard.md` and advance.
  Once the tiers that produce them are applied, resolve the GitOps `__DR_POST_APPLY__*` sentinels
  from those roots' Terraform outputs (`profile/gitops-rules.md` names the output per slug) into the
  `target_dir`, then **clear the SENTINEL GATE** below and commit, so the DR GitOps controller syncs
  a complete overlay.

**[SENTINEL GATE — the overlay commit].** The `target_dir` must be on `main` (the GitOps controller
syncs manifests from git), and before committing it run `grep -rl '__DR_' <target_dir>` — it **MUST
be empty**. A remaining `__DR_POST_APPLY__*` or `__DR_DECIDE__*` token means an unresolved identity,
resource id or allowlist, and committing it would sync a manifest that fails to authenticate (or
trusts the wrong sources) on the DR cluster. A non-empty result **blocks the commit** until resolved.

Resumability: if a session dies mid-apply, recovery does not depend on it — the committed state files
+ TFC state let any engineer resume the tiered apply (§8, §16.3).

Report as described in `docs/build-procedure.md`, plus which tiers planned/applied, any Validator
verdicts, and any escalations to `/agentic-dr:fix`.
