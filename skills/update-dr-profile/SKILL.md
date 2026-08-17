---
name: update-dr-profile
description: >-
  Audit and update the agentic DR build profile (profile/) after the source
  estate changes — new/renamed/deleted roots, new hardcoded ARM ids or subscription GUIDs, resources
  needing special DR handling, or a decision only a human can make. Produces a scoped diff plus a
  verification run of the invariant lint. Use whenever a change lands (or is about to) under any
  source-root location the profile's repo-map names, when asked to check the DR profile is current,
  or before a /agentic-dr:dr-build run.
---

# Keep the DR build profile current

`profile/` is the only thing that tells the agentic DR build what the estate looks like.
The generated estate under the DR output tree is disposable and rebuilt from `main` every run, so
**a stale profile is the one failure mode a rebuild does not fix.** It fails quietly: the build
succeeds, and the wrong estate comes out.

Read `docs/profile-contract.md` first — it holds the file-by-file contract and the maintenance
rules. This skill is the procedure for applying them.

## The two rules that decide every edit

**1. Write the finished state, not today's snapshot.** When a migration is agreed and in flight,
write the profile for the estate as it will be *once that work lands*. Do not describe an
intermediate state and plan to update again — the double update costs a review cycle each time and
nobody ever builds against the middle. The line is *agreed*, not *imagined*: a decided migration with
work underway, yes; a speculative design, no.

**2. Write rules, never inventories.** The engine reads the source roots itself. Anything discovery
can see — which accounts exist, which grants a service holds, which topics a namespace has, which
services are mid-migration — must not be copied into the profile. Write the rule that routes the
decision (`route by the dr-level tag`; `rewrite every ARM id in targets`) and let the build supply
the data.

> If you catch yourself typing a resource name, a count, or a per-service status table, stop. It
> belongs in the source root or in your own docs — not in the profile. A hand-written
> inventory goes stale the moment the estate moves, and it goes stale *silently*.

Corollary: **inclusions are discovered, exclusions are pinned.** Never maintain a list of in-scope
roots. A new root needs no profile edit unless it must be dropped or needs handling the generic
transform rules do not give it.

## Procedure

### 1. Find what changed since the profile last moved

`<source-roots>` and `<modules>` below are the locations `repo-map.md` names — read them from the
profile and substitute before running. They are not fixed by this framework.

```sh
git log --oneline -1 -- profile/
git diff --stat <that-sha>..HEAD -- <source-roots> <modules>
git diff --name-status <that-sha>..HEAD -- <source-roots> | grep -E '^[AD]'
```

Also list the current roots and read them against `scope-rules.md`, since a root added long ago may
never have been classified:

```sh
ls -d <source-roots>/*/
```

### 2. Classify each new or changed root

Work down this list. Most roots need **no edit at all** — that is the correct outcome.

| Question | If yes |
| -------- | ------ |
| Should it be **dropped** from DR (dev/test/stage, out of scope, half-built, a pure consumer like alerting)? | pin it in `scope-rules.md` **with the reasoning**, not just the name |
| Is it **global / non-regional / per-subscription** (global singleton, already replicating to the DR region, globally-unique name, subscription-scoped)? | classify into a bucket in `global-services.md` |
| Does it have a **hand-authored DR twin** that must never be overwritten? | `scope-rules.md` (protect both sides) **and** the pre-staged row in `repo-map.md` |
| Does it need handling the generic rules miss (ordering, a value not derivable at codegen, a cross-subscription reference)? | `transform-rules.md`, plus `preflight.md` if a human must confirm it |
| Otherwise | **nothing** — discovery covers it |

### 3. Hunt for new leakage tokens

This is the step most often skipped, and the one that catches real bugs. Source roots routinely pass
fully-qualified ARM ids and cross-tier resource names through tfvars; a Builder that copies one
either fails at apply or, worse, points the DR estate back at a source-region resource.

```sh
# Subscription GUIDs, in-scope roots only. <SOURCE_ROOTS> comes from profile/repo-map.md.
grep -rnoE '/subscriptions/[0-9a-f-]{36}' <SOURCE_ROOTS> | sort -u

# Cross-tier / shared-infra names reached by BARE NAME rather than ARM id — these slip past
# the GUID patterns entirely. Build the alternation from your estate's name prefixes
# (profile/naming.md) and widen it as new shared resources appear.
grep -rnE '<NAME_PREFIX_ALTERNATION>' <SOURCE_ROOTS>/*/[a-z]*.tfvars
```

