#!/usr/bin/env node
//
// engine/resolve.mjs — Phase-3 graph resolver + state writer + pipeline emitter (ARCHITECTURE
// §8 Phase 3, §9, §16.12). Deterministic (no LLM); run by the Workflow's thin exec agent (§16.13).
//
// Reads every Builder manifest (+ its lint/reconcile check) from the manifest dir, then:
//   - assembles the dependency DAG from produces/consumes,
//   - detects cycles (HALTS the affected subgraph + records it; never breaks them — §8),
//   - computes a tiered apply order (Kahn levels) over the generated roots,
//   - writes <state-dir>/{blackboard.md, dependency-graph.md, run-report.md},
//   - regenerates ONLY the managed DR job region inside the DR pipeline (§16.12), leaving the
//     hand-authored pre-staged jobs intact.
//
// Prints a one-line JSON summary to stdout for the Orchestrator.
//
// Customer-agnostic: the emitted pipeline job stanza is a template read from the profile
// (`pipeline-job.tmpl`), not baked in here, because the CI system and its inputs are estate
// decisions. A new customer edits the template, not this script.
//
// Usage: node resolve.mjs --sha <sha> [--pipeline <path>] [--manifest-dir <dir>] [--state-dir <dir>]
//                         [--job-template <path>]
//
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs'
import { join } from 'node:path'

// --- args ----------------------------------------------------------------------------------------
function arg(name, def) {
  const i = process.argv.indexOf(name)
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : def
}
// The engine ships separately from the estate it runs against, so paths default into the consuming
// repo's `<AGENTIC_DIR>/` convention rather than anywhere relative to this file.
const AGENTIC_DIR = process.env.AGENTIC_DR_DIR || 'agentic-dr'
const SHA = arg('--sha', 'UNKNOWN')
const STATE = arg('--state-dir', join(AGENTIC_DIR, 'state'))
const PROFILE = arg('--profile-dir', join(AGENTIC_DIR, 'profile'))
const PIPELINE = arg('--pipeline', '')
const JOB_TEMPLATE = arg('--job-template', join(PROFILE, 'pipeline-job.tmpl'))
const MANIFEST_DIR = arg('--manifest-dir', join(STATE, 'manifests'))

// --- load manifests + checks ---------------------------------------------------------------------
if (!existsSync(MANIFEST_DIR)) {
  console.error(`resolve: no manifest dir ${MANIFEST_DIR} — nothing to resolve (did any Builder run?)`)
  process.exit(2)
}
const manifestFiles = readdirSync(MANIFEST_DIR).filter((f) => f.endsWith('.json') && !f.endsWith('.check.json'))
const manifests = []
for (const f of manifestFiles) {
  try {
    manifests.push(JSON.parse(readFileSync(join(MANIFEST_DIR, f), 'utf8')))
  } catch (e) {
    console.error(`resolve: skipping unparseable manifest ${f}: ${e.message}`)
  }
}
function checkFor(component) {
  const p = join(MANIFEST_DIR, `${component}.check.json`)
  if (!existsSync(p)) return null
  try { return JSON.parse(readFileSync(p, 'utf8')) } catch { return null }
}

const generated = new Set(manifests.map((m) => m.component))
const byComponent = new Map(manifests.map((m) => [m.component, m]))

// --- build the dependency graph ------------------------------------------------------------------
// Edge producer -> consumer for any consumes entry naming a real producer (not "—"/empty). A
// generated node whose producer has no manifest depends on a pre-staged Phase-1 root (external).
const preds = new Map() // component -> Set(predComponent)
const allNodes = new Set()
for (const m of manifests) {
  allNodes.add(m.component)
  if (!preds.has(m.component)) preds.set(m.component, new Set())
  for (const c of m.consumes || []) {
    const from = (c.from || '').trim()
    if (!from || from === '—' || from === '-' || from === m.component) continue
    allNodes.add(from)
    preds.get(m.component).add(from)
  }
}
for (const n of allNodes) if (!preds.has(n)) preds.set(n, new Set())
const external = new Set([...allNodes].filter((n) => !generated.has(n))) // pre-staged producers

// --- cycle detection (DFS colors) ----------------------------------------------------------------
const cycles = []
const WHITE = 0, GRAY = 1, BLACK = 2
const color = new Map([...allNodes].map((n) => [n, WHITE]))
const stack = []
function dfs(n) {
  color.set(n, GRAY); stack.push(n)
  for (const p of preds.get(n)) {
    if (color.get(p) === GRAY) {
      const i = stack.indexOf(p)
      cycles.push(stack.slice(i).concat(p))
    } else if (color.get(p) === WHITE) {
      dfs(p)
    }
  }
  stack.pop(); color.set(n, BLACK)
}
for (const n of allNodes) if (color.get(n) === WHITE) dfs(n)

