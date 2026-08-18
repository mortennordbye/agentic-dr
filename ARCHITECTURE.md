# Agentic DR Build — Architecture

> **Status: design locked; first implementation landed.** All §16 design decisions (1–15) are
> resolved and the blueprint is complete. The runnable system now exists per the build order (§16.5):
> the committed invariant lint (`lint.sh` + `profile/lint-patterns.txt`) and second oracle
> (`reconcile.mjs`), the Orchestrator (`workflows/dr-build.js`) with its Phase-3 resolver (`resolve.mjs`) and
> its GitOps overlay rewriter (`gitops-rewrite.mjs` + `profile/gitops-substitutions.json`, §16.15),
> the three entrypoint skills (`dry-run`, `failover`, `fix` — one per mode, each carrying its gates), and the Mode-3 persona
> (`agents/dr-dynamic-remediator.md`) with its `profile/region-gaps.md` write-back target —
> alongside the two original personas (`dr-component-builder.md`, `dr-plan-validator.md`) and the
> per-customer **profile** (`profile/`). What remains is exercising it end-to-end (a first Mode-1
> dry-run to establish the drift baseline). This document is the blueprint for an AI-agent system that
> *generates* a Phase-2 disaster-recovery Terraform estate on demand from current production +
> connectivity code, instead of maintaining a parallel DR pipeline that would silently drift.

> **Blueprint vs. profile.** This file is **customer-agnostic**: it names no customer, region,
> CIDR, identity, subscription, or repo path. Every such binding lives in the **profile**
> (`profile/`, contract in [`docs/profile-contract.md`](docs/profile-contract.md)) — the only thing that changes
> per customer. Any concrete value shown here is an illustrative, non-normative example; the
> profile is authoritative.

---

## 1. Problem & thesis

DR is **cold standby**. Phase 1 (the source-estate VNets and the reserved egress public IPs) is
pre-staged. **Phase 2 — at failover — must materialize the network hub, firewall, and ~all
production + connectivity workloads in the DR region.** Today a platform engineer hand-ports every
in-scope root (§12) from the source roots (`profile/repo-map.md`), fixing region, CIDRs, naming,
identities, subscription, DNS, and every cross-component reference, under outage pressure.

**Thesis: do not maintain a standing DR pipeline — regenerate it on demand from current `main`.**
A maintained copy rots (prod changes, the DR copy goes stale, you find out on DR day). A generator
driven off the live source code is drift-proof by construction: its input is always today's truth.

### This document is a blueprint, not an inventory

Beyond naming no customer, the architecture stores **no dynamic inventory**: no enumerated
component list, no resource counts. The in-scope set is **discovered from the repo folders at run
time** (§12); the only things deliberately *pinned* are **guardrails in small, critical files** —
the scope exclusions (`profile/scope-rules.md`) and the invariant-lint patterns
(`profile/transform-rules.md`). A blueprint that needs hand-maintenance drifts exactly like the
pipeline we refuse to maintain.

The transformation is **~90 % mechanical** and fully specified by the profile (name scheme, IP
plan, TF/state conventions, guardrails). The agent fleet exists for the ~10 % that is not:
**cross-component references that do not yet exist in a cold region** — plus **adaptive
remediation** (Mode 3, §3) when the standard prod pattern won't work in the DR region.

### Where this sits — the customer's DR process

This system is **one phase** of a larger, customer-owned DR process: the **regional
core-infrastructure build**. The platform team owns that phase; the customer owns disaster
declaration, data/storage recovery, application deployment, and traffic cutover/validation. The
concrete process — phases, RACI, the request that triggers a failover build — lives in
[`profile/process.md`](profile/process.md). Two consequences hold for every customer:

- **The build's job ends at "infrastructure up and running"; the customer owns the data plane**
  (Responsibility boundary, below).
- **The build is additive only.** Cutover and failback are customer-led routing decisions, kept out
  of the agent fan-out (§1 isolation, §17 lifecycle).

### Why agents, not a templating engine

The cheaper deterministic alternative — Terragrunt, `generate` blocks, or region-parameterized
modules — is deliberately rejected, for three reasons:

1. **Retrofitting touches production.** The source roots are not region-parameterized today; making
   them so means editing live production code — exactly the blast radius §1 forbids. A generator
   that *reads* the source as immutable and *writes* a separate DR estate keeps production
   untouched by construction.
2. **The hard part is cold-start dependency ordering, not substitution.** A templating engine
   leaves the genuinely difficult work undone: resolving cross-root `data` lookups that resolve
   *nothing* in a cold region (§6), computing a safe apply order, and tracking the residue on a
   blackboard.
3. **The transform is semantic, not lexical.** A blind region-token or CIDR substitution corrupts
   partner IPs, comments, and unrelated resource IDs (§5). Telling a region marker from a partner's
   fixed IP requires understanding what each value *is*.

Where a sub-step *is* purely mechanical (the invariant lint, §11) we use a deterministic grep, not
an LLM — **agents are applied only where judgment is required.**

### Blast-radius isolation (the #1 guardrail — LOCKED)

DR is a **failover, not a migration**: the source estate keeps running **untouched** while DR is
built, so traffic can route back when it recovers (§17). The agents must therefore **never modify,
plan, apply, or destroy anything outside the DR estate** — enforced at **four independent levels**,
so a confused or hallucinating agent *still* cannot reach the source estate. The concrete bindings
are in [`profile/identity.md`](profile/identity.md):

1. **Subscription/account (the hard guarantee).** The DR pipeline authenticates with a **DR-only
   identity** scoped to the DR subscription, holding **no role** on the source subscriptions — even
   a malformed apply *physically cannot* touch a source resource. This guarantee does not depend on
   the agents behaving.
2. **State.** DR state lives only in the DR workspaces; agents never run against the source
   workspaces.
3. **Pipeline.** Agents only ever trigger the DR pipeline, never the source pipelines.
4. **Write path.** Builders write **only** under the DR output tree; they *read* the source roots
   as truth but treat them as **immutable** — never an edit, never a `plan`/`apply` against them.
   **One scoped exception, the Orchestrator's alone (§16.12):** the Orchestrator — never a Builder
   — also writes the per-component job stanzas into the single DR pipeline file, generated from the
   computed apply order and reviewed in the same PR. The Builder invariant is unchanged; this is
   the one deliberate widening, recorded so it stays auditable.

The one deliberate cross-estate action — **routing live traffic to DR (edge / DNS cutover)** — is
never done by a Builder; it is a separate, customer-driven, narrowly-scoped runbook step (§17).
Likewise the **only destroy** the agents ever perform is the DR-scoped cleanup at failback (§17).

### Design philosophy — a thin orchestrator over small-context workers

