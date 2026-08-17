// The name must NOT collide with any `skills/<name>/` directory. A plugin's workflows are
// auto-discovered and each one is exposed as a dispatch skill under its meta.name, so a workflow
// sharing an entrypoint skill's name SHADOWS that skill: invoking it hands the caller a
// "call Workflow with these args" shim instead of the skill body, silently skipping Phase-1
// discovery, the build-plan gate and every approval gate this system is built around. The skills
// still reach this file by scriptPath, so the name here only has to stay distinct.
export const meta = {
  name: 'dr-build-fanout',
  description:
    'Generate the Phase-2 DR Terraform estate from a pinned main SHA (ARCHITECTURE §8): fan out one Builder per in-scope root, invariant-lint + reconcile each, assemble the dependency DAG, compute the apply order, write the state files, regenerate the DR pipeline job stanzas, then regenerate the platform/core GitOps overlay from the source overlay via the committed rewriter. No cloud; no pipeline trigger.',
  phases: [
    { title: 'Build', detail: 'one dr-component-builder per in-scope root → invariant lint + manifest reconcile (committed scripts)' },
    { title: 'Resolve', detail: 'assemble DAG, detect cycles, compute apply order, write state files, regenerate the DR pipeline job stanzas' },
    { title: 'GitOps', detail: 'regenerate the platform/core GitOps overlay from the source overlay + the GitOps rules (committed script); flag POST-APPLY / DECIDE residue for the skill' },
  ],
}

// ---------------------------------------------------------------------------------------------
// Input (from the /agentic-dr:dry-run or /agentic-dr:failover skill, which runs Phase-1 discovery + the
// build-plan gate in the main
// loop and pins the main SHA — ARCHITECTURE §8, §16.13). The Workflow script has no filesystem
// access, so every deterministic file operation (lint, reconcile, graph, state writes, pipeline
// emit) runs inside a thin exec agent that execs a committed script; the determinism lives in the
// script, not the agent (§16.13/§16.14).
//
//   args = {
//     sha:      "<pinned main commit SHA>",
//     inScope:  [ { component, source_root, target_root, tfc_workspace }, ... ],
//     pipeline: "<path to the DR pipeline file>",   // optional; from profile/repo-map.md
//     engine:   "<abs path to the plugin's engine dir>",  // REQUIRED; the scripts ship with the plugin
//     agenticDir: "agentic-dr",                     // optional; where profile/ and state/ live
//     builderAgent: "agentic-dr:dr-component-builder", // optional; see BUILDER_AGENT below
//   }
//
// Nothing here is estate-specific: `engine` locates the plugin's committed scripts, `agenticDir`
// locates the consuming repo's profile and state, and the skill fills both in from the profile.
// ---------------------------------------------------------------------------------------------
const { sha, inScope, pipeline: pipelinePath, engine: enginePath, agenticDir, builderAgent } = args || {}

if (!sha || typeof sha !== 'string') {
  throw new Error('dr-build.js: args.sha (the pinned main SHA) is required — the skill pins it on invocation (ARCHITECTURE §4).')
}
if (!Array.isArray(inScope) || inScope.length === 0) {
  throw new Error('dr-build.js: args.inScope must be a non-empty array of {component, source_root, target_root, tfc_workspace} — discovery + the build plan run in the calling skill (/agentic-dr:dry-run or /agentic-dr:failover) and pass it in (ARCHITECTURE §8, §16.13).')
}

if (!enginePath || typeof enginePath !== 'string') {
  // No default: the engine ships with the plugin and the estate has no copy of it, so guessing a
  // path here would fan out every Builder and only fail at the check stage, with a confusing
  // "no such file" from an exec agent. The calling skill fills this in from ${CLAUDE_PLUGIN_ROOT}.
  throw new Error('dr-build.js: args.engine (absolute path to the plugin engine dir) is required — the calling skill passes ${CLAUDE_PLUGIN_ROOT}/engine (ARCHITECTURE §16.13).')
}

const AGENTIC = agenticDir || 'agentic-dr'
const ENGINE = enginePath