// A cycle halts more than its own members. Anything that consumes a halted component cannot be
// applied either, because the value it waits for is never produced. Excluding only the members would
// leave the consumer in the apply order while `jobPreds` silently dropped its now-dangling edge from
// `needs:` — scheduling it as though it had no dependency at all, which is worse than not emitting
// it. So the whole downstream closure is halted, and reported separately from the cycle itself.
const consumers = new Map([...allNodes].map((n) => [n, new Set()]))
for (const [c, ps] of preds) for (const p of ps) consumers.get(p)?.add(c)
const cycleMembers = new Set(cycles.flat())
const halted = new Set(cycleMembers)
const queue = [...cycleMembers]
while (queue.length) {
  const n = queue.shift()
  for (const c of consumers.get(n) || []) {
    if (!halted.has(c)) { halted.add(c); queue.push(c) }
  }
}
// Generated roots only: an external producer downstream of a cycle is not ours to apply anyway.
const haltedDownstream = [...halted].filter((n) => !cycleMembers.has(n) && generated.has(n)).sort()

// --- tiered apply order (Kahn levels), generated nodes only, excluding halted --------------------
const level = new Map()
function levelOf(n, seen = new Set()) {
  if (level.has(n)) return level.get(n)
  if (seen.has(n)) return 0 // guard (cycles handled separately)
  seen.add(n)
  let lv = 0
  for (const p of preds.get(n)) lv = Math.max(lv, levelOf(p, seen) + 1)
  level.set(n, lv)
  return lv
}
for (const n of allNodes) levelOf(n)

const tiers = []
for (const n of [...generated].filter((g) => !halted.has(g)).sort()) {
  const lv = level.get(n)
  ;(tiers[lv] ||= []).push(n)
}
const applyOrder = tiers.map((t) => (t || []).sort()).filter((t) => t.length)

// --- collect blackboard residue + blocked roots --------------------------------------------------
const blackboard = []
for (const m of manifests) {
  for (const c of m.consumes || []) {
    if (c.status === 'blackboard') {
      blackboard.push({ needed_by: m.component, what: c.what, source: c.from || '—', via: c.via })
    }
  }
}
const blocked = []
for (const m of manifests) {
  const chk = checkFor(m.component)
  if (!chk || chk.lint_pass === false || chk.reconcile_pass === false) {
    blocked.push({ component: m.component, reason: !chk ? 'no lint/reconcile result' : `lint=${chk.lint_pass} reconcile=${chk.reconcile_pass}` })
  }
}

// --- pipeline job validity: which predecessors are real, deployable jobs? ------------------------
// A `needs:` target naming a job the pipeline doesn't define makes the WHOLE workflow invalid, so a
// needs: edge may only point at a job that actually exists. Valid jobs = the generated roots we emit
// (apply-order; halted roots excluded) PLUS the hand-authored Phase-1 jobs already present OUTSIDE
// the managed block. External producers that are neither — excluded Bucket-A/B singletons (acr,
// front-door) or out-of-band replication (kv-replication, external KV replication) — are real
// dependency edges but NOT pipeline jobs: they stay in
// dependency-graph.md and surface through the aggregated prerequisites, and are dropped from needs:.
function jobName(component) { return 'deploy_' + component.replace(/[^a-zA-Z0-9]+/g, '_') }
function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') }
const BEGIN = '  # >>> BEGIN generated DR jobs (managed by agentic-dr resolve.mjs — do not edit by hand) <<<'
const END = '  # >>> END generated DR jobs <<<'

const emitted = new Set(applyOrder.flat()) // generated roots actually emitted as jobs (halted excluded)
const pipelineYml = existsSync(PIPELINE) ? readFileSync(PIPELINE, 'utf8') : null
const preStagedJobs = new Set()
if (pipelineYml) {
  const outsideManaged = pipelineYml.includes(BEGIN) && pipelineYml.includes(END)
    ? pipelineYml.replace(new RegExp(`${escapeRe(BEGIN)}[\\s\\S]*?${escapeRe(END)}`), '')
    : pipelineYml
  for (const mt of outsideManaged.matchAll(/^ {2}(deploy_[a-zA-Z0-9_]+):/gm)) preStagedJobs.add(mt[1])
}
const validJobNames = new Set([...emitted].map(jobName))
for (const j of preStagedJobs) validJobNames.add(j)
// predecessors of a component that map to an actual pipeline job (deduped, sorted)
function jobPreds(component) {
  return [...preds.get(component)].filter((p) => validJobNames.has(jobName(p))).sort()
}