The scarce resource in an LLM system is **attention over context**: a model on a tight, minimal
context writes cleaner, more correct Terraform than the same model holding the entire estate — as
irrelevant context grows, boundaries blur and output drifts toward another component's patterns.
So each **Component Builder is spawned with the minimum sufficient context** — one source root, the
transform rules, the inputs of the modules it actually calls — and *nothing* about the other
components. The **Orchestrator is the thin control plane**: it alone holds global state (the
dependency DAG, the blackboard, per-component status, the apply order) and makes all coordination
decisions. **Builders are stateless, fungible workers** that never talk to each other; every
cross-component dependency reconciles centrally.

| Property | Thin orchestrator + small-context workers | One thick agent holding everything |
| -------- | ----------------------------------------- | ---------------------------------- |
| **Code quality** | Each root written on a focused window — best first-token conditions | Diluted by every other component; boundaries blur |
| **Throughput** | one worker per in-scope root, all in parallel; wall-clock ≈ the slowest single component | Strictly serial; sum of all components |
| **Blast radius** | A worker that errs damages only its own root; lint + plan catch it; re-run just that one (the Workflow is resumable) | One mistake anywhere poisons the whole context |
| **Coordination** | One source of truth (the blackboard); deterministic dependency resolution; no N×N chatter | Implicit, in-head, unauditable; easy to contradict itself |
| **Evolvability** | A new source component is discovered automatically next run; no catalog, persona, or rule changes | The single prompt grows without bound |

**Coordination is thin, stateful, and central; production is focused, stateless, and parallel** —
which is why "one subagent per component" is an architectural decision, not a convenience.

### Responsibility boundary (LOCKED)

**The platform team — and therefore this agent system — owns the infrastructure / platform only:
getting the cloud resources provisioned and running.** The *data plane* and all data recovery is
**the customer's responsibility** — e.g. we provision *empty* SQL servers / databases, storage
accounts, and messaging namespaces as defined in code; the customer restores the data. The agents'
job ends at "resources up and running per the generated Terraform," and they must never imply they
are recovering data.

**One seam — bootstrap secrets.** Key Vaults are generated *empty*, but some workloads need
secrets / certs / connection strings present to *boot* (platform config, not business data).
**Resolved (§16.8, LOCKED): external Key Vault replication** from the primary region
pre-provisions the DR vault and its secrets, so the build only wires workloads to the
already-populated vault — it never owns secret population.

**Amendment (GitOps in scope — §16.15).** The boundary is drawn at *platform vs data plane*, not
*Terraform vs GitOps*. The GitOps layer in the platform repo is therefore **platform-owned DR**: the
GitOps Builder phase (§8) regenerates the whole component overlay, the same regenerate-from-`main`
move as the Terraform estate.

**The seam is the repo boundary, not a component list.** Everything in the platform repo is
generated; the applications' own manifests live in the customer's deployment repo and are never
touched. An earlier cut of this amendment also excluded the *onboarding* component as "application
GitOps" — wrong, and instructively so: that component is the ApplicationSet which **points** the
GitOps controller at the customer's deployment repo. Excluding it produced a DR cluster with every
platform service healthy and no mechanism to pull a single application, quietly making the customer's
app-deployment phase impossible. **We generate the pointer; they own what it points at.** This
refines — does not widen — the boundary: the agents still own only platform/infrastructure, never
business data.

### Non-goals

- **Not** a replacement for the profile / durable DR context — those stay the source of truth for
  facts.
- **Not** a data-recovery tool. Stateful roots (SQL / storage / messaging) are generated *empty*
  by design; populating them is the customer's data plane.
- **Not** an unattended auto-applier. Every pipeline run is human-approved (§10).
- **Not** in scope: anything `profile/scope-rules.md` excludes.

---

## 2. Operating constraint & how it runs

**Everything runs through the AI coding tool (Claude Code) as a platform engineer — no standalone
API token, no external service, no long-running headless agent.** The engineer opens the tool in
this repo and invokes one skill — the one named after what they want done.

### 2.1 Invocation — three committed skills, one per mode

- `/agentic-dr:dry-run` → Mode 1 (generate + lint + validate; optionally plan-only)
- `/agentic-dr:failover` → Mode 2 (generate → gated plan → gated apply → troubleshoot)
- `/agentic-dr:fix <service>` → Mode 3 (adaptive remediation of one service)

Each is a separate skill so the invocation states the intent and the mode set is discoverable by
typing the plugin prefix — there is no mode argument to remember or mistype. `dry-run` and
`failover` share Phases 1–3 verbatim via `docs/build-procedure.md`, so the common half has one
definition; they diverge only in what follows generation.

Every skill carries the gating discipline: **stop and ask before any `gh workflow run`.** Mode 2 is
triggered by the customer's DR process (`profile/process.md`), never on a hunch; the protected
scope is fixed by the profile, so the only run-time input is the build point — the current `main`
SHA is **pinned on receipt** (§4) and the whole estate is built from it.

### 2.2 Two execution surfaces (where approval has to live)

1. **Fan-out generation = a `Workflow` script.** The committed `workflows/dr-build.js` *is* the Orchestrator:
   it spawns one **Component Builder** sub-agent per component (parallel, capped ~10), each
   emitting a DR root + manifest, then runs the two deterministic checks on every root — the
   invariant lint and the manifest reconcile (§11). **No cloud**, and no mid-run approval — the
   fan-out starts only after the engineer authorizes the **build plan** (§8.1), then runs to
   completion deterministically.
2. **Cloud steps (plan / apply / troubleshoot) = the main loop.** The Workflow cannot pause mid-run
   for an interactive approval, so the gated steps run interactively: `gh workflow run` → `gh run
   watch`/`view` → on failure spawn a **Plan Validator** to triage → route the fix to a Builder, or
   escalate to Mode 3.

### 2.3 Where Terraform actually executes

The existing DR pipeline (`profile/repo-map.md`) runs every real plan/apply. Agents only
**trigger** it (`gh workflow run`) and **read** results (`gh run view`/`watch`). The only local
Terraform is the `fmt`/`validate` pass the main loop runs on the generated roots once the fan-out
returns (§8, `docs/build-procedure.md`) — config-only, no backend, no cloud.

### 2.4 Approval gates, concretely

- **Build plan (pre-fan-out):** the main loop presents the build plan (§8.1) for authorization
  before spawning any Builder — a cheap, local abort point (read-only, no cloud).
- **Local generation/validation:** no further gate — authorized up front by the build plan.
- **Plan trigger:** the main loop asks before `gh workflow run … plan_only=true`.
- **Apply:** doubly gated — `plan_only=false` only after explicit approval, **and** the DR GitHub
  Environment's **required-reviewers** enforce it server-side, independent of the agents.

### 2.5 At a glance — modes × surfaces × lifecycle