// A plugin's agents resolve ONLY by their scoped `<plugin>:<agent>` name; the bare name does not
// resolve. That prefix is therefore load-bearing rather than decoration: drop it and the fan-out
// silently runs generic agents with no Builder persona, which is the one failure this whole design
// exists to prevent — a model with the wrong context writing the estate. Overridable for an
// installation that vendors the personas into .claude/agents/ instead of installing the plugin.
const BUILDER_AGENT = builderAgent || 'agentic-dr:dr-component-builder'
const PROFILE = `${AGENTIC}/profile`
const STATE = `${AGENTIC}/state`
const MANIFEST_DIR = `${STATE}/manifests`
const PIPELINE = pipelinePath || ''

// The Builder's manifest contract (agents/dr-component-builder.md). Forcing the schema makes
// the Builder return validated data instead of prose.
const MANIFEST_SCHEMA = {
  type: 'object',
  required: ['component', 'source_root', 'target_root', 'tfc_workspace', 'produces', 'consumes', 'prereqs', 'notes'],
  additionalProperties: false,
  properties: {
    component: { type: 'string' },
    source_root: { type: 'string' },
    target_root: { type: 'string' },
    tfc_workspace: { type: 'string' },
    produces: { type: 'array', items: { type: 'string' } },
    consumes: {
      type: 'array',
      items: {
        type: 'object',
        required: ['what', 'from', 'via', 'status'],
        additionalProperties: false,
        properties: {
          what: { type: 'string' },
          from: { type: 'string' },
          via: { type: 'string', enum: ['data-rename', 'override', 'post-apply', 'remote-state'] },
          status: { type: 'string', enum: ['resolved', 'blackboard'] },
        },
      },
    },
    prereqs: { type: 'array', items: { type: 'string' } },
    notes: { type: 'array', items: { type: 'string' } },
  },
}

// The thin exec agent's return shape (per-root lint + reconcile).
const CHECK_SCHEMA = {
  type: 'object',
  required: ['component', 'lint_pass', 'reconcile_pass', 'report'],
  additionalProperties: false,
  properties: {
    component: { type: 'string' },
    lint_pass: { type: 'boolean' },
    reconcile_pass: { type: 'boolean' },
    report: { type: 'string' },
  },
}

// The GitOps overlay rewriter's return shape (gitops-rewrite.mjs stdout).
const GITOPS_SCHEMA = {
  type: 'object',
  required: ['ok', 'generated_components', 'excluded', 'stale_exclusions', 'applied_count', 'post_apply', 'decide', 'violations', 'report'],
  additionalProperties: false,
  properties: {
    ok: { type: 'boolean' },
    generated_components: { type: 'array', items: { type: 'string' } },
    excluded: { type: 'array', items: { type: 'string' } },
    stale_exclusions: { type: 'array', items: { type: 'string' } },
    applied_count: { type: 'integer' },
    post_apply: {
      type: 'array',
      items: {
        type: 'object',
        required: ['component', 'file', 'slug', 'what', 'why'],
        additionalProperties: false,
        properties: {
          component: { type: 'string' }, file: { type: 'string' }, slug: { type: 'string' },
          what: { type: 'string' }, why: { type: 'string' },
        },
      },
    },
    decide: {
      type: 'array',
      items: {
        type: 'object',
        required: ['component', 'file', 'slug', 'what', 'why', 'kept'],
        additionalProperties: false,
        properties: {
          component: { type: 'string' }, file: { type: 'string' }, slug: { type: 'string' },
          what: { type: 'string' }, why: { type: 'string' }, kept: { type: 'boolean' },
        },
      },
    },
    violations: {
      type: 'array',
      items: {
        type: 'object',
        required: ['file', 'line', 'pattern', 'why', 'snippet'],
        additionalProperties: false,
        properties: {
          file: { type: 'string' }, line: { type: 'integer' }, pattern: { type: 'string' },
          why: { type: 'string' }, snippet: { type: 'string' },
        },
      },
    },
    report: { type: 'string' },
  },
}

