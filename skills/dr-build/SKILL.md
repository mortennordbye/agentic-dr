---
name: dr-build
description: >-
  Generate and operate the Phase-2 disaster-recovery Terraform estate on demand from current main
  (ARCHITECTURE.md). Routes the three modes — dry-run (generate + lint/validate,
  optional plan-only), failover (generate → gated staged plan → gated staged apply → triage), and
  fix (Mode 3 adaptive remediation of one failing service). Enforces the hard rule: NEVER trigger a
  pipeline (even plan_only) without explicit user approval. Use when asked to build, dry-run, fail
  over, or fix the DR estate.
---

# DR build — generate the Phase-2 DR estate on demand

This skill is the entrypoint to the agentic DR build (blueprint: `ARCHITECTURE.md`). It
*regenerates* the DR estate from current `main` rather than maintaining a parallel pipeline that
would drift. You — the main loop — run the **non-fan-out** work: Phase-1 discovery, the build-plan
gate, and every gated cloud step. The fan-out generation is the committed Workflow
`workflows/dr-build.js`; the deterministic checks/rewrites are the committed scripts
`engine/lint.sh`, `reconcile.mjs`, `resolve.mjs`, `gitops-rewrite.mjs`.

**Agent and skill names carry the `agentic-dr:` prefix.** A plugin's components resolve only by
their scoped name; the bare name does not resolve, and using it would silently spawn a generic agent
with no persona. This is the one naming detail worth being pedantic about.

**Paths in this file are the profile's, not literals.** Every source root, DR output root, pipeline
file, state dir and workspace name below is read from `profile/repo-map.md` at run time. The
convention is that the consuming repo holds `agentic-dr/profile/` and `agentic-dr/state/`.

## Golden rules (read first)

1. **NEVER run `gh workflow run` — including `plan_only=true` — without explicit user approval.**
   Stop and ask every time (CLAUDE.md, ARCHITECTURE §10). This is the line you do not cross on a hunch.
2. **DR estate only.** You read the source roots named in `profile/repo-map.md` as immutable
   truth; you only ever write under the DR output tree and the state dir that file names, and you
   trigger only the DR pipeline it names. Never touch a source root, source workspace, or source pipeline
   (ARCHITECTURE §1). The DR identity has no role on the source subscriptions — but behave as if it
   did anyway.
3. **The customer profile is authoritative.** Every concrete value (regions, CIDRs, names, identity,
   paths, workspace scheme, exclusions) comes from `profile/`, never from memory.
4. **Pin the SHA.** Pin `main`'s commit SHA at invocation and build the whole estate from it
   (ARCHITECTURE §4). Record it in `run-report.md`.
5. **Apply is doubly gated and staged.** Per-tier approval here *and* the `dr` GitHub Environment's
   required-reviewers server-side.

## Modes

| Invocation | Mode | What runs |
| ---------- | ---- | --------- |
| `/agentic-dr:dr-build dry-run` | 1 | Phase 1–3 (generate Terraform + the platform/core GitOps overlay + lint/reconcile/validate); optionally a gated `plan_only=true` drift check. No apply. |
| `/agentic-dr:dr-build failover` | 2 | Phase 1–6: generate → gated staged plan → gated staged apply → triage → resolve GitOps POST-APPLY sentinels. Triggered by the customer DR process (`profile/process.md`), never on a hunch. |
| `/agentic-dr:dr-build fix <service>` | 3 | Adaptive remediation of one failing service (region-parity gap / misbehaving managed service). See "Mode 3" below. |

---

## Phase 1 — discover & build plan (main loop, no cloud)

Do all of this before spawning anything. It is the cheap abort point.

1. **Pin the SHA.** `git rev-parse main` (or the current `main` tip). Use this commit for every read.
2. **Advisory lock (§16.11).** Check `<state-dir>/build.lock`. If present, stop and report who
   holds it. Otherwise write it (engineer, pinned SHA, mode). Remove it when the run hands off to the
   gated phases or completes. Advisory only — TFC state locks are the real backstop.
3. **Discover the in-scope roots (§12).** Read `profile/repo-map.md` (source-root locations, DR
   output tree, TFC scheme, tfvars name), `profile/scope-rules.md` (exclusions), and
   `profile/global-services.md` (buckets). Enumerate every root under the source-root locations
   `repo-map.md` names, then **subtract** the `scope-rules.md` exclusions. For each surviving root
   build `{ component, source_root, target_root, tfc_workspace }` by applying the DR output tree and
   workspace scheme from `repo-map.md`, where `<component>` is the source directory name. Inclusions
   are discovered; only exclusions are pinned.
   **Collision rule (`repo-map.md`):** if two surviving roots share a directory name across source
   tiers, the flat `<component>` would map both to the same DR root — disambiguate **both** by
   prefixing the source tier (`<tier>-<name>`), and derive the target root and workspace from the
   prefixed name. Evaluate this on the discovered folder set **before** exclusions, so dropping one
   twin never collapses the survivor onto the bare name. Apply it deterministically here so the engineer is not
   re-asked at the gate; note the rename in `build-plan.md`.
