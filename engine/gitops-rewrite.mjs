#!/usr/bin/env node
//
// engine/gitops-rewrite.mjs — the GitOps Builder's deterministic engine (ARCHITECTURE §8, §11).
//
// Regenerate-on-build for the platform/core GitOps layer: copy the in-scope source GitOps components
// into the DR overlay and rewrite the env-specific values to their DR-region equivalents, using the
// SAME profile transform rules that generate the DR Terraform estate. The source manifests stay
// pristine; the DR overlay is generated output that cannot drift. Both directories come from the
// profile (`source_dir` / `target_dir`), never from this script.
//
// Customer-agnostic: every token lives in the patterns file (default profile/gitops-substitutions.json),
// so this script holds only the generic engine. A new customer re-points the profile and edits only
// that file. This is the GitOps analogue of lint.sh ↔ lint-patterns.txt.
//
// Three value classes (see docs/gitops-substitutions-schema.md):
//   AUTO        exact source→DR token pairs, applied verbatim (region, names, CIDRs, owner ids, paths).
//   POST-APPLY  not derivable at codegen (e.g. a workload-identity client id, a full resource id that
//               only exists after another root applies) — replaced with a "__DR_POST_APPLY__<slug>"
//               sentinel for the post-apply step / skill to resolve.
//   DECIDE      needs a human call (e.g. an on-prem allowlist) — a sensible default is kept and
//               flagged, or (default_kept:false) replaced with a "__DR_DECIDE__<slug>" sentinel.
//
// A narrow completeness scan then fails the build if any source infra token survived. Which tokens
// count is profile data (`forbidden_residual`), never a hardcoded set here. Cutover hostnames are
// deliberately absent from that list: they legitimately survive into the DR overlay, because cutover
// is a customer-led routing step (ARCHITECTURE §17), not something the build rewrites.
//
// Usage:  node gitops-rewrite.mjs [patterns-file] [--repo <root>] [--state-dir <dir>]
// Exit:   0 = generated, no residual leakage; 1 = residual source token(s) survived; 2 = usage/parse error.
//
import { readFileSync, writeFileSync, readdirSync, statSync, mkdirSync, rmSync } from 'node:fs'
import { join, resolve } from 'node:path'

// --- args ----------------------------------------------------------------------------------------
// The engine ships separately from the estate it runs against (this file lives in the plugin, the
// profile and state live in the consuming repo), so nothing here may be resolved relative to
// SCRIPT_DIR. Convention: the consuming repo holds `<AGENTIC_DIR>/profile` and `<AGENTIC_DIR>/state`,
// defaulting to `agentic-dr/`, and every path is overridable.
const AGENTIC_DIR = process.env.AGENTIC_DR_DIR || 'agentic-dr'
let repoRoot = process.cwd()
let patternsPath = null
let stateDirArg = null
const argv = process.argv.slice(2)
for (let i = 0; i < argv.length; i++) {
  if (argv[i] === '--repo') repoRoot = argv[++i]
  else if (argv[i] === '--state-dir') stateDirArg = argv[++i]
  else if (!argv[i].startsWith('--')) patternsPath = argv[i]
}
patternsPath = patternsPath || join(repoRoot, AGENTIC_DIR, 'profile', 'gitops-substitutions.json')

function die(msg) { console.error(`gitops-rewrite: ${msg}`); process.exit(2) }

let rules
try {
  rules = JSON.parse(readFileSync(patternsPath, 'utf8'))
} catch (e) {
  die(`cannot read/parse patterns ${patternsPath}: ${e.message}`)
}

const srcDir = resolve(repoRoot, rules.source_dir)
const dstDir = resolve(repoRoot, rules.target_dir)
try { if (!statSync(srcDir).isDirectory()) die(`source_dir is not a directory: ${srcDir}`) }
catch { die(`source_dir not found: ${srcDir} (run from the repo root, or pass --repo)`) }