// The Phase-3 resolver's return shape.
const RESOLVE_SCHEMA = {
  type: 'object',
  required: ['ok', 'apply_order', 'cycles', 'halted', 'halted_downstream', 'blackboard_open', 'report'],
  additionalProperties: false,
  properties: {
    ok: { type: 'boolean' },
    apply_order: { type: 'array', items: { type: 'array', items: { type: 'string' } } }, // tiers
    cycles: { type: 'array', items: { type: 'array', items: { type: 'string' } } },
    halted: { type: 'array', items: { type: 'string' } },            // cycle members + their closure
    halted_downstream: { type: 'array', items: { type: 'string' } }, // the closure alone
    blackboard_open: { type: 'integer' },
    report: { type: 'string' },
  },
}

function builderPrompt(item) {
  return [
    `Transform exactly one source Terraform root into its DR-region equivalent, per your persona`,
    `(the dr-component-builder agent) and the customer profile (${PROFILE}/).`,
    ``,
    `Inputs:`,
    `- component:     ${item.component}`,
    `- source_root:   ${item.source_root}`,
    `- target_root:   ${item.target_root}`,
    `- tfc_workspace: ${item.tfc_workspace}`,
    `- pinned SHA:    ${sha} (build only from the source as it is on this commit)`,
    ``,
    `Two orchestration conventions on top of your persona:`,
    `1. After writing the DR root, ALSO write your manifest JSON to ${MANIFEST_DIR}/${item.component}.json`,
    `   (create the directory if needed). Your returned value must be the SAME manifest object.`,
    `2. Flag-don't-guess is checked deterministically (ARCHITECTURE §11): for every value you defer`,
    `   to the blackboard (a consumes[] entry with "status":"blackboard"), leave the value unset in`,
    `   the HCL and mark that line with a trailing comment "# DR-DEFER: <what>" whose <what> matches`,
    `   the consumes[].what exactly. Do not add that sentinel for values you actually resolved.`,
  ].join('\n')
}

function checkPrompt(item) {
  const manifest = `${MANIFEST_DIR}/${item.component}.json`
  const check = `${MANIFEST_DIR}/${item.component}.check.json`
  return [
    `You are a thin exec runner. Do NOT edit any Terraform or source file. Run exactly these committed`,
    `deterministic checks against the generated DR root and report the result:`,
    ``,
    `  bash ${ENGINE}/lint.sh ${item.target_root} ${PROFILE}/lint-patterns.txt`,
    `  node ${ENGINE}/reconcile.mjs ${item.target_root} ${manifest}`,
    ``,
    `Both must exit 0 to pass. Then write a JSON file ${check} with shape`,
    `{"component":"${item.component}","lint_pass":<bool>,"reconcile_pass":<bool>,"report":"<combined output>"}`,
    `and return the same object. Report the actual command output verbatim in "report"; never invent a pass.`,
  ].join('\n')
}

function resolvePrompt() {
  return [
    `You are a thin exec runner. Do NOT edit any file by hand. Run exactly this committed deterministic`,
    `resolver, which reads ${MANIFEST_DIR}/*.json (+ *.check.json), writes ${STATE}/blackboard.md,`,
    `${STATE}/dependency-graph.md and ${STATE}/run-report.md, and regenerates ONLY the managed DR job`,
    `region inside ${PIPELINE || 'the DR pipeline file named by the profile'}:`,
    ``,
    `  node ${ENGINE}/resolve.mjs --sha ${sha} --state-dir ${STATE} --profile-dir ${PROFILE}` +
      (PIPELINE ? ` --pipeline ${PIPELINE}` : ''),
    ``,
    `Return its JSON summary (it prints one line of JSON to stdout): {ok, apply_order, cycles, halted,`,
    `halted_downstream, blackboard_open, report}. Report the resolver's output verbatim; never invent`,
    `the graph.`,
  ].join('\n')
}

function gitopsPrompt() {
  return [
    `You are a thin exec runner. Do NOT edit any manifest by hand, and treat the SOURCE GitOps overlay`,
    `(the profile's source_dir) as immutable — never write to it.`,
    `Run exactly this committed deterministic rewriter, which copies the in-scope platform/core`,
    `components from the profile's source_dir into its target_dir, applies the source→DR`,
    `substitutions from ${PROFILE}/gitops-substitutions.json, stamps POST-APPLY / DECIDE`,
    `sentinels, writes ${STATE}/gitops-report.md, and runs the completeness guard:`,
    ``,
    `  node ${ENGINE}/gitops-rewrite.mjs ${PROFILE}/gitops-substitutions.json --state-dir ${STATE}`,
    ``,
    `It prints one line of JSON to stdout: {ok, generated_components, excluded, stale_exclusions,`,
    `applied_count, post_apply, decide, violations, report}. Return that object verbatim, every key`,
    `included. A non-empty "violations" (exit 1) means a source infra token survived into the overlay`,
    `— report it, never invent a pass. A non-empty "stale_exclusions" means the profile pins an`,
    `exclusion that no longer matches a real component; report it rather than dropping it.`,
  ].join('\n')
}