4. **Write `<state-dir>/build-plan.md`** (§8.1) from a *static read* of the source roots +
   profile — **no Builder spawned, no HCL written**. Three sections:
   - **Will be created** — each in-scope source root → its DR root (name, region, CIDR, workspace),
     grouped by expected tier.
   - **Will NOT be created (and why)** — the `scope-rules.md` exclusions, the pre-staged /
     hand-authored DR roots `repo-map.md` pins (never regenerated), global singletons /
     already-replicated services (`global-services.md`). Empty data-bearing roots go in *will-create*;
     their **data** is manual work.
   - **Will need manual work** — the `profile/prerequisites.md` checklist, the gotchas/decisions in
     `profile/preflight.md` (every unsettled item it lists), the **predicted blackboard residue** (hardcoded principal IDs,
     post-apply IPs, secret refs, `terraform_remote_state` outputs a static scan already shows), known
     region gaps (`profile/region-gaps.md` if present), and the customer-owned data restore + cutover.
5. **[PLAN APPROVAL GATE]** Present `build-plan.md`. The engineer approves as-is, amends scope (regen
   the plan), or aborts. Nothing past here runs without explicit approval. This is a hard sign-off, not
   a notification.
6. **After approval, on a FRESH run only: reconcile `<state-dir>/manifests/` against the approved
   plan** and delete any manifest the plan does not list. `resolve.mjs` assembles the DAG from every
   manifest present — which is exactly what makes a partial re-run come out whole — so a manifest left
   by an earlier run of different scope silently joins the apply order and reaches the pipeline. On a
   **resume**, leave the directory alone; that is the mechanism you are relying on
   (`docs/state-files.md`).

---

## Phase 2–3 — fan-out generation (the Workflow, autonomous, no cloud)

After approval, run the committed Orchestrator. It has no filesystem access of its own — its
deterministic file work runs via a thin exec agent over the committed scripts (§16.13).

Invoke the **Workflow** tool with `scriptPath: "${CLAUDE_PLUGIN_ROOT}/workflows/dr-build.js"` and:

```
args = {
  sha:        "<pinned SHA>",
  inScope:    [ { component, source_root, target_root, tfc_workspace }, ... ], // from Phase 1
  pipeline:   "<DR pipeline path>",                    // from profile/repo-map.md
  engine:     "${CLAUDE_PLUGIN_ROOT}/engine",          // REQUIRED — the committed deterministic scripts
  agenticDir: "agentic-dr"                             // where profile/ and state/ live
}
```

`${CLAUDE_PLUGIN_ROOT}` is substituted in this skill's content, so the Workflow receives concrete
absolute paths. That indirection is the whole reason `engine` is an argument: the scripts ship with
the plugin, the profile and state live in the estate's own repo, and neither may assume the other's
location.

> The fan-out workflow is auto-exposed as `agentic-dr:dr-build-fanout`. **It is not an entrypoint.**
> It carries none of the gates — they live here, in the main loop, because a workflow cannot pause
> for approval. Invoked bare it throws, because `sha`, `inScope` and `engine` only exist once Phase 1
> has run and been approved. Its name differs from this skill's on purpose: a workflow sharing a
> skill's name shadows it, and the caller silently gets the dispatch shim instead of these gates.

It fans out one `agentic-dr:dr-component-builder` per in-scope root, invariant-lints + reconciles each
(`lint.sh` + `reconcile.mjs`), assembles the DAG, halts on any cycle **and everything downstream of
it** (recorded in `dependency-graph.md` — escalate, never auto-break), computes the tiered apply order, writes
`blackboard.md` / `dependency-graph.md` / `run-report.md`, and regenerates the managed DR job region
in the DR pipeline file. Its final **GitOps** phase regenerates the platform/core GitOps overlay
into the profile's `target_dir` (`gitops-rewrite.mjs` + `profile/gitops-substitutions.json`) and
writes `state/gitops-report.md`.

**On return:** read `run-report.md` and present it — it confirms/corrects the build plan. If any
component shows a lint/reconcile failure, **re-invoke the Workflow** (it is resumable — only the
edited/new Builders re-run) after the owning root is fixed. Then run `terraform fmt -check` and
`terraform validate -backend=false` locally on the generated roots (config-only, no cloud).

**Commit the result as a PR** (ARCHITECTURE §16.2): the generated DR roots, the regenerated DR
pipeline job stanzas, the committed state files (`build-plan.md`, `blackboard.md`,
`dependency-graph.md`, `run-report.md`, `gitops-report.md`), and — for failover — the regenerated
GitOps overlay (see GitOps residue below). Git is the audit trail and the Mode-1
drift baseline.

### GitOps overlay (platform/core) — interactive residue (main loop)

The Workflow's GitOps phase already did the mechanical work: copy + AUTO substitutions + the
completeness guard, recorded in `state/gitops-report.md` and the returned `gitops` object. You own
the residue it can't decide autonomously:

