#!/usr/bin/env node
//
// engine/reconcile.mjs — the SECOND deterministic oracle (ARCHITECTURE §11).
//
// Guards the flag-don't-guess rule (§7): a Builder must DEFER a cross-component value it can't
// resolve (log it to the manifest blackboard + leave it unset in the HCL), never hallucinate one —
// and must not log a blackboard entry for a value it actually hardcoded. This check is deterministic
// (no LLM): it reconciles each manifest against its emitted root via an explicit sentinel.
//
// Convention (set by the Orchestrator's Builder prompt): every deferred value is left unset in the
// HCL and marked with a trailing comment `# DR-DEFER: <what>` whose <what> equals the manifest
// consumes[].what for the matching `status:"blackboard"` entry. The two sets must correspond exactly.
//
// Usage:  node reconcile.mjs <dr-root-dir> <manifest.json>
// Exit:   0 = pass, 1 = reconciliation failure, 2 = usage / parse error.
//
import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'

const [root, manifestPath] = process.argv.slice(2)
if (!root || !manifestPath) {
  console.error('usage: reconcile.mjs <dr-root-dir> <manifest.json>')
  process.exit(2)
}

function die(msg) { console.error(`reconcile: ${msg}`); process.exit(2) }

let manifest
try {
  manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
} catch (e) {
  die(`cannot read/parse manifest ${manifestPath}: ${e.message}`)
}
try {
  if (!statSync(root).isDirectory()) die(`not a directory: ${root}`)
} catch {
  die(`not a directory: ${root}`)
}

const problems = []

// --- 1. Manifest structural validity (enums + required fields) -----------------------------------
const VIA = new Set(['data-rename', 'override', 'post-apply', 'remote-state'])
const STATUS = new Set(['resolved', 'blackboard'])
for (const f of ['component', 'source_root', 'target_root', 'tfc_workspace']) {
  if (typeof manifest[f] !== 'string' || !manifest[f]) problems.push(`manifest missing string field "${f}"`)
}
for (const f of ['produces', 'consumes', 'prereqs', 'notes']) {
  if (!Array.isArray(manifest[f])) problems.push(`manifest field "${f}" must be an array`)
}
const consumes = Array.isArray(manifest.consumes) ? manifest.consumes : []
consumes.forEach((c, i) => {
  if (!c || typeof c !== 'object') { problems.push(`consumes[${i}] is not an object`); return }
  if (typeof c.what !== 'string' || !c.what) problems.push(`consumes[${i}].what missing`)
  if (!VIA.has(c.via)) problems.push(`consumes[${i}].via invalid: ${JSON.stringify(c.via)}`)
  if (!STATUS.has(c.status)) problems.push(`consumes[${i}].status invalid: ${JSON.stringify(c.status)}`)
})

// --- 2. Sentinel reconciliation ------------------------------------------------------------------
// Collect the `# DR-DEFER: <what>` sentinels from the root's HCL.
const norm = (s) => String(s).trim().toLowerCase().replace(/\s+/g, ' ')
const sentinels = []
let files = []
try {
  files = readdirSync(root).filter((f) => f.endsWith('.tf') || f.endsWith('.tfvars'))
} catch (e) {
  die(`cannot list ${root}: ${e.message}`)
}
const SENTINEL = /#\s*DR-DEFER:\s*(.+?)\s*$/
for (const f of files) {
  const text = readFileSync(join(root, f), 'utf8')
  text.split(/\r?\n/).forEach((line, idx) => {
    const m = line.match(SENTINEL)
    if (m) sentinels.push({ file: f, line: idx + 1, what: m[1] })
  })
}

const blackboard = consumes.filter((c) => c && c.status === 'blackboard')
const sentinelKeys = sentinels.map((s) => norm(s.what))
const blackboardKeys = blackboard.map((c) => norm(c.what))

// every blackboard consume must have a matching sentinel in the HCL (deferred, not hardcoded)
for (const c of blackboard) {
  if (!sentinelKeys.includes(norm(c.what))) {
    problems.push(`blackboard consume "${c.what}" has no matching "# DR-DEFER: ${c.what}" sentinel in the HCL — value may have been hardcoded instead of deferred`)
  }
}
// every sentinel must have a matching blackboard consume (deferred in code, but not logged)
for (const s of sentinels) {
  if (!blackboardKeys.includes(norm(s.what))) {
    problems.push(`${s.file}:${s.line} "# DR-DEFER: ${s.what}" has no matching blackboard consumes[] entry in the manifest`)
  }
}

// --- Report --------------------------------------------------------------------------------------
if (problems.length) {
  console.log(`reconcile: FAIL — ${root}`)
  for (const p of problems) console.log(`  ✗ ${p}`)
  process.exit(1)
}
console.log(`reconcile: PASS — ${root} (${blackboard.length} deferred value(s) reconciled)`)
process.exit(0)