| Mode | What it does | Lifecycle stage (§17) | Execution surface (§2.2) | Cloud? | Gated? |
| ---- | ------------ | --------------------- | ------------------------ | ------ | ------ |
| **1 Dry-run** | generate Terraform + GitOps overlay + lint/validate, optional plan-only | rehearses stage 1 | Workflow (gen) → main loop (plan) | read/plan only | plan trigger gated |
| **2 Failover** | generate → plan → apply, tiered, self-troubleshooting → resolve GitOps post-apply | stage 1 (build DR) | Workflow (gen) → main loop (plan/apply) | yes | plan **and** apply gated |
| **3 Dynamic** | diagnose one failing service, propose an invariant-safe alternative | any stage (escape hatch) | main loop only | maybe | approval on the chosen fix |

Every Mode 1/2 run opens with the **build-plan gate** (§8.1). Cutover (stage 3) and failback
(stage 4) are **not** agent modes — they are customer-driven routing steps (§1, §17); cleanup
(stage 5) is a future `/agentic-dr:cleanup`.

---

## 3. Three modes

Modes 1 and 2 share one machinery (generate → lint → plan → apply); Mode 3 is a separate, focused,
human-invoked loop. All run inside the AI coding tool (§2).

### Mode 1 — Dry-run (test the agents / drift check) · **no apply**

> *"Test out the agents and make sure they can write Terraform as it should."*

Regenerate Phase-2 DR code from current `main` and verify it, without touching the cloud beyond
read/plan. Two escalating levels:

- **Local (fast inner loop, zero cloud):** generate the DR roots, then `terraform fmt -check` +
  `terraform validate` + the invariant lint (§11). No TFC, no cloud, no approval needed.
- **Plan (drift check):** escalate to a `plan_only=true` pipeline run in dependency order, as far
  as a cold region allows (§6.3). Surfaces source→DR drift early; the regenerated roots are diffed
  against the committed DR baseline (§16.2) and opened as a PR.

Because this path is exercised regularly, Mode 2 is never a cold first run during a crisis —
**test the machinery constantly so it works on DR day.**

### Mode 2 — Failover (DR declared) · **apply, gated + self-troubleshooting**

> *"Invoke during an actual DR: create the code, do plans, ask for applies; if I approve the
> applies, look at the applies and troubleshoot the Terraform failures."*

Same generation + lint, then, tier by tier in dependency order:

1. **Plan** the tier → present it.
2. **[APPROVAL GATE]** ask the engineer to approve the apply.
3. On approval, **apply** the tier.
4. **Watch the apply.** On failure, the Plan Validator (§7) classifies the error and routes a fix
   to the owning Builder; re-plan → re-apply (re-gated). A failure that is *not* a fixable config
   error — a service that won't come up the standard way — escalates to **Mode 3**.
5. Capture post-apply residue (firewall IP, hub IPs) to the blackboard; advance to the next tier.

### Mode 3 — Dynamic (adaptive remediation) · **human-invoked, per failing service**

> *"If a specific service in our production / connectivity workflows stops working, adapt and
> figure out a different solution — e.g. a different way to expose a service, or if a managed
> firewall doesn't work, do something else."*

Not regeneration — **problem-solving**, invoked against **one** failing service, typically a
region-parity gap (SKU/feature/zone) or a misbehaving managed service. The loop:

1. **Ingest the failure** — a plan/apply error *or* a "service isn't working" report.
2. **Diagnose** the root cause: region capability gap, quota, dependency, or config.
3. **Propose alternatives** — a different exposure mechanism, egress approach, SKU, or a documented
   manual workaround — with trade-offs.
4. **[APPROVAL GATE]** engineer picks an approach.
5. **Implement** it as a surgical change to the affected DR root (or record a manual step), then
   re-plan / re-apply through the Mode 2 gates.

Though framed for DR, this is the general escape hatch for "the standard pattern doesn't work
here" — built customer-agnostic and `profile/`-driven (§16.6, LOCKED), scoped to DR for the first
cut.

**Hard invariants Mode 3 may never propose violating** — it invents alternative *designs*, and an
engineer under outage pressure may rubber-stamp them, so its solution space is bounded:

- **No public exposure of an internal service.** Anything private in the source stays private in
  DR.
- **Egress stays through the controlled egress path** — no firewall / reserved-egress-IP bypass,
  even temporarily.
- **No weakening of network isolation, encryption-at-rest, or TLS** relative to the source pattern.
- **DR-estate-only** (§1) — an alternative may never reach into the source estate.

If the only working alternative would break one of these, Mode 3 **stops and escalates to a human**
rather than presenting it as an option. Its output contract: the failure, the diagnosis, the
candidate alternatives *that satisfy the invariants*, the trade-offs, and an explicit "invariants
preserved" attestation per option. (The Mode 3 agent file — defined when Mode 3 is built, §16.7 —
encodes this set.)

---

## 4. Source of truth (LOCKED)

Per value class:

1. **Repo HCL (primary).** The source roots on current `main` are the maintained desired state;
   all structural generation derives from here. Drift-proof.
2. **Live cloud / TFC state (residue only).** A small set of values exist *only* after apply — the
   firewall private IP, hub IPs, generated resource IDs, the reserved egress PIPs. Read from state
   when needed, never invented.
3. **Profile overrides.** The values the profile pins for DR (subscription, identity, CIDR block,
   partner egress IPs) win over whatever the source uses — **read from the profile, never
   duplicated here**.

**Input pinning (LOCKED).** A failover can run for hours while `main` moves, so every run **pins
the exact commit SHA of `main` at invocation** and generates the entire estate from that one
commit — reproducible and internally consistent; a later resume or re-plan builds from the same
input. The pinned SHA is recorded in `run-report.md`.

---

## 5. Transformation ruleset

The transform happens along fixed **dimensions**; the authoritative values for each live in
[`profile/transform-rules.md`](profile/transform-rules.md), not here. Builders apply them
**semantically**, never as blind find/replace (§1).

- **Name prefix** — source tier prefixes → their DR equivalents (`profile/naming.md`).
- **Region tokens** — source-region tokens → DR-region tokens, in names, `location`, and strings.
- **CIDR** — source blocks → DR blocks per the IP plan (`profile/network.md`).
- **TFC workspace** — source workspace names → DR workspace names.
- **Module source path** — adjusted for the DR roots' depth in the tree (`profile/repo-map.md`).
- **Subscription** — stays a runtime `var.subscription_id` via OIDC; code unchanged.
- **Tags** — `Environment` → the DR value; cost/department/deployment tags unchanged.
- **tfvars filename** — source var-file → the DR var-file.
- **DNS (Phase-1 posture)** — strip source resolver/firewall IPs and routes; default DNS until the
  DR resolver exists.
