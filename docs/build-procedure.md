# The build procedure — Phases 1–3

**Shared by `/agentic-dr:dry-run` and `/agentic-dr:failover`.** Both entrypoints regenerate the DR
estate the same way; they differ only in what happens *after* it exists. This file is that common
half, so there is one copy of it to keep correct. Read it in full when either skill sends you here.

You — the main loop — run the **non-fan-out** work: Phase-1 discovery, the build-plan gate, and every
gated cloud step. The fan-out generation is the committed Workflow `workflows/dr-build.js`; the
deterministic checks/rewrites are the committed scripts `engine/lint.sh`, `reconcile.mjs`,
`resolve.mjs`, `gitops-rewrite.mjs`. Blueprint: `ARCHITECTURE.md`.

**`<plugin-root>` below is a placeholder, not a literal.** Substitute the absolute path the invoking
skill states before sending you here. The plugin-root variable those skills use is expanded in
*skill* content only, so writing it in this file would hand the Workflow an empty string and a path
like `/engine`; hence the placeholder.

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
5. **Apply is doubly gated and staged.** Per-tier approval in `/agentic-dr:failover` *and* the `dr`
   GitHub Environment's required-reviewers server-side.

---

## Phase 1 — discover & build plan (main loop, no cloud)

Do all of this before spawning anything. It is the cheap abort point.

1. **Pin the SHA.** `git rev-parse main` (or the current `main` tip). Use this commit for every read.
2. **Advisory lock (§16.11).** Check `<state-dir>/build.lock`. If present, stop and report who
   holds it. Otherwise write it (engineer, pinned SHA, which entrypoint). Remove it when the run hands
   off to the gated phases or completes. Advisory only — TFC state locks are the real backstop.
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

Invoke the **Workflow** tool with `scriptPath: "<plugin-root>/workflows/dr-build.js"` and:

```
args = {
  sha:        "<pinned SHA>",
  inScope:    [ { component, source_root, target_root, tfc_workspace }, ... ], // from Phase 1
  pipeline:   "<DR pipeline path>",                    // from profile/repo-map.md
  engine:     "<plugin-root>/engine",                  // REQUIRED — the committed deterministic scripts
  agenticDir: "agentic-dr"                             // where profile/ and state/ live
}
```

Both must be the **absolute** plugin path the skill gave you, so the Workflow receives concrete
paths. That indirection is the whole reason `engine` is an argument: the scripts ship with
the plugin, the profile and state live in the estate's own repo, and neither may assume the other's
location.

> The fan-out workflow is auto-exposed as `agentic-dr:dr-build-fanout`. **It is not an entrypoint.**
> It carries none of the gates — they live in the main loop, because a workflow cannot pause
> for approval. Invoked bare it throws, because `sha`, `inScope` and `engine` only exist once Phase 1
> has run and been approved. Its name matches no skill directory on purpose: a workflow sharing a
> skill's name shadows it, and the caller silently gets the dispatch shim instead of these gates.

It fans out one `agentic-dr:dr-component-builder` per in-scope root, invariant-lints + reconciles each
(`lint.sh` + `reconcile.mjs`), assembles the DAG, halts on any cycle **and everything downstream of
it** (recorded in `dependency-graph.md` — escalate, never auto-break), computes the tiered apply order, writes
`blackboard.md` / `dependency-graph.md` / `run-report.md`, and regenerates the managed DR job region
in the DR pipeline file. Its final **GitOps** phase regenerates the platform/core GitOps overlay
into the profile's `target_dir` (`gitops-rewrite.mjs` + `profile/gitops-substitutions.json`) and
writes `<state-dir>/gitops-report.md`.

**On return:** read `run-report.md` and present it — it confirms/corrects the build plan. If any
component shows a lint/reconcile failure, **re-invoke the Workflow** (it is resumable — only the
edited/new Builders re-run) after the owning root is fixed. Then run `terraform fmt -check` and
`terraform validate -backend=false` locally on the generated roots (config-only, no cloud).

**Commit the result as a PR** (ARCHITECTURE §16.2): the generated DR roots, the regenerated DR
pipeline job stanzas, the committed state files (`build-plan.md`, `blackboard.md`,
`dependency-graph.md`, `run-report.md`, `gitops-report.md`), and — for a failover — the regenerated
GitOps overlay (see GitOps residue below). Git is the audit trail and the `/agentic-dr:dry-run`
drift baseline.

### GitOps overlay (platform/core) — interactive residue (main loop)

The Workflow's GitOps phase already did the mechanical work: copy + AUTO substitutions + the
completeness guard, recorded in `<state-dir>/gitops-report.md` and the returned `gitops` object. You own
the residue it can't decide autonomously:

- **Completeness guard.** If `gitops.violations` is non-empty, a source infra token (a name prefix,
  a source CIDR, a source region token) survived into the overlay — the rules are incomplete. Fix
  `profile/gitops-substitutions.json` and re-invoke the Workflow; never commit a leaking overlay.
- **DECIDE.** Present each `gitops.decide` item (e.g. an internal gateway allowlist, on-prem
  sources kept as the default) and ask the engineer to confirm or override; apply the answer to the
  overlay file.
- **POST-APPLY.** A `__DR_POST_APPLY__*` sentinel cannot be resolved until the root that produces its
  value applies. For `/agentic-dr:dry-run` they simply stay unresolved. For `/agentic-dr:failover`
  they are resolved in **Phase 6**: once those tiers apply, read each DR value from the producing
  root's **Terraform output** — `profile/gitops-rules.md` names the output per sentinel slug —
  replace the sentinels, then commit. Never infer one from the source overlay.

---

## What to report when done

- The **pinned SHA** and the **in-scope list** (from `run-report.md`).
- **Built vs blocked**, and any **open blackboard items** + **cycles** (escalate cycles).
- The **manual-work checklist** (prerequisites + preflight gotchas) the engineer still owns.
- The PR link for the generated roots + state files.

`/agentic-dr:failover` adds to this: which tiers planned/applied, and any Validator verdicts /
`/agentic-dr:fix` escalations.

## Not in scope for either entrypoint

Cutover (routing live traffic to DR) and failback are **customer-driven routing steps**, never the
agent fan-out (ARCHITECTURE §1, §17). DR cleanup is a future `/agentic-dr:cleanup`. Data restore is
the customer's data plane (§1).