// Longest-first so an AUTO token that is a prefix of another can never partially shadow it.
const auto = [...(rules.auto || [])].sort((a, b) => b.from.length - a.from.length)
const postApplyRules = rules.post_apply || []
const decideRules = rules.decide || []
const paPrefix = rules.post_apply_placeholder_prefix || '__DR_POST_APPLY__'
const decPrefix = rules.decide_placeholder_prefix || '__DR_DECIDE__'

const applied = []     // {component, file, rule:'auto', from, to, count}
const postApply = []   // {component, file, slug, what, why}
const decide = []      // {component, file, slug, what, why, kept}

// --- per-file rewrite ----------------------------------------------------------------------------
function rewrite(text, component, relFile) {
  // 1. POST-APPLY first, so a placeholder removes source tokens (e.g. a name prefix inside a resource id)
  //    BEFORE the AUTO sweep and the completeness scan see them.
  for (const r of postApplyRules) {
    const sentinel = `${paPrefix}${r.slug}`
    if (r.kind === 'line-value') {
      // Replace the scalar value of `  <key>: <value>` with the sentinel (comments dropped — the
      // value is being deferred anyway). Mapping lines (`<key>:` with no inline value) are skipped.
      const re = new RegExp(`^([ \\t]*${escapeRe(r.match)}[ \\t]*:[ \\t]*)(\\S.*?)[ \\t]*$`, 'gm')
      let hit = false
      text = text.replace(re, (_m, head) => { hit = true; return `${head}${sentinel}` })
      if (hit) postApply.push({ component, file: relFile, slug: r.slug, what: r.what, why: r.why })
    } else { // kind: 'token'
      if (text.includes(r.match)) {
        text = text.split(r.match).join(sentinel)
        postApply.push({ component, file: relFile, slug: r.slug, what: r.what, why: r.why })
      }
    }
  }

  // 2. DECIDE — keep a sensible default and flag it, or stamp a sentinel when there is no default.
  for (const r of decideRules) {
    if (!text.includes(r.match)) continue
    if (r.default_kept) {
      decide.push({ component, file: relFile, slug: r.slug, what: r.what, why: r.why, kept: true })
    } else {
      const sentinel = `${decPrefix}${r.slug}`
      text = text.split(r.match).join(sentinel)
      decide.push({ component, file: relFile, slug: r.slug, what: r.what, why: r.why, kept: false })
    }
  }

  // 3. AUTO — exact-token prod→DR substitutions.
  for (const r of auto) {
    if (!text.includes(r.from)) continue
    const count = text.split(r.from).length - 1
    text = text.split(r.from).join(r.to)
    applied.push({ component, file: relFile, rule: 'auto', from: r.from, to: r.to, count })
  }
  return text
}