- **Network-contributor identity** — the shared VNet module's default source identity → the DR
  identity (`profile/identity.md`).
- **Scope exclusions** — drop whatever `profile/scope-rules.md` excludes.
- **Global / non-regional services** — classify per `profile/global-services.md`: never clone a
  global singleton (Front Door, public DNS), skip ones already replicated **to the DR region**
  (geo-replicated ACR — *not* storage geo-redundancy, which targets the Azure-paired region, so it
  does not qualify; see `profile/global-services.md`), regenerate global-namespace resources under a
  DR name, and give the DR subscription its own copy of subscription-scoped shared infra
  (`privatelink.*` zones, vWAN hub).
- **Module versions** — read each module's `variables.tf` live; never copy a stale POC.

---

## 6. Dependency model (the hard part)

**This repo wires cross-root dependencies through named `data` lookups, not
`terraform_remote_state`** (confirmed by survey: `data "azurerm_virtual_network"`,
`data "azurerm_subnet"`, `data "azurerm_private_dns_zone"`, `data "azurerm_key_vault"`, etc.; only
a couple of roots use `terraform_remote_state`). The orchestrator detects which from the code, not
a maintained list. Consequences:

1. **A `data` lookup resolves a resource *by name* in the live subscription.** In a cold DR region
   those resources don't exist until applied — a consumer's `plan` *fails* until its producers are
   applied. The cross-component job is therefore mostly **(a)** rewrite every lookup target name to
   its DR equivalent (`profile/naming.md`) and **(b)** enforce apply order so producers exist
   before consumers plan.
