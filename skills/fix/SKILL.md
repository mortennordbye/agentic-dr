---
name: fix
description: >-
  Adaptive remediation of ONE disaster-recovery service that will not come up — a region-parity gap
  or a misbehaving managed service (ARCHITECTURE.md Mode 3). Diagnoses via the dr-dynamic-remediator
  agent, proposes only invariant-safe alternatives, escalates rather than weaken isolation, and on
  approval implements a surgical fix and re-plans through the failover gates. Use when asked to fix,
  remediate or work around one failing service in the DR estate.
---

# /agentic-dr:fix &lt;service&gt; — adaptive remediation of one service (Mode 3)

Not regeneration — problem-solving against **one** failing service (a region-parity gap or a
misbehaving managed service). Reached deliberately, or escalated here by `/agentic-dr:failover`
Phase-5 triage (`route_to: human` / `escalate_to_mode3`).

Do not run a whole build to get here. If the service has no generated DR root yet, that is a
`/agentic-dr:dry-run` job first.

## The rules that still hold

1. **NEVER run `gh workflow run` — including `plan_only=true` — without explicit user approval.**
   Stop and ask every time (CLAUDE.md, ARCHITECTURE §10).
2. **DR estate only.** Read the source roots `profile/repo-map.md` names as immutable truth; write
   only under the DR output tree and state dir it names; trigger only the DR pipeline it names
   (ARCHITECTURE §1).
3. **The customer profile is authoritative** for every concrete value — never memory.

## Procedure

Spawn the **`agentic-dr:dr-dynamic-remediator`** agent with the failure + the affected DR root. It
diagnoses, then proposes only **invariant-safe** alternatives:

> **Hard invariants it may never propose violating** (ARCHITECTURE §3): no public exposure of an
> internal service, no egress bypass of the controlled path, no weakening of network isolation /
> encryption-at-rest / TLS, and DR-estate-only. If the only working option breaks one, it **stops and
> escalates to a human** instead of presenting it.

**[APPROVAL GATE]** the engineer picks an option → implement it as a surgical change to the affected
DR root (or record a manual step) → re-plan/apply through the `/agentic-dr:failover` gates. An
approved + applied fix **auto-drafts a PR** to `profile/region-gaps.md` (rationale + revisit
trigger), never into the mechanical `transform-rules.md` (§16.10). Human-reviewed, never auto-merged.

## What to report

The diagnosis, the options considered (including any rejected for violating a hard invariant), which
was approved, what changed in which DR root, whether it has been re-planned, and the
`profile/region-gaps.md` PR link.