function escapeRe(s) { return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') }

// --- copy + rewrite the in-scope tree ------------------------------------------------------------
function walk(absSrc, absDst, component, rel) {
  mkdirSync(absDst, { recursive: true })
  for (const name of readdirSync(absSrc)) {
    const s = join(absSrc, name)
    const d = join(absDst, name)
    const childRel = rel ? `${rel}/${name}` : name
    if (statSync(s).isDirectory()) {
      walk(s, d, component, childRel)
    } else {
      const out = rewrite(readFileSync(s, 'utf8'), component, childRel)
      writeFileSync(d, out)
    }
  }
}

// Scope is DISCOVERED, not catalogued (ARCHITECTURE §12): enumerate every component under the source
// dir and subtract the pinned data-plane exclusions, so a new platform/core component added to prod is
// covered automatically. Only exclusions are pinned (profile/gitops-substitutions.json `exclude`).
const exclude = new Set(rules.exclude || [])
const discovered = readdirSync(srcDir)
  .filter((n) => { try { return statSync(join(srcDir, n)).isDirectory() } catch { return false } })
  .sort()
const components = discovered.filter((c) => !exclude.has(c))
const excluded = discovered.filter((c) => exclude.has(c))
// A pinned exclusion that no longer matches a real component is stale — surface it, never swallow it.
const staleExclusions = [...exclude].filter((c) => !discovered.includes(c))
if (staleExclusions.length) console.error(`gitops-rewrite: stale exclusion(s) not present in ${rules.source_dir}: ${staleExclusions.join(', ')}`)

// Regenerate cleanly: blow away any prior overlay so a renamed/removed prod file can't leave a stale
// copy behind in the DR overlay.
rmSync(dstDir, { recursive: true, force: true })
const generatedComponents = []
for (const component of components) {
  walk(join(srcDir, component), join(dstDir, component), component, '')
  generatedComponents.push(component)
}

// --- completeness scan: no prod infra token may survive in the generated overlay -----------------
const violations = []
const forbidden = (rules.forbidden_residual || []).map((f) => ({ re: new RegExp(f.pattern), why: f.why, pattern: f.pattern }))
function scan(absDst, rel) {
  for (const name of readdirSync(absDst)) {
    const p = join(absDst, name)
    const childRel = rel ? `${rel}/${name}` : name
    if (statSync(p).isDirectory()) { scan(p, childRel); continue }
    const lines = readFileSync(p, 'utf8').split(/\r?\n/)
    lines.forEach((line, i) => {
      for (const f of forbidden) {
        if (f.re.test(line)) violations.push({ file: childRel, line: i + 1, pattern: f.pattern, why: f.why, snippet: line.trim() })
      }
    })
  }
}
scan(dstDir, rules.target_dir) // violations report repo-relative paths, per the profile's target_dir

// --- report --------------------------------------------------------------------------------------
const ok = violations.length === 0
const stateDir = stateDirArg
  ? resolve(repoRoot, stateDirArg)
  : resolve(repoRoot, AGENTIC_DIR, 'state')
try {
  mkdirSync(stateDir, { recursive: true })
  writeFileSync(join(stateDir, 'gitops-report.md'), renderReport())
} catch { /* state report is best-effort; the stdout JSON is the contract */ }

function renderReport() {
  const L = []
  L.push('# GitOps overlay build report', '')
  L.push(`Generated \`${rules.target_dir}\` from \`${rules.source_dir}\` — ${generatedComponents.length} platform/core component(s) discovered; ${excluded.length} data-plane component(s) excluded.`, '')
  L.push(`Status: ${ok ? 'PASS — no prod infra token survived' : `FAIL — ${violations.length} residual prod token(s)`}`, '')
  if (excluded.length) L.push(`Excluded (data plane): ${excluded.join(', ')}`, '')
  if (staleExclusions.length) L.push(`⚠ Stale exclusion(s) not present in source: ${staleExclusions.join(', ')}`, '')
  L.push('## AUTO substitutions applied', '')
  for (const a of applied) L.push(`- \`${a.component}/${a.file}\`: \`${a.from}\` → \`${a.to}\` (×${a.count})`)
  L.push('', '## POST-APPLY — resolve after the DR estate applies (sentinel left in place)', '')
  for (const p of postApply) L.push(`- \`${p.component}/${p.file}\`: **${p.what}** — ${p.why}`)
  L.push('', '## DECIDE — human confirmation required', '')
  for (const d of decide) L.push(`- \`${d.component}/${d.file}\`: **${d.what}** — ${d.why} (${d.kept ? 'prod default kept, confirm' : 'sentinel stamped'})`)
  if (!ok) {
    L.push('', '## Residual prod tokens (build FAILED)', '')
    for (const v of violations) L.push(`- \`${v.file}:${v.line}\` /${v.pattern}/ — ${v.snippet}`)
  }
  L.push('')
  return L.join('\n')
}

console.log(JSON.stringify({
  ok,
  generated_components: generatedComponents,
  excluded,
  stale_exclusions: staleExclusions,
  applied_count: applied.length,
  post_apply: postApply,
  decide,
  violations,
  report: join(stateDir, 'gitops-report.md'),
}))
process.exit(ok ? 0 : 1)