2. **The blackboard tracks the residue** — references that are not a simple name rewrite
   (hardcoded principal IDs, post-apply IPs, secret references, `terraform_remote_state` outputs).
   Each entry: what is needed, by which component, from which producer, and how it resolves (the
   manifest's `via` values: `data-rename` / `override` / `post-apply` / `remote-state`).
3. **Cold-region plan-only is only partially valid (accepted limitation).** A downstream component
   cannot fully validate until its upstreams are applied; peacetime validation is *staged and
   partial*. Intrinsic to cold DR — call it out, never hide it.

### Manifest contract (every Component Builder emits one)

The **authoritative schema is the Builder persona's contract**
(`agents/dr-component-builder.md`); this is an illustrative instance:

```jsonc
{
  "component": "aks",
  "source_root": "<source root path>",
  "target_root": "<DR root path>",
  "tfc_workspace": "<DR workspace>",
  "produces": ["<DR resource> (cluster id, kube host, CA cert)"],
  "consumes": [
    { "what": "vnet subnet id (aks snet)", "from": "vnet", "via": "data-rename", "status": "resolved" },
    { "what": "acr id",                     "from": "acr",  "via": "data-rename", "status": "resolved" },
    { "what": "<hardcoded principal id>",   "from": "—",    "via": "override",    "status": "blackboard" }
  ],
  "prereqs": ["<DR workspace> created + Local exec mode", "RP Microsoft.ContainerService"],
  "notes": []
}
```

The Orchestrator builds the DAG from all `produces` / `consumes`, detects cycles, computes the
apply order, and owns the blackboard.

---

## 7. Agent topology

| Role | Count | Responsibility |
| ---- | ----- | -------------- |
| **Orchestrator** (`workflows/dr-build.js` + the entrypoint skill that invoked it, §2.2) | 1 | Owns the run: discovers the in-scope roots from the repo (minus `profile/scope-rules.md` exclusions), fans out Builders, assembles the DAG from manifests, detects cycles, computes apply order, maintains `status.json` + `blackboard.md` + `dependency-graph.md`, triggers plan validation, routes errors back, surfaces the prerequisite checklist, pauses at every gate. |
| **Component Builder** | 1 per in-scope component | Reads its source root + `profile/transform-rules.md` + the relevant module `variables.tf`. Emits the DR root (`providers.tf`, `main.tf`, `variables.tf`, DR var-file), applies the transform semantically, rewrites `data`-lookup target names to DR, returns its manifest (§6). Logs anything it can't resolve to the blackboard rather than guessing. |
| **Plan Validator** | as needed | Reads `gh run` plan *and* apply output, classifies the failure (category set in its persona contract), returns a structured verdict the Orchestrator routes to the owning Builder — or escalates to Mode 3 when the failure is a region-parity / "won't come up" problem. |
| **Invariant Linter** | mechanical | Not an LLM — a grep pass (§11). Runs after every Builder, before any plan. Fails the component on source-estate leakage. |

### Where the prompts live (two layers)

Agent behaviour is **committed and versioned**, not hand-written per run:

- **Layer 1 — agent definitions** (`agents/dr-*.md`): each worker's persona — role,
  do's/don'ts, and its input/output **contract with the Orchestrator**. Referenced by the `Agent`
  tool (`subagent_type`) and the Workflow (`agentType`). Customer-agnostic.
- **Layer 2 — the customer profile** (`profile/`): the stable bindings and guardrails (transform
  rules, lint patterns, scope exclusions, naming, network, identity, repo map). Guardrails, not
  inventory — scope *inclusions* are discovered, never listed (§12).

The **Orchestrator is not an agent file** — it is the `workflows/dr-build.js` script body plus the
entrypoint skill that invoked it (§2). Mode 3's agent is defined when Mode 3 is built (§16.7).

---

## 8. Orchestration flow

The run spans the two execution surfaces of §2.2: **Phase 1 (discover + build plan) runs in the
main loop and ends at the plan-approval gate; Phases 2–3 are the autonomous `Workflow` script (no
cloud); Phases 4–6 run in the interactive main loop (every cloud step gated).** The hand-off *into*
the Workflow is the approved build plan + in-scope list + source→target map; the hand-off *out* is
the generated DR roots + manifests + computed apply order.

**Main loop (pre-fan-out, no cloud — "think before coding"):**

```
Phase 1  Discover & plan      scan the source roots (profile/repo-map.md), drop profile/scope-rules.md
                              exclusions → in-scope list + source→target map (derived, never hand-maintained).
                              From that list + the profile + a static read of each source root, assemble the
                              BUILD PLAN (§8.1) — what WILL be created, what will deliberately NOT be, and what
                              will need MANUAL work — without spawning a single Builder. Write build-plan.md.
        [PLAN APPROVAL GATE]  present the build plan; the engineer authorizes it (or amends scope) before the
                              fan-out spawns. The cheap abort point: no roots generated, no agents spawned yet.
```

**Workflow script (autonomous, no cloud):**

```
Phase 2  Build (fan-out)     pipeline: per component → Builder emits DR root + manifest → Invariant lint
Phase 3  Graph & resolve     assemble DAG, detect cycles (halt that subgraph + escalate — see below),
                             resolve data-renames, write unresolved refs to blackboard.md, compute apply
                             order, emit run-report.md — the ACTUAL outcome that confirms/corrects the
                             Phase-1 build plan (what built / blocked)
Phase G  GitOps overlay      regenerate the platform/core GitOps overlay into the profile's target_dir
                             from its source_dir via the committed rewriter (gitops-rewrite.mjs +
                             profile/gitops-substitutions.json, §16.15): AUTO prod→DR substitutions,
                             __DR_POST_APPLY__/__DR_DECIDE__ sentinels for the non-derivable residue, and
                             a completeness guard that fails on any surviving prod infra token. Emits
                             gitops-report.md. The interactive residue (confirm DECIDE, resolve POST-APPLY)
                             is the skill's job — the Workflow can't pause for input (§2.2).
```

  ── hand-off: generated roots + manifests + apply order + GitOps overlay ──

**Main loop (interactive, gated):**

```
Phase 4  Plan (staged)       [APPROVAL GATE] trigger the DR pipeline plan_only=true, in dependency
                             order; human reviews each plan (the real semantic gate, §10/§11)
Phase 5  Triage & fix        on a plan/apply failure, spawn a Plan Validator → route the verdict: a config
                             fix re-runs the owning Builder (re-invoke the Workflow, resumable); an ordering
                             issue adjusts apply order; a region-parity gap escalates to Mode 3
─────────  (failover only — Mode 2)  ─────────
Phase 6  Apply (staged)      [APPROVAL GATE per tier] flip plan_only=false, tier by tier (hub/firewall →
                             DNS → network-dependent workloads → rest), capture post-apply residue
                             (firewall IP, hub IPs) back to blackboard
```

Builders run concurrently within Phase 2; ordering constraints come from the DAG, not hand-wiring.

**Where the deterministic steps execute (§16.13).** The Workflow script itself has no filesystem
access: discovery + the build plan run in the main loop (above, before the gate), passed into the
fan-out via `args`; the §11 lint and the Phase-3 state-file writes run *inside* the Workflow via a
**thin spawned agent that execs the committed script** — the determinism lives in the script
(§16.14), not the agent, whose only job is a trivial exec. The DR pipeline's per-component job
stanzas are regenerated the same way, from the computed apply order (§16.12).

**On cycles:** most apparent firewall↔network "cycles" are **post-apply** values (a firewall IP
known only after apply), broken by staging and the blackboard (§6.3, `via: post-apply`). A
*genuine* plan-time `data` cycle would mean the source estate itself can't apply — vanishingly
rare. The Orchestrator therefore does **not** break cycles programmatically: on detection it
**halts the affected subgraph, records it in `dependency-graph.md`, and escalates to a human**,
while the rest of the fan-out proceeds.

**Resumability has two senses, both required:**

- *Generation* — the `Workflow` is resumable: a re-run reuses unchanged Builder results and only
  re-runs edited/new ones. Phase 5 fixes exploit this.
- *Failover* — if the engineer's session dies mid-apply, recovery must **not** depend on it. The
  committed run state (`blackboard.md`, `run-report.md`, `dependency-graph.md`) plus TFC state are
  the source of truth, so **any** platform engineer can resume the tiered apply. This is *why*
  those files are committed (§16.3) — on DR day the run must survive a dead laptop.

This flow covers **Mode 1** (phases 1–4, plan-only) and **Mode 2** (phases 1–6). **Mode 3** (§3)
is a separate, narrower loop against a single failing service, not the full fan-out.

### 8.1 The build plan (preflight) — *what the run intends, before it acts*

Phase 1 produces a **build plan** (`build-plan.md`, §9): for the pinned commit (§4), exactly what
the run intends to do — assembled from the discovered in-scope list, the profile, and a **static
read** of the source roots. **No Builder is spawned, no HCL is written, no cloud is touched** to
produce it; it is the repo's *think-before-coding* rule applied at the level of the whole estate.

**A hard sign-off gate, not a notification.** Nothing past it begins until the engineer explicitly
approves: approve as-is, amend the scope (plan regenerated), or abort. Three sections, all
derivable pre-build:

1. **Will be created** — each in-scope source root → its DR root (name, region, CIDR, TFC
   workspace per the profile), grouped by apply tier.
2. **Will *not* be created (and why)** — the deliberate omissions, each with its reason:
   `profile/scope-rules.md` exclusions, the pre-staged Phase-1 roots (§12), global singletons and
   already-replicated services (`profile/global-services.md`, §5), and policy roots (excluded —
   §16.9). *Empty* data-bearing roots appear in "will be created"; their **data** does not — it is
   manual work (§1 boundary).
3. **Will need manual work** — everything the agents emit but never perform: the out-of-band
   prerequisites checklist (§13), the bootstrap-secret / Key-Vault dependency (§16.8), the
   **predicted blackboard residue** (references a static scan already shows won't be a simple
   data-rename — hardcoded principal IDs, post-apply IPs, secret references,
   `terraform_remote_state` outputs, §6), known region-parity gaps (`profile/region-gaps.md`,
   §16.10), and the customer-owned data restore and traffic cutover (§1, §17). The standing
   gotchas/decisions this section draws from — storage account-failover status, KV replication
   coverage, Bucket D private-DNS, the observability split (sinks in / leaves out) and its AKS
   `law`/`amw` wiring — are the **preflight checklist** (`profile/preflight.md`).

**It is a prediction, not the authoritative graph** — the DAG and reconciled blackboard are
products of the manifests (Phase 3); `run-report.md` later confirms or corrects the plan. It
exists to catch scope and prerequisite errors *cheaply, before generating dozens of roots* — and
it is explicitly **not** a `terraform plan` (that is Phase 4).

---

## 9. State files (the blackboard)

Created under `<state-dir>/` (durable files committed per §16.3; `status.json` git-ignored):

| File | Shape | Purpose |
| ---- | ----- | ------- |
| `build-plan.md` | three sections: will-create · won't-create · manual-work | The Phase-1 preflight plan (§8.1) the engineer authorizes before the fan-out. |
| `status.json` | `{ component: { phase, plan_status, last_error } }` | Live run status the Orchestrator tracks. |
| `blackboard.md` | table: `needed_by · what · source · resolution · status` | Unresolved cross-component values; the Orchestrator works this down. |
| `dependency-graph.md` | DAG + computed apply order + cycle report | The ordering the staged plan/apply follows. |
| `run-report.md` | human summary | The pinned SHA, the in-scope list, what built, what's blocked, prerequisites, residue. |

---

## 10. Verification & approval gates (LOCKED)

- **The build plan precedes generation** (§8.1) — local and read-only, but a true gate: the
  fan-out does not start without it.
- **Verification is `terraform plan`, never a test suite** (repo convention).
- **Never trigger a pipeline without explicit user approval** — including `plan_only` runs. The
  skill / main loop *stops* and asks before any `gh workflow run`.
- **Apply is doubly gated and staged** — tier by tier (hub/firewall → DNS → network-dependent
  workloads → the rest), each tier approved, because a downstream plan is only valid once its
  upstream is applied (§6.3).
- **Success criterion per component:** `plan` shows the intended adds and **no source-estate
  leakage** (§11), with the only-expected diff. A green plan that wires the wrong region is a
  *failure*.
- **The lint is a tripwire, not a proof.** It catches source-region *tokens* (§11); it cannot
  catch region-clean-but-semantically-wrong wiring (a transposed octet still inside the DR block,
  the right-named resource on the wrong subnet). **Human review of the `plan` is the real semantic
  gate.**

---

## 11. Correctness oracle — invariant lint

Cheap, mechanical, high-value. Run on every generated DR root; any hit fails the component. A DR
root must contain **none** of the source-estate markers (source-region tokens, source CIDR blocks,
source resolver/firewall IPs, the source pipeline identity, source TFC workspaces, a non-DR
`Environment` tag, source-depth module paths) — and **must** contain the expected DR markers (DR
region token, DR name prefix, the correct DR CIDR block for its tier).

The authoritative pattern set is **committed as an executable lint** (`engine/lint.sh`, or a
patterns file it reads) — the single run-time source, validated against the Phase-1 roots as a
known-good fixture; the human-readable table in
[`profile/transform-rules.md`](profile/transform-rules.md) points at it (§16.14). It runs inside
the fan-out via the thin exec agent of §16.13 — a deterministic tripwire (the script, not an LLM,
is the check) — **necessary but not sufficient** (the real semantic gate is the human plan review,
§10).

A **second deterministic check** guards the *flag-don't-guess* rule (§7): reconcile each emitted
root against its manifest. Every cross-component value left at `null`/default in the HCL must have
a matching `consumes[]` / blackboard entry, and every blackboard entry must point at a real
unresolved reference. A mismatch means a Builder either hallucinated a value it should have
deferred, or deferred one it actually hardcoded — the failure mode an LLM is most prone to. Runs
at the end of Phase 2.

---

## 12. Scope — discovered, not catalogued

The in-scope set is **derived at run time**, never a maintained list (which would drift, §1):

1. **Discover.** Enumerate the roots under the source-root locations (`profile/repo-map.md`) on
   the pinned commit (§4). Whatever is there *is* the candidate set — a new source component is
   picked up automatically.
2. **Exclude (the guardrail).** Subtract `profile/scope-rules.md` — the *only* hand-maintained
   scope artifact, small and security-reviewed. Exclusions are deliberate policy → pinned;
   inclusions are discovered → never stale.
3. **Order (derived).** Apply order comes from the dependency DAG (§6), not hand-assigned tiers —
   "failover-critical first" falls out of the graph.
4. **Record (output, not source).** The concrete in-scope list for a run is written to
   `run-report.md` — a snapshot, never a file to keep up to date.

The pre-staged Phase-1 roots (`profile/repo-map.md`) are excluded from regeneration — they are the
cold-standby footprint. Data-bearing services (databases, storage, messaging, registries, key
vaults, …) are **always in scope**, built *empty*; the customer restores the data (§1).

**What gets signed off is the *rules*, not an inventory (§16.1)** — the `profile/scope-rules.md`
exclusion set, once. Everything else, discovery handles.

---

## 13. Out-of-band prerequisites (gate every apply; agents emit, don't perform)

The orchestrator surfaces these as a **checklist**; they are manual and the agents never perform
them. The concrete list — resource-provider registration, a TFC workspace per DR root (Local
execution mode), the DR GitHub environment's OIDC + secrets, quota/zone confirmation, and the
customer-owned data restore — lives in [`profile/prerequisites.md`](profile/prerequisites.md).
The companion [`profile/preflight.md`](profile/preflight.md) holds the **gotchas & decisions** to
confirm before a build (e.g. the storage account-failover check) — judgement calls, not provisioning.

---

## 14. Pitfalls & accepted limitations

1. **Cold plan-only is partial** (§6.3) — mitigated by staged ordering and the invariant lint.
2. **Data ≠ code** — generation yields empty infra *by design*; data recovery is the customer's
   (§1).
3. **Approval + cost + startup time** — failover apply of hub + firewall + compute is paid and
   slow; every run is human-gated.
4. **Semantic vs textual transform** — blind replace corrupts data; hence LLM builders + lint.
5. **Module / provider drift** — read module `variables.tf` live; never a stale POC.
6. **Generated-code disposition** — committed PR (audit) vs ephemeral (clean): §16.2.
7. **Graph cycles** — the Orchestrator must detect, not assume a DAG.
8. **Scope creep** — discovery widens automatically as the repo grows; the `scope-rules.md`
   guardrail (§12) is what keeps the set bounded, so it must stay reviewed.
9. **Estate confusion (the worst case)** — an agent mutating the live source estate. Made
   *structurally* impossible by the four isolation levels in §1, not merely by prompt
   instructions.

---

## 15. File layout

Two halves that ship separately — the blueprint travels as a plugin, the binding layer lives in the
estate's own repo — which is why no engine script resolves a path relative to its own location
(§16.13), and why every estate path below is a *pointer to a profile row*, never a literal.

**The blueprint (the plugin)**

```
agentic-dr/
├── ARCHITECTURE.md         # this file — the estate-agnostic blueprint
├── README.md               # what the system is and why it is built this way
├── workflows/dr-build.js   # the Orchestrator — committed Workflow script (§8, §2.2)
├── engine/                 # the deterministic half — no LLM anywhere in here (§11, §16.14)
│   ├── lint.sh             # invariant lint runner (§11); reads the profile's lint-patterns.txt
│   ├── reconcile.mjs       # second oracle (§11) — manifest↔HCL flag-don't-guess reconciliation
│   ├── resolve.mjs         # Phase-3 resolver (§8) — DAG, apply order, state files, DR pipeline job stanzas (§16.12)
│   └── gitops-rewrite.mjs  # GitOps overlay rewriter (§8 Phase G, §16.15) — copies the profile's GitOps source_dir into its target_dir, substituting; reads profile/gitops-substitutions.json
├── skills/dry-run/         # Mode 1 entrypoint — generate + check, never apply (§2.1)
├── skills/failover/        # Mode 2 entrypoint — generate, then the gated plan/apply/triage (§2.1)
├── skills/fix/             # Mode 3 entrypoint — adaptive remediation of one service (§2.1)
├── skills/update-profile/  # the profile-maintenance skill
├── docs/build-procedure.md # Phases 1–3, shared verbatim by dry-run and failover
├── agents/                 # dr-component-builder (§2.2, §7) · dr-plan-validator · dr-dynamic-remediator (§3, §16.7)
├── docs/                   # the profile contract, the state-file schemas, the two rule-file formats, the operating guide
├── profile.example/        # a filled-in fictional profile — the contract is docs/profile-contract.md
├── fixtures/ · tools/      # what makes the deterministic half verifiable standalone
└── .claude-plugin/         # the plugin manifest
```

**The binding layer and the estate (the consuming repo)** — `<framework-dir>` is `agentic-dr/` by
convention, overridable with `AGENTIC_DR_DIR`:

```
<framework-dir>/
├── profile/                # the per-estate binding layer — contract in docs/profile-contract.md
│   ├── context.md          # customer, CSP, regions, subscriptions, mgmt group, tokens
│   ├── naming.md           # name scheme + source→DR name transform
│   ├── network.md          # CIDR transform map, DNS + egress posture
│   ├── identity.md         # DR identity + the four isolation bindings
│   ├── repo-map.md         # source/DR root locations, module paths, pipeline, TFC scheme
│   ├── transform-rules.md  # exhaustive transform + invariant-lint patterns (guardrail) → points at lint-patterns.txt
│   ├── lint-patterns.txt   # machine-readable lint token set — the single run-time source for lint.sh (§11, §16.14)
│   ├── scope-rules.md      # exclusion guardrail (what discovery drops) + GitOps platform/core-vs-data-plane split (§16.15)
│   ├── gitops-rules.md     # GitOps overlay rules + value classes + completeness guard (human doc, §16.15)
│   ├── gitops-substitutions.json # machine-readable GitOps prod→DR rule set — the run-time source for gitops-rewrite.mjs
│   ├── global-services.md  # global/non-regional services + DR-handling bucket (don't-clone singletons)
│   ├── process.md          # the customer DR process / RACI / trigger
│   ├── prerequisites.md    # out-of-band provisioning that gates apply
│   ├── preflight.md        # gotchas & decisions to confirm before a build (e.g. storage failover)
│   └── region-gaps.md      # Mode 3 adaptive-remediation log + write-back target (§16.10)
└── state/                  # §9 run artifacts — the AI's run-tracking files  [runtime]
    │                       # schemas + the advisory-lock convention: docs/state-files.md (§16.11)
    ├── .gitignore          # whitelists the committed durable files; ignores status.json / manifests/ / build.lock
    ├── build-plan.md        # §8.1 preflight: what will / won't be built + manual work (authorized before fan-out)
    ├── status.json          # live per-component run status (git-ignored, transient)
    ├── manifests/           # per-component Builder manifest + lint/reconcile result (git-ignored intermediates)
    ├── blackboard.md        # unresolved cross-component values the Orchestrator works down
    ├── dependency-graph.md  # the DAG + computed apply order + cycle report
    ├── run-report.md        # the actual outcome: pinned SHA, in-scope list, what built / blocked, residue
    └── gitops-report.md     # GitOps overlay build report: AUTO substitutions, POST-APPLY/DECIDE residue, guard result (§16.15)

<source roots>              # read-only to the build; located by repo-map.md
<shared modules>            # read-only to the build; located by repo-map.md
<DR output tree>            # GENERATED Terraform roots; located by repo-map.md
<gitops source_dir>         # source platform/core + application manifests, read-only to the build; located by gitops-substitutions.json
<gitops target_dir>         # GENERATED platform/core overlay (gitops-rewrite.mjs output, §16.15); same file
```

The GitOps trees sit outside `<framework-dir>`: they are the estate's own manifests, not run
artifacts. Where exactly is the profile's business.

The blueprint (this file, the agent personas, the Orchestrator, the skills) is estate-agnostic; the
`profile/` folder is the only part that changes per estate. Nothing changes the DR output tree until
a Builder runs; Builders write DR roots there and the diff is reviewed as a PR.

---

## 16. Design decisions — all locked

Numbering is stable — items are cross-referenced throughout this document and from the personas
and the profile; entries are never renumbered. **All decisions are LOCKED (1–15).** Each
entry records the decision + rationale; the mechanics live in the body section it points to.

1. **Scope guardrails (§12) — LOCKED.** The `profile/scope-rules.md` exclusion set is signed off
   as written — including its one live trade-off: **the observability stack is excluded at the
   first cut**, so the freshly-built DR estate runs without its own alerting/dashboards until a
   later iteration adds them back. The policy call the sign-off forced is resolved by §16.9. The
   concrete exclusions live in the profile, not here; revisit only to add observability back.
   - **Amendment (observability split).** Tracing the dependency graph showed "exclude the
     observability stack" was too broad: the **telemetry sinks** (Log Analytics + Azure Monitor
     workspace) carry *inbound* dependencies — the AKS root hard-depends on them (a cold-region
     `data` lookup at a missing Azure Monitor workspace fails the AKS plan, §6) — so excluding them
     *adds* friction. Only the **alerting/dashboard leaves** (alerts, alert-processing-rule,
     action-group, grafana) are true pure-consumers safe to defer. The split is now in
     `profile/scope-rules.md`: **sinks in scope, leaves excluded.** This narrows the locked
     exclusion (it builds *more*, not less) and keeps the cold-standby footprint cheap (empty
     workspaces, no data to restore).