// --- write state files ---------------------------------------------------------------------------
function blackboardMd() {
  const head = `# Blackboard — unresolved cross-component values\n\n` +
    `Generated by resolve.mjs from the Builder manifests (ARCHITECTURE §6, §9). The Orchestrator works these down;\n` +
    `\`post-apply\` rows resolve once the producer applies (residue captured back here in Phase 6).\n\n`
  if (!blackboard.length) return head + `_No unresolved cross-component values._\n`
  const rows = blackboard
    .map((b) => `| ${b.needed_by} | ${b.what} | ${b.source} | ${b.via} | open |`)
    .join('\n')
  return head + `| needed_by | what | source | resolution (via) | status |\n| --- | --- | --- | --- | --- |\n${rows}\n`
}

function dependencyGraphMd() {
  let out = `# Dependency graph & apply order\n\n` +
    `Generated by resolve.mjs from the Builder manifests (ARCHITECTURE §8 Phase 3). Pinned SHA: \`${SHA}\`.\n\n`
  out += `## Edges (producer → consumer)\n\n`
  const edges = []
  for (const [c, ps] of preds) for (const p of ps) {
    const label = !external.has(p) ? ''
      : validJobNames.has(jobName(p)) ? ' _(pre-staged Phase-1 producer)_'
      : ' _(external — no pipeline job; see prerequisites)_'
    edges.push(`- \`${p}\` → \`${c}\`${label}`)
  }
  out += (edges.length ? edges.sort().join('\n') : '_No cross-component edges._') + '\n\n'
  out += `## Apply order (tiers — plan/apply earliest tier first)\n\n`
  if (applyOrder.length) {
    applyOrder.forEach((t, i) => { out += `${i + 1}. ${t.map((n) => `\`${n}\``).join(', ')}\n` })
  } else {
    out += `_No generated roots to order._\n`
  }
  out += `\n## Cycles\n\n`
  if (cycles.length) {
    out += `**HALTED — escalate to a human (ARCHITECTURE §8).** The affected subgraph is excluded from the apply order:\n\n`
    cycles.forEach((c) => { out += `- ${c.map((n) => `\`${n}\``).join(' → ')}\n` })
    if (haltedDownstream.length) {
      out += `\nAlso excluded — downstream of the cycle, so the value each waits for is never produced:\n\n`
      haltedDownstream.forEach((n) => { out += `- ${'`' + n + '`'}\n` })
    }
  } else {
    out += `_None detected._\n`
  }
  return out
}

function runReportMd() {
  let out = `# DR build run report\n\n`
  out += `- **Pinned SHA:** \`${SHA}\`\n`
  out += `- **In-scope (generated) roots:** ${manifests.length ? [...generated].sort().map((c) => `\`${c}\``).join(', ') : '_none_'}\n`
  out += `- **Built:** ${manifests.length}\n`
  out += `- **Blocked (lint/reconcile or missing result):** ${blocked.length ? blocked.map((b) => `\`${b.component}\` (${b.reason})`).join(', ') : 'none'}\n`
  out += `- **Open blackboard items:** ${blackboard.length}\n`
  out += `- **Cycles:** ${cycles.length ? cycles.map((c) => c.join('→')).join(' ; ') : 'none'}\n`
  out += `- **Halted (excluded from the apply order):** ${halted.size ? [...halted].sort().map((c) => `\`${c}\``).join(', ') : 'none'}${haltedDownstream.length ? ` — of which downstream of a cycle: ${haltedDownstream.map((c) => `\`${c}\``).join(', ')}` : ''}\n\n`
  out += `This is the ACTUAL outcome that confirms/corrects the Phase-1 build plan (\`build-plan.md\`).\n` +
    `Plan/apply follow the tiers in \`dependency-graph.md\`; unresolved values are in \`blackboard.md\`.\n\n`
  // aggregate prereqs (deduped) so the apply gate has the out-of-band checklist in one place
  const prereqs = [...new Set(manifests.flatMap((m) => m.prereqs || []))].sort()
  out += `## Aggregated prerequisites (out-of-band; gate every apply — ARCHITECTURE §13)\n\n`
  out += (prereqs.length ? prereqs.map((p) => `- ${p}`).join('\n') : '_none reported_') + '\n'
  return out
}