- **Completeness guard.** If `gitops.violations` is non-empty, a source infra token (a name prefix,
  a source CIDR, a source region token) survived into the overlay — the rules are incomplete. Fix
  `profile/gitops-substitutions.json` and re-invoke the Workflow; never commit a leaking overlay.
- **DECIDE.** Present each `gitops.decide` item (e.g. an internal gateway allowlist, on-prem
  sources kept as the default) and ask the engineer to confirm or override; apply the answer to the
  overlay file.
- **POST-APPLY.** A `__DR_POST_APPLY__*` sentinel cannot be resolved until the root that produces its
  value applies. Leave them for **Phase 6**: once those tiers apply, read each DR value from the
  producing root's **Terraform output** — `profile/gitops-rules.md` names the output per sentinel
  slug — replace the sentinels, then commit. Never infer one from the source overlay.
- **Commit semantics.** For **dry-run**, the overlay + report are the artifact — review the diff
  (`git diff --no-index <source_dir> <target_dir>`); sentinels remain unresolved, do not deploy. For
  **failover**, the `target_dir` must be on `main` (the GitOps controller syncs manifests from git),
  and **every sentinel must be resolved** first.
- **[SENTINEL GATE — failover commit].** Before committing the overlay for a failover, run
  `grep -rl '__DR_' <target_dir>` — it **MUST be empty**. A remaining `__DR_POST_APPLY__*` or
  `__DR_DECIDE__*` token means an unresolved identity, resource id or allowlist, and committing it
  would sync a manifest that fails to authenticate (or trusts the wrong sources) on the DR cluster.
  A non-empty result **blocks the commit** until resolved.

For **`/dr-build dry-run`**, you may stop here, or escalate to a gated drift check: **[GATE]** ask
before `gh workflow run <DR pipeline> -f plan_only=true ...`, in dependency order, as far as a cold
region allows (cold plan-only is partial by design, §6.3). No apply, ever, in Mode 1.

---

## Phase 4–6 — failover plan / apply / triage (`/dr-build failover`, gated)

Run in the main loop, tier by tier, in the order from `dependency-graph.md`. The Workflow can't pause
for approvals — you carry the gates.

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
    the engineer; a region-parity / "won't come up" failure goes to **Mode 3** (`/dr-build fix`).
- **Phase 6 — Apply (staged, failover only).** **[GATE per tier]** Only after explicit approval, flip
  `plan_only=false` for that tier (the `dr` Environment's required-reviewers gate it again
  server-side). Tier order: hub/firewall → DNS → network-dependent workloads → the rest. After each
  apply, capture post-apply residue (firewall IP, hub IPs) back into `blackboard.md` and advance.
  Once the tiers that produce them are applied, resolve the GitOps `__DR_POST_APPLY__*` sentinels
  from those roots' Terraform outputs (`profile/gitops-rules.md` names the output per slug) into the
  `target_dir`, then **clear the SENTINEL GATE** (`grep -rl '__DR_' <target_dir>` must be empty —
  covers the DECIDE values too) and commit, so the DR GitOps controller syncs a complete overlay.

Resumability: if a session dies mid-apply, recovery does not depend on it — the committed state files
+ TFC state let any engineer resume the tiered apply (§8, §16.3).

---

## Mode 3 — adaptive remediation (`/dr-build fix <service>`)

Not regeneration — problem-solving against **one** failing service (a region-parity gap or a
misbehaving managed service). Spawn the **`agentic-dr:dr-dynamic-remediator`** agent with the failure + the
affected DR root. It diagnoses, then proposes only **invariant-safe** alternatives:

> **Hard invariants it may never propose violating** (ARCHITECTURE §3): no public exposure of an
> internal service, no egress bypass of the controlled path, no weakening of network isolation /
> encryption-at-rest / TLS, and DR-estate-only. If the only working option breaks one, it **stops and
> escalates to a human** instead of presenting it.

**[APPROVAL GATE]** the engineer picks an option → implement it as a surgical change to the affected
DR root (or record a manual step) → re-plan/apply through the Mode-2 gates. An approved + applied fix
**auto-drafts a PR** to `profile/region-gaps.md` (rationale + revisit trigger), never into
the mechanical `transform-rules.md` (§16.10). Human-reviewed, never auto-merged.

---

## What to report when done

- The **pinned SHA** and the **in-scope list** (from `run-report.md`).
- **Built vs blocked**, and any **open blackboard items** + **cycles** (escalate cycles).
- The **manual-work checklist** (prerequisites + preflight gotchas) the engineer still owns.
- For failover: which tiers planned/applied, and any Validator verdicts / Mode-3 escalations.
- The PR link for the generated roots + state files.

## Not in scope for this skill

Cutover (routing live traffic to DR) and failback are **customer-driven routing steps**, never the
agent fan-out (ARCHITECTURE §1, §17). DR cleanup is a future `/dr-build cleanup`. Data restore is the
customer's data plane (§1).