2. **Generated-code disposition (LOCKED — commit).** The generator commits DR roots as a
   reviewable PR: git is the audit trail and the baseline Mode 1's drift check diffs against. The
   first Mode 1 run *establishes* the baseline; drift checks are meaningful from run two.
3. **State-file disposition (LOCKED — commit the durable ones).** Commit `build-plan.md`,
   `blackboard.md`, `run-report.md`, `dependency-graph.md` (history + dead-laptop resume, §8);
   git-ignore `status.json` as transient.
4. **Peacetime trigger (LOCKED — manual only).** No scheduled automation, no standing drift check.
   Runs happen on a branch: generate → human review → optionally a plan-only pipeline run with
   explicit approval. Nothing larger.
5. **Build order of the system itself (LOCKED).** Profile guardrails → invariant lint →
   the Orchestrator → the entrypoint skills, validating each on the Phase-1 roots as a known-good
   fixture.
6. **Dynamic-mode scope (LOCKED — generic, file-driven).** Customer-agnostic, driven by the
   `profile/` files — no customer-specific hardcoding; the profile scopes it to DR for the first
   cut.
7. **Mode build sequencing (LOCKED).** Mode 1 (dry-run) first and fully — the safe, testable core
   — then Mode 2 (failover) on top, Mode 3 (dynamic) last (it depends on the Plan Validator and
   the diagnosis patterns the first two establish).
