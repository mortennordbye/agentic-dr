# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working approach

These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### Think before coding

Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### Simplicity first

Minimum code that solves the problem. Nothing speculative.

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### Surgical changes

Touch only what you must. Clean up only your own mess.

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: every changed line should trace directly to the user's request.

### Goal-driven execution

Define success criteria. Loop until verified.

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

### Track unfinished work in BACKLOG.md

If you leave anything unfinished, partially implemented, or explicitly defer it, add an entry to `BACKLOG.md` in the repo root before reporting the task done. Don't bury deferrals in chat — they vanish next session.

Each entry needs four things: **what** the work is, **why** it was deferred, **what would unblock it**, and **where** the relevant code lives (file paths). Read existing entries for the format.

Don't put work-in-progress on `BACKLOG.md` — WIP belongs on a branch. The backlog is for *known gaps the team has agreed to leave for later*. If you finish an item, delete it.

What counts as "unfinished":
- Tier 1 / Tier 2 splits where you only shipped Tier 1.
- Out-of-scope items you noticed but didn't fix.
- Features behind a feature flag that still need ramping or cleanup.
- Tests skipped, mocks left in, debug logging not yet stripped.
- TODO comments you wrote (write the entry instead — TODOs rot in code).

What does NOT belong:
- Forward-looking ideas the user didn't agree to defer ("we could also..."). Either do them or drop them.
- Codebase-wide debts that pre-existed your work and the user didn't ask you to track.

### No AI attribution in commits

Commits and PRs read as the human author's. No AI fingerprint, ever.

- No `Co-Authored-By` trailer naming Claude or any AI.
- No session links or IDs (e.g. a `Claude-Session:` trailer).
- No "Generated with Claude Code", 🤖 emoji, or similar tool signatures in commit messages, PR descriptions, or issue bodies.
- Describe the change, not the tool that produced it.

These guidelines are working if: fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.

## Development

There is no application to run and nothing to install: the engine uses only Node builtins and
bash. Everything below works from a clean clone.

```bash
# test:     bash tools/test.sh          (the whole suite; includes both scrub-gate modes)
# lint:     shellcheck engine/*.sh tools/*.sh demo/*.sh
# validate: claude plugin validate . --strict
# scrub:    bash tools/scrub-check.sh --history
```

The container and `.env` guidance from the blueprint is deliberately dropped: this ships as a
Claude Code plugin, holds no configuration, and reads no environment beyond two optional
overrides (`AGENTIC_DR_DIR`, `SCRUB_PATTERNS`).

## Before reporting a task complete

```bash
# verify: bash tools/test.sh && shellcheck engine/*.sh tools/*.sh demo/*.sh && claude plugin validate . --strict
```

Run it even when the change looks obviously correct. Skip rules: none. A doc-only change still
runs it, because the suite asserts things *about* the docs — that the blueprint names no estate
path, and that no agent is referenced by a name that would not resolve.

If you touch the diagram, re-render `docs/agentic-dr-build-diagram.png` from the `.html` beside
it at 2600x1400. A stale PNG is drift no gate can see.

## Security baseline

The blueprint's baseline covers network, auth, and data surfaces. **This project has none** — no
endpoints, no sessions, no database, no runtime credentials — so that section is skipped, as it
instructs. What replaces it is narrower and stricter, because the failure modes here are
different:

- **Never commit an estate identifier.** The repository is public, and a force-push does not
  reliably retract a blob. `tools/scrub-check.sh` is the gate; run `--history` before pushing.
  It checks *shapes* (GUID, IP, FQDN), so it cannot catch a bare word — a company name, a person,
  a region. Keep a private supplementary patterns file outside this repo and point
  `SCRUB_PATTERNS` at it. This is not theoretical: a bare region name once survived the
  extraction and passed every automated gate.
- **Blast-radius isolation is the product's core safety property**, not a feature. The four
  levels in `ARCHITECTURE.md` §1 — identity, state, pipeline, write path — are load-bearing.
  Never weaken one to make a build work.
- **Never widen a gate to make a test pass.** If the scrub gate rejects something, the answer is
  usually to change the thing, not the pattern. Allow-listing is for values that are genuinely
  this repo's own, one entry each, never a broadened regex.