writeFileSync(join(STATE, 'blackboard.md'), blackboardMd())
writeFileSync(join(STATE, 'dependency-graph.md'), dependencyGraphMd())
writeFileSync(join(STATE, 'run-report.md'), runReportMd())

// --- regenerate the managed DR job region in the pipeline (§16.12) -------------------------------
// The stanza is a profile-owned template, because which CI system runs the estate and which inputs
// its reusable workflow takes are estate decisions, not framework ones. Placeholders:
//
//   {{job}}          the job id for this component
//   {{component}}    the component name
//   {{target_root}}  the generated DR root's path
//   {{needs}}        a rendered `needs: [...]` line, or empty when the component has no predecessors
//   {{needs_expr}}   an `always() && (...)` guard over the predecessors, or empty
//
// A {{...}} line that renders empty is dropped entirely, so the template can carry `needs:` and the
// output stays valid for roots that have no predecessors.
const jobTemplate = (() => {
  try {
    return readFileSync(JOB_TEMPLATE, 'utf8')
  } catch {
    return null
  }
})()

function jobStanza(m) {
  if (!jobTemplate) return null
  const ps = jobPreds(m.component)
  const needs = ps.length ? `needs: [${ps.map(jobName).join(', ')}]` : ''
  // A root with no predecessors has nothing to wait for, so its needs-guard is vacuously true.
  // Rendering it empty would leave `(... || )` in the template, which is not a valid CI expression;
  // rendering it `false` would invert the meaning and gate the job off entirely.
  const needsExpr = ps.length
    ? ps
        .map((p) => `needs.${jobName(p)}.result == 'success' || needs.${jobName(p)}.result == 'skipped'`)
        .join(' || ')
    : 'true'
  const vars = {
    job: jobName(m.component),
    component: m.component,
    target_root: m.target_root,
    needs,
    needs_expr: needsExpr,
  }
  return jobTemplate
    .replace(/\{\{(\w+)\}\}/g, (_, k) => (k in vars ? vars[k] : `{{${k}}}`))
    // A line that rendered empty held only an empty placeholder (`needs` / `needs_expr` on a root
    // with no predecessors). Blank lines inside a job stanza carry no YAML meaning, so dropping
    // every empty line is both correct and simpler than tracking which ones collapsed.
    .split('\n')
    .filter((line) => line.trim() !== '')
    .join('\n')
}

let pipelineUpdated = false
let pipelineSkipped = null
if (pipelineYml && manifests.length && !jobTemplate) {
  // Emitting nothing is the safe failure: a half-written jobs block would break the whole workflow
  // file. Say so loudly rather than silently leaving the pipeline stale.
  pipelineSkipped = `no job template at ${JOB_TEMPLATE} — pipeline left untouched`
  console.error(`resolve: ${pipelineSkipped}`)
}
if (pipelineYml && manifests.length && jobTemplate) {
  let yml = pipelineYml
  // emit in apply-order (tiers) so the file reads top-to-bottom in dependency order; halted roots
  // are intentionally NOT emitted (they need human attention).
  const ordered = applyOrder.flat().map((c) => byComponent.get(c)).filter(Boolean)
  const block = [BEGIN, ordered.map(jobStanza).filter(Boolean).join('\n\n'), END].join('\n')
  if (yml.includes(BEGIN) && yml.includes(END)) {
    yml = yml.replace(new RegExp(`${escapeRe(BEGIN)}[\\s\\S]*?${escapeRe(END)}`), block)
  } else {
    yml = yml.replace(/\s*$/, '\n') + '\n' + block + '\n'
  }
  writeFileSync(PIPELINE, yml)
  pipelineUpdated = true
}

// --- summary to stdout ---------------------------------------------------------------------------
const ok = cycles.length === 0 && blocked.length === 0
const report = [
  `built ${manifests.length}`,
  `blocked ${blocked.length}`,
  `tiers ${applyOrder.length}`,
  `blackboard ${blackboard.length}`,
  `cycles ${cycles.length}`,
  `halted ${halted.size}`,
  `pipeline ${pipelineUpdated ? 'updated' : pipelineSkipped ? `skipped (${pipelineSkipped})` : 'unchanged'}`,
].join(', ')
console.log(JSON.stringify({
  ok,
  apply_order: applyOrder,
  cycles,
  // Every component kept out of the apply order by a cycle: the members plus their downstream
  // closure. `cycles` alone under-reports what the run did not build.
  halted: [...halted].sort(),
  halted_downstream: haltedDownstream,
  blackboard_open: blackboard.length,
  report,
}))
process.exit(0)