8. **Bootstrap-secret hand-off (LOCKED — external KV replication).** Key Vault replication from
   the primary region pre-provisions the DR vault *and its secrets* outside the agentic build; the
   build only wires workloads to the already-populated vault, sequenced by the apply order (§6.3).
   Supersedes "pre-stage empty + populate at failover"; revisit only if a vault DR workloads need
   falls outside replication coverage. (Seam described in §1.)
9. **Policy / compliance parity (LOCKED — out of scope).** Policy-as-code is not operational for
   the customer — a partial, unfinished policy root exists but is **excluded**
   (`profile/scope-rules.md`), so nothing is mirrored and DR carries no policy guardrails at the
   first cut. Revisit if/when policy-as-code is completed and introduced for prod.
10. **Mode 3 write-back (§3) — LOCKED.** An approved + applied Mode 3 remediation **auto-drafts a
    PR** to a new `profile/region-gaps.md` (rationale + revisit trigger) so the fix isn't lost to
    one run — **not** into the mechanical `transform-rules.md`, because a region-parity workaround
    is point-in-time and would carry a stale hack forever. Human-reviewed, never auto-merged.
    Implemented when Mode 3 is built (§16.7).
11. **Concurrent-run advisory lock (§8/§9) — LOCKED.** TFC's per-workspace state lock is the real
    safety net; what's missing is *human coordination* — a lightweight committed advisory lock in
    `<state-dir>/` so two engineers don't both start a fan-out, and session control hands
    over cleanly on a dead laptop. Advisory only. Built with the Orchestrator (§16.5).
