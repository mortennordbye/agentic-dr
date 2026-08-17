---
name: dry-run
description: >-
  Regenerate the Phase-2 disaster-recovery Terraform estate from current main and check it —
  generate + invariant-lint + reconcile + validate, plus the platform/core GitOps overlay, with an
  optional gated plan-only drift check (ARCHITECTURE.md Mode 1). Never applies. Enforces the hard
  rule: NEVER trigger a pipeline (even plan_only) without explicit user approval. Use when asked to
  dry-run, rehearse, test, drift-check or just generate the DR estate without touching cloud.
---

# /agentic-dr:dry-run — generate and check the DR estate (Mode 1)

Regenerates the DR estate from current `main` and proves it holds together, **without ever applying
anything**. This is the mode to run constantly: it is cheap, it is the drift baseline, and it is what
must be trusted before `/agentic-dr:failover` is ever reached.

**Plugin root:** `${CLAUDE_PLUGIN_ROOT}` — this line is substituted, so that is a real absolute path.
Use it wherever the procedure below writes `<plugin-root>`.

## Procedure

1. **Run Phases 1–3** exactly as written in `${CLAUDE_PLUGIN_ROOT}/docs/build-procedure.md` — read it
   now, in full. It holds the golden rules, Phase-1 discovery and the build-plan approval gate, the
   Workflow fan-out, and the GitOps residue you own. Everything there applies here unchanged.
2. **Then stop, or escalate to a gated drift check.** Generation + lint/reconcile/validate is a
   complete Mode-1 run; you may end there. If the engineer wants a drift check against real cloud
   state: **[GATE]** ask before `gh workflow run <DR pipeline> -f plan_only=true ...`, then run it in
   dependency order, as far as a cold region allows (cold plan-only is partial by design, §6.3).
3. **No apply, ever.** `plan_only=false` is not a Mode-1 outcome. If the run reveals something that
   needs applying, that is a `/agentic-dr:failover` decision the engineer makes deliberately.

## What is different from a failover

- **GitOps sentinels stay unresolved.** The overlay + `state/gitops-report.md` *are* the artifact —
  review the diff (`git diff --no-index <source_dir> <target_dir>`). `__DR_POST_APPLY__*` values do
  not exist until the producing roots apply, so do not deploy this overlay and do not hand-fill them.
  The failover skill carries the sentinel gate; here their presence is expected.
- **The PR is the baseline, not a deployment.** Committing the generated roots + state files is what
  makes the *next* run's diff meaningful (ARCHITECTURE §16.2).

Report as described in `docs/build-procedure.md` — the pinned SHA, in-scope list, built vs blocked,
open blackboard items and cycles, the manual-work checklist, and the PR link. Say plainly that
nothing was applied.