// --- Phase 2: build + per-root checks (pipelined; each root checks as soon as it is built) -------
phase('Build')
log(`DR build from ${sha}: ${inScope.length} in-scope root(s)`)

const built = await pipeline(
  inScope,
  (item) => agent(builderPrompt(item), {
    label: `build:${item.component}`,
    phase: 'Build',
    agentType: BUILDER_AGENT,
    schema: MANIFEST_SCHEMA,
  }),
  (manifest, item) => {
    if (!manifest) return null // Builder died/skipped — drop from the run; resolve reports the gap
    return agent(checkPrompt(item), {
      label: `lint:${item.component}`,
      phase: 'Build',
      schema: CHECK_SCHEMA,
    }).then((check) => ({ item, manifest, check }))
  },
)

const results = built.filter(Boolean)
const lintFailures = results
  .filter((r) => r.check && (r.check.lint_pass === false || r.check.reconcile_pass === false))
  .map((r) => r.item.component)
const missing = inScope
  .filter((it) => !results.some((r) => r.item.component === it.component))
  .map((it) => it.component)

if (lintFailures.length) log(`lint/reconcile FAILED: ${lintFailures.join(', ')} — re-run those Builders (resumable) before plan`)
if (missing.length) log(`Builder produced no result: ${missing.join(', ')}`)

// --- Phase 3: assemble the graph, write state, regenerate pipeline stanzas (committed resolver) ---
phase('Resolve')
const resolve = await agent(resolvePrompt(), {
  label: 'resolve:graph',
  phase: 'Resolve',
  schema: RESOLVE_SCHEMA,
})

if (resolve && resolve.cycles && resolve.cycles.length) {
  const downstream = resolve.halted_downstream || []
  log(`cycle(s) detected — halted, recorded in ${STATE}/dependency-graph.md, escalate to a human (ARCHITECTURE §8): ${resolve.cycles.map((c) => c.join('→')).join(' ; ')}` +
    (downstream.length ? `. Also excluded from the apply order, downstream of the cycle: ${downstream.join(', ')}` : ''))
}

// --- Phase: GitOps — regenerate the platform/core GitOps overlay (committed rewriter) -------------
// The mechanical, deterministic part runs here (autonomous): copy + AUTO substitutions + sentinels +
// completeness guard. The interactive part — confirming AUTO, prompting the DECIDE values, and
// resolving the POST-APPLY sentinels after the DR cluster applies — runs in the calling skill,
// because this Workflow script cannot pause for input (ARCHITECTURE §2.2, §16.15).
phase('GitOps')
const gitops = await agent(gitopsPrompt(), {
  label: 'gitops:overlay',
  phase: 'GitOps',
  schema: GITOPS_SCHEMA,
})

if (gitops && gitops.violations && gitops.violations.length) {
  log(`GitOps overlay FAILED the completeness guard — residual prod token(s): ${gitops.violations.map((v) => `${v.file}:${v.line}`).join(', ')}. Fix the rules in profile/gitops-substitutions.json and re-run.`)
} else if (gitops) {
  const pa = gitops.post_apply ? gitops.post_apply.length : 0
  const dec = gitops.decide ? gitops.decide.length : 0
  log(`GitOps overlay generated: ${gitops.generated_components.length} component(s), ${gitops.applied_count} AUTO substitution(s); ${pa} POST-APPLY + ${dec} DECIDE residue for the skill (see ${STATE}/gitops-report.md)`)
}

return {
  sha,
  in_scope: inScope.map((i) => i.component),
  built: results.map((r) => r.item.component),
  lint_failures: lintFailures,
  missing,
  resolve,
  gitops,
}
