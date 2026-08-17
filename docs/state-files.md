# DR build run state (the blackboard)

Run artifacts for the agentic DR build (ARCHITECTURE §9). The Workflow script has no filesystem
access, so these are written by the committed helper scripts (`../lint.sh`, `../reconcile.mjs`,
`../resolve.mjs`) run via the thin exec agent (§16.13), and by the `/dr-build` skill in the main loop.

## Files

| File | Committed? | Writer | Purpose |
| ---- | ---------- | ------ | ------- |
| `build-plan.md` | **yes** | skill (Phase 1, main loop) | The §8.1 preflight plan: will-create · won't-create · manual-work. Authorized at the build-plan gate before any Builder is spawned. |
| `blackboard.md` | **yes** | `resolve.mjs` | Unresolved cross-component values (`needed_by · what · source · via · status`) the Orchestrator works down. |
| `dependency-graph.md` | **yes** | `resolve.mjs` | The DAG edges, the tiered apply order, and the cycle report. |
| `run-report.md` | **yes** | `resolve.mjs` | The actual outcome: pinned SHA, in-scope list, built / blocked, open residue, aggregated prerequisites. |
| `status.json` | no (git-ignored) | skill / Orchestrator | Live per-component run status — transient. |
| `manifests/` | no (git-ignored) | Builders + lint exec agent | Per-component manifest + lint/reconcile result; run intermediates feeding `resolve.mjs`. **Every manifest present joins the graph** — see below. |
| `build.lock` | no (git-ignored) | skill | Advisory lock (§16.11) so two engineers don't both start a fan-out; TFC's per-workspace state lock is the real safety backstop. |

The durable four are committed so a failover survives a dead laptop — any platform engineer can resume
the tiered apply from committed state + TFC state (§8 "resumability", §16.3).

## `manifests/` persists on purpose, and that cuts both ways

`resolve.mjs` assembles the DAG from **every** manifest in the directory, not from the components one
Workflow invocation happened to build. That is what makes a partial re-run work: re-invoke the
Workflow for the single root that failed, and the graph still comes out whole because the other
manifests are still there (§8 resumability).

The cost of that design is that a manifest outlives the run that wrote it. If scope changed — a root
was dropped from `scope-rules.md`, renamed, or deleted from the source estate — its stale manifest is
still read, joins the apply order, and reaches the emitted pipeline, with nothing reporting it.

**So on a fresh run, reconcile `manifests/` against the approved `build-plan.md` and delete anything
the plan does not list.** On a resume, leave it alone. This is a step the skill takes in the main
loop, not something the engine can decide for itself: only the plan knows which set is intended.

## Advisory lock (§16.11)

Before fanning out, the skill checks `build.lock`; if absent it writes one (engineer + pinned SHA +
mode), and removes it when the run hands off or completes. Advisory only — it coordinates humans and
hands over cleanly on a dead laptop; it does not gate the cloud (TFC state locks do that).