12. **DR pipeline wiring for generated roots (LOCKED — the Orchestrator emits the job stanzas).**
    Generated DR roots need pipeline jobs; the **Orchestrator (never a Builder)** regenerates the
    per-component job stanzas from the computed apply order (`dependency-graph.md`) into the
    single DR pipeline file, in the same reviewed PR as the roots. Generated-from-truth, not
    hand-maintained — so it is not the drift §1 forbids — and the existing pipeline structure
    stays intact. The scoped write-path carve-out this requires is recorded once in §1 (write
    path, level 4).
13. **Where the deterministic steps execute (LOCKED — thin exec agent on a committed script).**
    Workflow scripts have no filesystem access, so: discovery + build plan in the skill / main
    loop (the Workflow can't pause for the §8.1 gate), passed in via `args`; the §11 lint and
    Phase-3 state writes inside the Workflow via a **thin spawned agent that execs the committed
    script** — a trivial exec it cannot meaningfully get wrong, so the determinism (§16.14) is
    preserved. Recorded in the flow, §8.
14. **Lint as a committed executable, not prose (LOCKED — with §13).** An LLM translating the
    pattern table into greps at run time would forfeit the lint's determinism. The executable lint
    (`engine/lint.sh`, or a patterns file it reads) is committed as the single source,
    `transform-rules.md` points at it, and it is validated against the Phase-1 roots (§16.5).
    Committed script = the determinism; the §16.13 agent = the exec. Recorded in the oracle, §11.
15. **Platform/core GitOps overlay regenerated, not hand-maintained (LOCKED).** The platform/core
    GitOps layer (the profile's `source_dir`) is brought to DR by *regenerating* it into the
    profile's `target_dir` on every build — never by inline DR labels in the source manifests, and
    never by a hand-maintained sidecar registry (both couple prod to DR and rot). The prod manifests
    stay pristine; the overlay is generated output that can't drift. The substitution is rule-driven
    by `profile/gitops-substitutions.json` (the GitOps analogue of `lint-patterns.txt`), reusing the
    same naming/CIDR transforms as the Terraform estate, so a new source-prefixed value is rewritten
    automatically — and the completeness guard fails the build if one isn't, so the rules can't
    silently rot. **Scope is discovered, not catalogued** (§12): the engine enumerates every component
    under the `source_dir` and subtracts a pinned `exclude` list, so a new platform/core
    component is covered automatically — only the data-plane exclusions are pinned. Three value
    classes: **AUTO** (derivable now), **POST-APPLY** (an identity client id, a resource id that
    exists only once another root applies — resolved at failover from the producing DR root's
    Terraform output, which `gitops-rules.md` names per slug), **DECIDE** (an allowlist or a zone a
    human must confirm).
    POST-APPLY/DECIDE leave a `__DR_…__` sentinel; a **sentinel gate** (no `__DR_` left in the overlay)
    blocks the failover commit so a broken manifest never syncs. The mechanical rewrite runs in the
    Workflow (§8 Phase G); the interactive residue + commit run in the skill (§2.2). **This supersedes the prior "the build
    never copies the GitOps manifests" rule** (old `preflight.md` line / §17 stage 2): it refines the
    §1 boundary — platform/core GitOps is platform-owned, application GitOps stays data plane — it
    does not widen it. The lint lives inside `gitops-rewrite.mjs` (not `lint.sh`, which lints only
    `*.tf`/`*.tfvars`). Detail: `profile/gitops-rules.md`, §1 amendment, §8 Phase G.

---

## 17. DR lifecycle & failback

The agentic build is **one stage** of a customer-driven failover lifecycle (concrete process in
`profile/process.md`). The agents own only the DR-estate work (stages 1 and 5); the source estate
is read-as-truth and **never mutated** at any stage (§1).

1. **Build DR — agents, additive.** Generate + plan + apply the DR estate (Modes 1/2), triggered
   by the customer's DR request (§2). The source estate untouched.
2. **Populate — customer + GitOps.** The customer restores data into the empty resources. GitOps
   provisions the manifests onto the DR cluster: the **platform/core** overlay is the build's own
   generated overlay in the profile's `target_dir` (regenerated in stage 1, §16.15) — once on `main` with its POST-APPLY
   sentinels resolved, the DR ApplicationSet syncs it; the **application** manifests are the
   customer's data-plane job (§1, §16.15).
3. **Cutover — customer-led, gated.** Route live traffic to the DR region at the edge
   (origins / DNS). Deliberate, narrowly-scoped, **out-of-band from the build fan-out** (§1)
   because it may touch a source-/globally-managed resource.
4. **Failback — human, gated.** When the source region recovers, route traffic back. The source
   was never torn down, so failback is a **routing change, not a rebuild**.
5. **Clean up DR — agents, DR-scoped, explicit.** Tear down the expensive Phase-2 resources,
   keeping Phase-1 per the cold-standby posture. **The only `destroy` the agents ever perform, and
   all four §1 isolation levels still apply.** A separate, fully-gated invocation (a future
   `/agentic-dr:cleanup`), never part of a build run.

> The hazard this lifecycle prevents — an agent "getting confused" mid-failover and mutating live
> source resources — is made structurally impossible by §1's four isolation levels; the
> cutover/failback switches stay human-driven for the same reason.
