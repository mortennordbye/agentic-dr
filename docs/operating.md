# Agentic DR build — how to use it

A platform engineer's quickstart. This system **generates** the Phase-2 disaster-recovery Terraform
estate (the network hub, the firewall, and ~all production + connectivity workloads in the DR region)
on demand from current `main`, instead of maintaining a parallel DR pipeline that would drift.

- **What it is / why** → `ARCHITECTURE.md` (the design blueprint, customer-agnostic).
- **What it runs against** → `profile/` (the only per-customer part; contract in `docs/profile-contract.md`).
- **How the agent behaves** → `skills/*/SKILL.md` (one per mode) and `docs/build-procedure.md`
  (the generation phases they share, plus the approval gates).
- **This file** → the operator's quickstart.

## How it runs

Everything runs **inside Claude Code, in this repo, as you** — there is no standalone service or API
token. You open the tool and invoke one skill; it pins the current `main` SHA and builds the whole
estate from that commit.

```
/agentic-dr:dry-run        # Mode 1 — generate + lint/validate (+ optional gated plan-only). No apply.
/agentic-dr:failover       # Mode 2 — generate → gated staged plan → gated staged apply → triage.
/agentic-dr:fix <service>  # Mode 3 — adaptively remediate ONE failing service (region-parity gap).
```

The `agentic-dr:` prefix is the plugin namespace. It applies to the agents too, and it is not
optional: a bare name does not resolve, so it would spawn an agent with no persona.

**Start with `/agentic-dr:dry-run`.** Mode 2 is only ever reached after Mode 1 is trusted, and is triggered by the
customer DR process (`profile/process.md`), never on a hunch.

## The one rule

**No pipeline ever runs without your explicit approval — including `plan_only`.** Every skill stops
and asks before any `gh workflow run`. Apply is doubly gated (you approve per tier, *and* the `dr` GitHub
Environment's required-reviewers approve server-side).

## What happens in a run

1. **Discover & build plan (you review).** It scans the source-root locations `profile/repo-map.md`
   names, drops the `profile/scope-rules.md` exclusions, and writes `<state-dir>/build-plan.md`: what **will** be
   created, what **won't** (and why), and what is **manual work** (prerequisites, data restore,
   cutover). → **You approve, amend scope, or abort at this gate.** Nothing is generated before it.
2. **Fan-out generation (automatic, no cloud).** One Builder per in-scope root writes a DR root into
   the DR output tree; each root is invariant-linted (`lint.sh`) and reconciled
   (`reconcile.mjs`); the dependency DAG + apply order are computed and the DR pipeline job stanzas
   regenerated. Output is committed as a **PR** for review.
3. **Plan / apply (failover only, gated per tier).** You approve each tier; failures are triaged by a
   Plan Validator and routed back to a Builder, the apply order, or Mode 3.

## Where to look afterward (`<state-dir>/`)

| File | What it tells you |
| ---- | ----------------- |
| `build-plan.md` | what the run intended (the thing you approved) |
| `run-report.md` | the actual outcome: pinned SHA, in-scope list, built / blocked, open residue, the prerequisite checklist |
| `dependency-graph.md` | the DAG, the tiered apply order, and any **halted cycles to escalate** |
| `blackboard.md` | cross-component values still unresolved |

The durable four are committed so a failover survives a dead laptop — any engineer can resume the
tiered apply from committed state + TFC state. `status.json`, `manifests/`, and `build.lock` are
transient (git-ignored).

## Before you run (confirm these)

- The out-of-band prerequisites in `profile/prerequisites.md` are in place (TFC workspaces in Local
  exec mode, the `dr` GitHub environment + OIDC secrets, resource-provider registration, quota/zones).
- The judgement calls in `profile/preflight.md` are settled — every unchecked item there is a
  decision the build cannot make for you.

## Files & responsibilities (reference)

The system is split into two kinds of thing. **Agents** are LLM personas — they exercise judgement
(semantic Terraform transformation, failure diagnosis). **Code** is deterministic and runs no LLM —
it computes and checks, *because a deterministic check cannot hallucinate* (ARCHITECTURE §1, §7, §11).
The Orchestrator coordinates agents but is itself code, not an agent.

### Code — deterministic, no LLM (`engine/`, `workflows/`)

