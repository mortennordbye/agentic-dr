# The profile contract

The framework is split in two. **The blueprint** (`ARCHITECTURE.md`, the engine scripts, the agent
personas, the skills) is estate-agnostic: it names no customer, region, CIDR, identity, subscription
or repo path. **The profile** is the only part that changes per estate.

This document is the contract between them. A profile is complete when every row below resolves to a
real value or a pointer to one. `profile.example/` is a filled-in, fictional instance of it.

## The files

| File | Role (what the blueprint needs) | Read by |
| ---- | ------------------------------- | ------- |
| `context.md` | customer, cloud, regions (source→DR), subscriptions, env/region tokens | orchestrator · humans |
| `naming.md` | resource-name scheme + the source→DR name transform | builders |
| `network.md` | CIDR transform map, DNS + egress posture | builders |
| `identity.md` | DR pipeline identity + the bindings that realise the four isolation levels | orchestrator · humans |
| `repo-map.md` | source-root locations, module-path convention, pipeline, state scheme, DR output path | orchestrator · builders |
| `transform-rules.md` | the concrete transform dimensions and their values | builders |
| `lint-patterns.txt` | the machine-readable token set `engine/lint.sh` greps for | linter |
| `pipeline-job.tmpl` | the CI job stanza `engine/resolve.mjs` renders per component | resolver |
| `scope-rules.md` | the exclusion guardrail (what discovery drops) | orchestrator |
| `global-services.md` | global / non-regional services and their DR-handling bucket | orchestrator · builders |
| `gitops-rules.md` | GitOps overlay rules + completeness guard (prose twin of the JSON), and the Terraform output each POST-APPLY sentinel resolves from | gitops builder · humans |
| `gitops-substitutions.json` | the machine-readable substitution/exclusion set the rewriter reads | gitops rewriter |
| `process.md` | the customer DR process / RACI / trigger this build plugs into | humans |
| `prerequisites.md` | out-of-band provisioning that gates apply | orchestrator · humans |
| `preflight.md` | judgement calls to settle before a build | orchestrator · humans |
| `region-gaps.md` | the Mode 3 remediation log: parity gaps and the workaround chosen | remediator · humans |

Segmented on purpose: an agent loads only the slice it needs. A Builder reads naming, network and
transform rules, and never `process.md`.

## Track a "Last reviewed" date per file

Add a `Last reviewed` column to your profile's own index and stamp it on every review pass.

**Reviewed means a human read the file and confirmed it still matches the estate — not merely that it
was edited.** An edit implies a review; a review does not imply an edit. A file confirmed correct and
left untouched still gets a fresh date. That is the entire point, and it is exactly what a git commit
date cannot tell you: a file whose content is fine but whose date is a year old is the state this
column exists to make visible.

## The six rules that decide every edit

The generated estate is disposable and rebuilt from `main` on every run, so **a stale profile is the
one failure mode that survives a rebuild.** These rules keep it from going stale.

1. **Rules, not inventories.** The engine reads the source roots itself. Anything it can see — which
   accounts exist, which grants a service holds, which services are mid-migration — must **not** be
   copied here. Write the rule that routes the decision and let the build supply the data. A
   hand-written inventory goes stale the moment the estate moves, and it goes stale *silently*,
   because nothing validates it. If you catch yourself typing a resource name, a count, or a
   per-service status table, it belongs in the source root or in your own docs.
2. **Pin exclusions, discover inclusions.** Never maintain a list of in-scope roots. The failure mode
   should be a needless DR root, visible in review, not a silently missing one.
3. **Thin bindings, not copies.** Where an authoritative source already exists, point at it and
   inline only the token the engine resolves. A copied GUID or CIDR is exactly the dynamic data that
   drifts. This applies *between* profile files too: state a fact in the file that owns it and link
   from the others.
4. **Runtime files are the source; prose points at them.** `lint-patterns.txt` and
   `gitops-substitutions.json` are read by machines and carry their own per-pattern reasons. The
   prose files describe the *shape* of those checks — they do not restate the lists, because a
   mirrored copy is one more thing to keep in sync and would lose anyway.
5. **Write the finished state, not today's snapshot.** Where a migration is **agreed and in flight**,
   write the profile for where it lands. Updating twice for the same facts costs a review cycle each
   time, and the intermediate state is the one nobody ever builds against. The line is *agreed*, not
   *imagined*.
6. **What only a human can settle is a `preflight.md` checkbox, not an invented default.** Recording
   the open question is the deliverable. This is narrower than it looks: `preflight.md` holds
   *decisions*, not *status*. "Does this namespace want geo-pairing?" belongs there; "service X has
   not migrated yet" is rule 1's problem, and discovery reads it.

## When to update

A profile change lands in the **same commit** as the estate change that caused it, never afterwards.

| Estate change | What it touches |
| ------------- | --------------- |
| A new source root | Nothing, **if** it should be regenerated. Inclusions are discovered — act only if it should be dropped, or needs handling the generic rules do not give it. |
| A root deleted or renamed | `scope-rules.md` if it was named there; `repo-map.md` if it was pinned |
| A resource that is global, per-subscription, or self-replicating | a bucket in `global-services.md` |
| A new hardcoded resource id, subscription id, or cross-tier name in a source root | `transform-rules.md` **and** `lint-patterns.txt` |
| A region/CIDR/naming decision | `naming.md` / `network.md` / `context.md` |
| A new pre-staged or hand-authored DR root | `scope-rules.md` (protect it) **and** `repo-map.md` |
| A decision a build cannot make for itself | `preflight.md` |
| Out-of-band provisioning that gates apply | `prerequisites.md` |
| A new env-specific value in a GitOps component | `gitops-substitutions.json` + `gitops-rules.md` |
| An applied Mode 3 workaround | `region-gaps.md` |

## Verifying a profile change

The lint must stay green on your known-good roots, and **a new FORBIDDEN pattern must actually fire
on the source root that motivated it** — a pattern that matches nothing is worse than no pattern,
because it reads as coverage. Then run `/agentic-dr:dry-run`.