Every GUID or shared-resource name that reaches a DR root must be either **rewritten by a transform
rule** or **forbidden by the lint**. Add the pattern to `lint-patterns.txt` (the runtime source) and
mirror it into `transform-rules.md`.

Before adding a `FORBIDDEN` pattern, check both directions:

- it **fires** on the source roots it targets (otherwise it is wrong or already covered)
- it does **not** fire on a DR root that carries the value legitimately. Some hand-authored roots do —
  a DR root whose private endpoint targets a source-region server by resource id has to carry that
  source subscription GUID. Those roots are pinned in `repo-map.md` and excluded from regeneration, so
  the lint never runs on them; say so in a comment next to the pattern, the way the existing
  exemptions do.

### 4. Keep the doc/runtime pairs in sync

Two files are read by machines; their prose twins are for humans and rot without anything failing.
Edit the runtime file first, then mirror it. **If they disagree, the runtime file wins.**

| Runtime (authoritative) | Prose twin |
| ----------------------- | ---------- |
| `lint-patterns.txt` | `transform-rules.md` |
| `gitops-substitutions.json` | `gitops-rules.md` |

### 5. Park what only a human can settle

A decision nobody has made, or a judgement that must be re-made per run, is a `preflight.md`
checkbox — never an invented default. Recording the open question **is** the deliverable.

Note the difference from rule 2: `preflight.md` holds *decisions and judgements*, not status. "Does
this Premium namespace want Geo-DR pairing?" is a preflight item. "Service X has not migrated yet" is
not — discovery reads that.

If the work is a known gap the team has agreed to leave for later, record it wherever your repo
tracks known gaps. The profile is not that place: it describes the estate, not the work queue.

### 6. Stamp the "Last reviewed" dates

`docs/profile-contract.md` carries a **Last reviewed** column, one row per profile file. Update
it before you finish.

- Stamp **every file you read and confirmed still matches the estate**, whether or not you changed it.
  A file confirmed correct and left untouched gets a fresh date — that is the point of the column, and
  it is what a git commit date cannot tell you.
- Leave a row alone if you did not actually read that file. A date that means "probably fine" is worse
  than an old one, because it stops anyone looking.
- Use the review date in `YYYY-MM-DD`, not a guess at today. Ask the user for the date if you do not
  have it; **do not** shell out to `date` and assume the machine clock is the intended one.

Add a row when a profile file is added; delete one when a file is removed. A row with no file, or a
file with no row, means the contract table has drifted.

### 7. Verify

```sh
# Your known-good DR roots must stay green — this is the regression check for a new pattern.
bash engine/lint.sh <a-clean-DR-root> profile/lint-patterns.txt

# A new FORBIDDEN pattern must FAIL a source root it targets (expected: violations listed).
bash engine/lint.sh <the-root-that-motivated-it> profile/lint-patterns.txt
```

Pick the known-good roots from the pre-staged rows in `repo-map.md`, and **only** the ones with no
legitimate source-region reference. A pre-staged root that carries a source subscription GUID or a
primary-region resource id on purpose is not a fixture — running the lint on it proves nothing and
will read as a failure.

Then run `/agentic-dr:dr-build dry-run` and read the build plan's *"will need manual work"* section. A
`preflight.md` item that never surfaces there, or a `scope-rules.md` exclusion reported as a stale
exclusion, means the edit did not land where the engine reads it.

## Landing it

Profile changes belong in the **same PR as the estate change that caused them**, not a follow-up.
Splitting them is how the profile falls behind.

State in the PR body which of the two rules drove each edit — finished-state vs snapshot, rule vs
inventory. That is what a reviewer needs to check, and it is not visible from the diff.

## Never

- **Never trigger a pipeline** (not even `plan_only`) without explicit user approval — and it
  applies to the DR pipeline above all.
- **Never edit the DR output tree as part of a profile update.** The profile describes; the build
  generates. The hand-authored roots there are protected for reasons documented per root in
  `scope-rules.md`.
- **Never widen scope by deleting an exclusion** without reading why it was pinned. Every exclusion in
  `scope-rules.md` carries its reasoning; that file is security-reviewed, because changing it changes
  what DR builds.