## Architecture

An agent system that regenerates a disaster-recovery Terraform estate on demand from current
`main`, rather than maintaining a parallel copy that drifts. Read `ARCHITECTURE.md` for the
design and the numbered decision log; the sections below are only what you need to work here.

The split that governs everything: **the blueprint is estate-agnostic, the profile is not.**

| Half | Where | Contains |
| ---- | ----- | -------- |
| Blueprint | `ARCHITECTURE.md`, `engine/`, `agents/`, `skills/`, `workflows/`, `docs/` | no customer, region, CIDR, identity, subscription, or repo path |
| Profile | the consuming repo's `agentic-dr/profile/` | every one of those bindings |

`profile.example/` is a filled-in fictional profile; its contract is `docs/profile-contract.md`.

### Safety rules for AI-assisted changes

The invariants unique to this system. Each one is asserted in `tools/test.sh`, so breaking one
turns the suite red rather than shipping quietly:

- **No estate path in the blueprint.** Source-root locations, DR output trees and GitOps
  directories are profile rows. Write a pointer to the row, never the literal.
- **Reference plugin agents by their scoped name** (`agentic-dr:dr-component-builder`). A bare
  name does not resolve, and nothing errors — you silently get a generic agent with no persona,
  writing the estate.
- **A workflow's `meta.name` must not match a skill directory.** It shadows the skill, and the
  caller gets a dispatch shim instead of the approval gates.
- **Nothing resolves relative to a script's own location.** The engine ships in the plugin, the
  profile ships in the estate; neither may assume where the other is.
- **`${CLAUDE_PLUGIN_ROOT}` is substituted in skill and agent content only.** `docs/` is *read* by
  a skill, not loaded as one, so the variable arrives unexpanded there and silently yields
  `/engine`. `docs/build-procedure.md` says `<plugin-root>`; the skill that sends you there states
  the real path.
- **The deterministic half must stay deterministic.** `engine/` contains no LLM call and never
  will. That is what makes it a correctness oracle rather than another opinion.

### Directory layout

```
agentic-dr/
├── engine/          # the deterministic scripts — no LLM: lint, reconcile, resolve, gitops-rewrite
├── workflows/       # the Orchestrator (a Claude Code Workflow script)
├── agents/          # the three LLM personas
├── skills/          # the three entrypoints (dry-run, failover, fix) + profile maintenance
├── docs/            # profile contract, state-file schemas, rule formats, operating guide,
│                  #   and build-procedure.md — Phases 1–3, shared by dry-run and failover
├── profile.example/ # a fictional filled-in profile
├── fixtures/        # what makes the deterministic half verifiable standalone
└── tools/           # the test suite and the release gate
```

### Key patterns

- **Fixtures are golden output, not hand-authored.** `fixtures/gitops/expected/` is regenerated
  by running the engine; edit the source and re-run, never edit the expected tree to match.
- **Assertions must be able to fail.** Several checks here were written, passed, and turned out
  to assert nothing. When adding one, mutate the code to prove it goes red.
- **Surface, never swallow.** A stale exclusion, a halted cycle, a residual token: report it in
  both the JSON contract and the human report. Silence is the failure mode this project is built
  against.

### Code quality

- **Reuse before adding** — check shared utilities and components before writing new ones.
- **Prefer established frameworks over reinventing** — reach for a well-maintained, widely-used library or framework before hand-rolling auth, routing, state, validation, dates, HTTP, and the like. The same goes for the UI: build on a proven component library or design system (e.g. shadcn/ui, Radix, MUI, Chakra) instead of hand-rolling buttons, modals, dropdowns, and form controls — you get accessibility, keyboard handling, and a consistent look for free. Mature libraries are battle-tested and keep the app feeling consistent; bespoke versions drift and rot. Only build your own when no good option fits, and say why.
- **Use current, supported versions** — pick libraries that are actively maintained and pull a recent, supported release. Avoid end-of-life or abandoned dependencies; an unmaintained library is a security and upgrade liability.
- **No dead code** — if a button has no handler, implement or remove it.
- **No premature abstractions** — only extract a helper when it's used in 2+ places.
