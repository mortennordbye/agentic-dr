<div align="center">

<img src="assets/icon.png" alt="" width="84">

# Agentic DR

### Generate your disaster-recovery infrastructure on the day you need it, from the production code you already maintain.

![Terraform](https://img.shields.io/badge/Terraform-844FBA?logo=terraform&logoColor=white) ![Azure](https://img.shields.io/badge/Azure-0078D4?logo=microsoftazure&logoColor=white) [![Claude Code](https://img.shields.io/badge/Claude%20Code-D97757?logo=anthropic&logoColor=white)](https://code.claude.com) ![Node.js](https://img.shields.io/badge/Node.js-5FA04E?logo=nodedotjs&logoColor=white) ![Bash](https://img.shields.io/badge/Bash-4EAA25?logo=gnubash&logoColor=white)

[![CI](https://github.com/mortennordbye/agentic-dr/actions/workflows/ci.yml/badge.svg)](https://github.com/mortennordbye/agentic-dr/actions/workflows/ci.yml) [![Scorecard](https://api.securityscorecards.dev/projects/github.com/mortennordbye/agentic-dr/badge)](https://scorecard.dev/viewer/?uri=github.com/mortennordbye/agentic-dr)

[![License](https://img.shields.io/github/license/mortennordbye/agentic-dr?style=flat-square)](LICENSE) [![Last Commit](https://img.shields.io/github/last-commit/mortennordbye/agentic-dr?style=flat-square)](https://github.com/mortennordbye/agentic-dr/commits/main) [![Stars](https://img.shields.io/github/stars/mortennordbye/agentic-dr?style=flat-square)](https://github.com/mortennordbye/agentic-dr/stargazers)

Most DR estates are a second copy of production, maintained by hand. That copy rots. Production
changes, the DR copy does not, and you find out on DR day.

</div>

Agentic DR takes the other position: **do not maintain a standing DR pipeline — regenerate it on
demand from current `main`.** A generator driven off live production IaC is drift-proof by
construction, because its input is always today's truth.

It runs as a [Claude Code](https://code.claude.com) plugin, in your repo, as you. There is no service,
no API token, and no long-running agent.

```
/agentic-dr:dry-run       # generate + lint/validate. No cloud. Run this constantly.
/agentic-dr:failover      # generate → gated staged plan → gated staged apply → triage
/agentic-dr:fix <service> # adaptively remediate one service that will not come up in DR
```

Plugin skills are namespaced, hence the prefix. One skill per intent, so typing `/agentic-dr:`
lists what the system can do.

---

## Why agents rather than a templating engine

The cheap deterministic answer is Terragrunt, `generate` blocks, or region-parameterised modules. That
is rejected for three reasons:

1. **Retrofitting touches production.** Making your live roots region-parameterised means editing
   production code to enable DR. A generator that *reads* production as immutable and *writes* a
   separate estate keeps production untouched by construction.
2. **The hard part is cold-start ordering, not substitution.** In a cold region, a cross-root `data`
   lookup resolves *nothing*. Working out what can plan before what, and tracking the values that
   cannot exist until something else applies, is the actual problem. Templating leaves it undone.
3. **The transform is semantic, not lexical.** A blind CIDR sweep corrupts a partner's fixed IP, a
   comment, and any unrelated id that shares the prefix. Telling a region marker from a partner's
   allowlisted address requires understanding what the value *is*.

**Where a step is genuinely mechanical, it uses a grep, not a model.** Agents are applied only where
judgement is required. That line runs through the whole design.

## How it is put together

```
      ┌─────────────────────────────────────────────────────────┐
      │  entrypoint skill: dry-run │ failover │ fix             │
      │  (main loop: discovery, every gate)                     │
      └───────────────┬─────────────────────────────────────────┘
                      │  approved build plan + in-scope list
      ┌───────────────▼─────────────────────────────────────────┐
      │  Orchestrator (workflows/dr-build.js)                   │
      │  thin control plane — holds ALL global state            │
      └───┬──────────────────────────────┬──────────────────────┘
          │ one per in-scope root        │
      ┌───▼─────────────┐            ┌───▼───────────────────────┐
      │ Component       │  ......    │ deterministic oracles     │
      │ Builder (LLM)   │            │ lint.sh · reconcile.mjs   │
      │ minimal context │            │ NO LLM — cannot lie       │
      └─────────────────┘            └───────────────────────────┘
```

**A thin orchestrator over small-context workers.** The scarce resource in an LLM system is attention
over context. A model given one source root writes better Terraform than the same model holding the
whole estate, because as irrelevant context grows, boundaries blur and output drifts toward another
component's patterns. So each Builder gets one root and nothing about the others; the Orchestrator
alone holds the dependency graph, the blackboard and the apply order.

**Two deterministic oracles**, because the failure modes an LLM is most prone to are exactly the ones
a grep catches for free:

- `lint.sh` fails a generated root that leaked a source-estate token, or is missing a DR marker.
- `reconcile.mjs` enforces *flag-don't-guess*: every value the Builder deferred must have a matching
  `# DR-DEFER:` sentinel in the HCL, and every sentinel must have a matching manifest entry. A
  mismatch means the Builder either invented a value it should have deferred, or deferred one it
  actually hardcoded.

Neither is sufficient. **The real gate is a human reading the `terraform plan`.** A green plan that
wires the wrong region is a failure.

## Blast-radius isolation

DR is a failover, not a migration: production keeps running untouched while DR is built. The agents
must never modify, plan, apply or destroy anything outside the DR estate, enforced at **four
independent levels** so that a confused or hallucinating agent still cannot reach production:

1. **Identity** — the DR pipeline authenticates with a DR-only identity holding **no role** on the
   source subscriptions. Even a malformed apply *physically cannot* touch a production resource. This
   guarantee does not depend on the agents behaving.
2. **State** — DR state lives only in DR workspaces.
3. **Pipeline** — agents trigger only the DR pipeline.
4. **Write path** — Builders write only under the DR output tree.

And one rule above all: **no pipeline ever runs without explicit human approval, including
plan-only.** Apply is doubly gated — per tier by you, and server-side by the CI environment's
required reviewers.

## What it does not do

- **It is not a data-recovery tool.** Databases, storage and messaging are generated *empty* by
  design. Restoring data is the customer's data plane. The build's job ends at "infrastructure up and
  running".
- **It does not cut over traffic.** Routing is a customer-led decision, deliberately kept out of the
  agent fan-out.
- **It is not unattended.** Every cloud step is human-approved.
- **Cold plan-only is partial.** In a region where nothing exists yet, some plans cannot fully
  resolve. That is an accepted, documented limitation, mitigated by staged ordering and the lint.

## Blueprint and profile

Everything estate-specific lives in one directory.

- **The blueprint** — `ARCHITECTURE.md`, `engine/`, `agents/`, `skills/` — names no customer, region,
  CIDR, identity, subscription or repo path.
- **The profile** — your regions, naming scheme, IP plan, identities, repo layout, scope exclusions
  and lint tokens.

To adopt it, you write a profile. `profile.example/` is a complete fictional one; the contract is in
[`docs/profile-contract.md`](docs/profile-contract.md).

## Getting started

```bash
# 1. Install the plugin (both commands run inside Claude Code)
/plugin marketplace add mortennordbye/agentic-dr
/plugin install agentic-dr@agentic-dr

# 2. Copy the example profile into your infrastructure repo and fill it in
cp -R profile.example <your-repo>/agentic-dr/profile

# 3. Check the deterministic half works
bash tools/test.sh

# 4. Generate, without touching the cloud
/agentic-dr:dry-run
```

To try it without installing, clone the repo and run `claude --plugin-dir /path/to/agentic-dr`.

**No estate to point it at?** `demo/` is a fictional one, small enough to read in a sitting and
shaped to exercise a whole run: five roots, three of them in scope, a real cross-root dependency,
and a value the generator must defer rather than invent. Copy it somewhere scratch first —
`demo/README.md` explains why running a build in place is a bad idea.

Start with `dry-run`, and run it often. Mode 2 should never be a cold first run during an incident —
**test the machinery constantly so it works on DR day.**

## Requirements

- Claude Code
- Node 18+ and bash (no npm dependencies; the engine uses only Node builtins)
- Terraform, and a CI system that can run it
- Currently assumes **Terraform on Azure**. The architecture is not Azure-specific, but the lint's
  conditional rules and the example profile are.

## Repository structure

```text
agentic-dr/
├── engine/            # the deterministic scripts. No LLM: lint, reconcile, resolve, gitops-rewrite
├── workflows/         # the Orchestrator, a committed Claude Code Workflow script
├── agents/            # the three LLM personas: builder, plan validator, remediator
├── skills/            # the three entrypoints — dry-run, failover, fix — and profile maintenance
├── docs/              # the profile contract, state-file schemas, rule formats, operating guide
├── profile.example/   # a complete fictional profile — the only per-estate layer
├── fixtures/          # what makes the deterministic half verifiable standalone
└── tools/             # the test suite and the release gate
```

---

## Workflows

| Workflow | Trigger | Purpose |
| -------- | ------- | ------- |
| CI | push, PR | `tools/test.sh` (58 checks, both scrub-gate modes) and a blocking shellcheck |
| Dependency Review | PR | block a pull request that swaps in a vulnerable action version |
| Scorecard | push, weekly | OpenSSF supply-chain grade, published to the Security tab |
| Release Please | push to `main` | releases and a changelog from Conventional Commits |

---

## Documentation

| Document | What |
| -------- | ---- |
| [`ARCHITECTURE.md`](ARCHITECTURE.md) | The blueprint. Design, modes, dependency model, and every locked decision with its rationale. |
| [`docs/operating.md`](docs/operating.md) | Operator quickstart: how to invoke a run and read the output. |
| [`docs/profile-contract.md`](docs/profile-contract.md) | The profile contract and the six rules that keep it from going stale. |
| [`docs/global-services.md`](docs/global-services.md) | Classifying global and non-regional services. |
| [`docs/lint-patterns-format.md`](docs/lint-patterns-format.md) | The invariant lint's input format. |
| [`docs/gitops-substitutions-schema.md`](docs/gitops-substitutions-schema.md) | The GitOps overlay rewriter's rule set. |
| [`docs/scrub-gate.md`](docs/scrub-gate.md) | This repo's own release gate. |
| [Build walkthrough](https://mortennordbye.github.io/agentic-dr/) | An interactive walkthrough of a full run, served from `docs/`. |

## Status

Early. The design is complete and the deterministic half is covered by `tools/test.sh`. It has been
exercised as a dry run against a real estate, not yet as a live failover. Treat Mode 2 as
unproven-under-fire and read every plan.

## License

Apache-2.0. See [`LICENSE`](LICENSE).

---

<div align="center">

### ⭐ Star this repo if you find it useful ⭐

<a href="https://www.star-history.com/#mortennordbye/agentic-dr&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=mortennordbye/agentic-dr&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=mortennordbye/agentic-dr&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=mortennordbye/agentic-dr&type=Date" width="600" />
  </picture>
</a>

Made by [Morten Victor Nordbye](https://github.com/mortennordbye)

</div>