| File | Kind | What it does | In → out |
| ---- | ---- | ------------ | -------- |
| `workflows/dr-build.js` | Workflow script (the **Orchestrator**) | The thin control plane. Spawns one Builder per in-scope root, runs the checks + resolver via thin exec agents, holds global run state. *Not an agent* — it coordinates them. | `args = {sha, inScope[], engine, pipeline}` → spawns agents; returns a run summary |
| `lint.sh` | bash | Invariant lint (oracle 1): greps each generated DR root for source-estate leakage and required DR markers. Customer-agnostic; all tokens come from `profile/lint-patterns.txt`. Strips comments first. | `lint.sh <dr-root> [patterns]` → exit 0 pass / 1 fail + report |
| `reconcile.mjs` | node | Second oracle: validates the manifest and enforces *flag-don't-guess* — every deferred value (`status:blackboard`) must have a matching `# DR-DEFER: <what>` sentinel in the HCL, and vice-versa. | `reconcile.mjs <dr-root> <manifest.json>` → exit 0/1 + report |
| `resolve.mjs` | node | Phase-3 resolver: reads all manifests, builds the dependency DAG, halts on cycles (never auto-breaks), computes the tiered apply order, writes the committed state files, and regenerates the managed DR job region in the DR pipeline file (§16.12). | `resolve.mjs --sha <sha> --pipeline <path>` → writes state + pipeline; prints JSON summary |

> The Workflow script has no filesystem access, so it can't run the three scripts directly — it
> spawns a **thin exec agent** whose only job is to `bash`/`node` them (§16.13). The agent is just the
> launcher; the determinism lives in the committed script (§16.14).

### Agents — LLM personas (`agents/`)

| File | Role |
| ---- | ---- |
| `dr-component-builder.md` | Transforms **one** source root → its DR root + a manifest. Spawned once per in-scope root, in parallel. Reads source as immutable; writes only under the DR output tree. |
| `dr-plan-validator.md` | Read-only triage of one `plan`/`apply` failure → a structured verdict the Orchestrator routes (to a Builder, to apply-order, or to a human / Mode 3). |
| `dr-dynamic-remediator.md` | Mode 3: diagnoses one failing service and proposes **invariant-safe** alternatives; on approval, implements a surgical fix. Escalates rather than violate a hard invariant. |

### Skills — the entrypoints (`skills/`)

One per intent, so the invocation says what you want rather than naming a mode.

| Skill | Role |
| ---- | ---- |
| `dry-run/` | `/agentic-dr:dry-run` — Phases 1–3 then stop, or a gated plan-only drift check. Never applies. |
| `failover/` | `/agentic-dr:failover` — Phases 1–3, then the gated staged plan, gated staged apply, triage, and the sentinel gate on the GitOps overlay. |
| `fix/` | `/agentic-dr:fix <service>` — spawns the Dynamic Remediator against one failing service and gates the chosen fix. |
| `update-profile/` | `/agentic-dr:update-profile` — audits and updates `profile/` after the source estate changes. |

`dry-run` and `failover` both run Phases 1–3 from **`docs/build-procedure.md`**, which holds the
golden rules, Phase-1 discovery, the build-plan gate, the Workflow fan-out and the GitOps residue —
one copy, so the shared half cannot drift between them.

### Profile — the per-customer bindings (`profile/`)

The only part that changes per customer; each file documented in **`docs/profile-contract.md`**. In brief:
`context · naming · network · identity · repo-map` (the bindings), `transform-rules · lint-patterns.txt ·
scope-rules · global-services` (the guardrails), `process · prerequisites · preflight · region-gaps`
(the human/operational facts).

### State — run artifacts (`<state-dir>/`)

Written during a run; schemas documented in **`docs/state-files.md`**. Committed durable four:
`build-plan.md · blackboard.md · dependency-graph.md · run-report.md`. Transient (git-ignored):
`status.json · manifests/ · build.lock`.

## Boundaries

The build's job ends at **"infrastructure up and running."** Data restore is the customer's data plane;
**traffic cutover and failback are customer-led routing steps**, never the agent fan-out (ARCHITECTURE
§1, §17). DR cleanup is a future `/agentic-dr:cleanup`.

## Running it for another customer

Install the plugin, then write a `profile/` that satisfies
[`docs/profile-contract.md`](profile-contract.md). Nothing on the blueprint side names a customer,
region, CIDR, identity, or path — all of that lives in the profile, which is what makes the same
blueprint run against a second estate unchanged.
