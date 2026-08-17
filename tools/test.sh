#!/usr/bin/env bash
#
# tools/test.sh — verify the deterministic half of the framework.
#
# There is no LLM in this file. Everything here is one of the two correctness oracles or the
# resolver, run against committed fixtures, which is exactly the point: the parts of the system that
# must not hallucinate are the parts that can be tested without a model.
#
# The agents themselves are verified differently — by `terraform plan` on a real estate, reviewed by
# a human (ARCHITECTURE §10). A green run here means the guardrails work, not that a build is correct.
#
# Usage: bash tools/test.sh
# Exit:  0 = all checks passed, 1 = a check failed.
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Every path below is repo-relative, so a failed cd would run the whole suite against the wrong tree.
cd "$ROOT" || exit 2

PROFILE=profile.example
pass=0
fail=0

ok()   { printf '  \xE2\x9C\x93 %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \xE2\x9C\x97 %s\n' "$1"; fail=$((fail + 1)); }

# expect <expected-exit> <description> -- <command...>
expect() {
  local want="$1" desc="$2"; shift 3
  local out; out="$("$@" 2>&1)"; local got=$?
  if [[ "$got" == "$want" ]]; then
    ok "$desc (exit $got)"
  else
    bad "$desc — expected exit $want, got $got"
    printf '%s\n' "$out" | sed 's/^/      /'
  fi
}

echo "== invariant lint (oracle 1) =="
# The clean fixture carries a provenance comment naming the source estate on purpose: lint.sh strips
# HCL comments before matching, so this also guards the comment-stripping behaviour.
expect 0 "clean root passes" -- bash engine/lint.sh fixtures/clean-root "$PROFILE/lint-patterns.txt"
expect 1 "leaking root fails" -- bash engine/lint.sh fixtures/leaking-root "$PROFILE/lint-patterns.txt"
expect 2 "missing root is a usage error, not a pass" -- bash engine/lint.sh fixtures/does-not-exist "$PROFILE/lint-patterns.txt"

# Every pattern kind must actually fire. A lint that silently stopped loading CONDITIONAL rules
# would still exit 1 on the leaking fixture, so assert the individual violations by name.
echo "== lint covers every pattern kind =="
leak="$(bash engine/lint.sh fixtures/leaking-root "$PROFILE/lint-patterns.txt" 2>&1 || true)"
for kind in "FORBIDDEN" "REQUIRED" "CONDITIONAL \[marker-if-regional\]" "CONDITIONAL \[cidr-if-network\]" \
            "CONDITIONAL \[env-tag-dr\]" "CONDITIONAL \[vnet-netcontrib\]"; do
  if grep -qE "$kind" <<<"$leak"; then ok "$kind fires"; else bad "$kind did NOT fire"; fi
done

echo "== manifest reconciliation (oracle 2) =="
expect 0 "manifest matching the HCL sentinels passes" -- \
  node engine/reconcile.mjs fixtures/clean-root fixtures/manifests/clean-root.json
# Both directions of flag-don't-guess: a deferred value with no sentinel (hardcoded instead of
# deferred), and a sentinel with no manifest entry (deferred but not logged).
expect 1 "manifest that hallucinated a deferral fails" -- \
  node engine/reconcile.mjs fixtures/clean-root fixtures/manifests/hallucinated.json

echo "== phase-3 resolver =="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp -R fixtures/resolve/state "$tmp/state"
cp fixtures/resolve/dr-pipeline.template.yml "$tmp/pipeline.yml"

summary="$(node engine/resolve.mjs --sha testsha123 --state-dir "$tmp/state" \
  --profile-dir "$PROFILE" --pipeline "$tmp/pipeline.yml" 2>&1)"

check_json() { # <jq-ish grep> <description>
  if grep -qF "$1" <<<"$summary"; then ok "$2"; else bad "$2 — summary was: $summary"; fi
}
check_json '"apply_order":[["law","vnet"],["aks"],["workload-identity"]]' "tiers computed in dependency order"
check_json '"cycles":[["alpha","beta","alpha"]]' "seeded cycle detected"
check_json '"blackboard_open":1' "unresolved cross-component value recorded"
check_json 'blocked 0' "no component blocked when all checks pass"

# A cycle must be HALTED, never auto-broken: the members stay out of the apply order.
if grep -qE '"apply_order":\[\[[^]]*(alpha|beta)' <<<"$summary"; then
  bad "cycle members leaked into the apply order — the resolver broke a cycle instead of halting it"
else
  ok "cycle members excluded from the apply order"
fi

# A cycle halts its whole downstream closure, not just its members. `gamma` consumes `beta` and is
# clean in itself, so only the cycle can keep it out. Emitting it would schedule a root whose input
# is never produced — and with the dangling edge dropped from `needs:`, it would look unconditional.
check_json '"halted":["alpha","beta","gamma"]' "cycle closure halted, not just the cycle members"
check_json '"halted_downstream":["gamma"]' "downstream exclusion reported separately from the cycle"
# Parsed rather than grepped: the tiers are nested arrays, so a substring match would only ever see
# the first tier and would read as coverage while checking almost nothing.
in_apply_order() { # <component>
  node -e 'const s=JSON.parse(process.argv[1].trim().split("\n").pop());
           process.exit(s.apply_order.flat().includes(process.argv[2]) ? 0 : 1)' "$summary" "$1"
}
if in_apply_order gamma; then
  bad "a root downstream of a halted cycle was emitted into the apply order"
else
  ok "root downstream of a halted cycle excluded from the apply order"
fi
for c in alpha beta; do
  if in_apply_order "$c"; then bad "cycle member $c reached the apply order"; else ok "cycle member $c excluded (parsed, all tiers)"; fi
done
# Scoped to the Cycles section: the edge list names every component, so a whole-file grep would
# pass no matter what the cycle report said.
if sed -n '/## Cycles/,$p' "$tmp/state/dependency-graph.md" | grep -qF 'gamma'; then
  ok "the downstream exclusion is named in dependency-graph.md, not silently dropped"
else
  bad "dependency-graph.md does not say why the downstream root was excluded"
fi
if grep -q 'deploy_gamma' "$tmp/pipeline.yml"; then
  bad "a halted root was emitted as a pipeline job"
else
  ok "no pipeline job emitted for a halted root"
fi

for f in blackboard.md dependency-graph.md run-report.md; do
  if [[ -s "$tmp/state/$f" ]]; then ok "wrote $f"; else bad "did not write $f"; fi
done

echo "== pipeline emitter =="
if grep -q 'deploy_prestaged_vnet' "$tmp/pipeline.yml"; then
  ok "hand-authored job outside the managed region survived"
else
  bad "the resolver clobbered a hand-authored job"
fi
# The failure this guards against is a root with no predecessors rendering `(... || )`, which is not
# a valid CI expression and would break the whole workflow file.
if grep -qE '\|\| *\)' "$tmp/pipeline.yml"; then
  bad "empty needs-expression rendered — invalid CI expression"
else
  ok "no empty expression rendered for roots without predecessors"
fi
if command -v ruby >/dev/null 2>&1; then
  if ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$tmp/pipeline.yml" >/dev/null 2>&1; then
    ok "generated pipeline is valid YAML"
  else
    bad "generated pipeline is not valid YAML"
  fi
fi

# Emitting nothing is the safe failure: a half-written jobs block breaks the entire workflow file.
cp fixtures/resolve/dr-pipeline.template.yml "$tmp/pipeline2.yml"
out="$(node engine/resolve.mjs --sha testsha123 --state-dir "$tmp/state" \
  --job-template /nonexistent.tmpl --pipeline "$tmp/pipeline2.yml" 2>&1)"
if grep -qF 'pipeline skipped' <<<"$out" && ! grep -q 'deploy_law' "$tmp/pipeline2.yml"; then
  ok "missing job template leaves the pipeline untouched and says so"
else
  bad "missing job template did not fail safe"
fi

echo "== gitops overlay rewrite =="
# Everything here runs against a temp copy, so the generated overlay never lands in the source tree.
gtmp="$tmp/gitops"
cp -R fixtures/gitops "$gtmp"
gout="$(node engine/gitops-rewrite.mjs "$gtmp/substitutions.json" \
        --repo "$gtmp" --state-dir "$gtmp/state" 2>&1)"
grc=$?
if [[ $grc -eq 0 ]]; then
  ok "clean overlay generates (exit 0)"
else
  bad "overlay generation failed — expected exit 0, got $grc"
  printf '%s\n' "$gout" | head -10 | sed 's/^/      /'
fi

if gdiff="$(diff -ru fixtures/gitops/expected "$gtmp/out" 2>&1)"; then
  ok "generated overlay matches fixtures/gitops/expected byte for byte"
else
  bad "generated overlay drifted from fixtures/gitops/expected"
  printf '%s\n' "$gdiff" | head -20 | sed 's/^/      /'
fi

# The ordering exhibit, and the reason this fixture exists. POST-APPLY must run BEFORE the AUTO
# sweep, because the deferred value is a resource id that itself contains a source name prefix.
# AUTO-first produces an id that is syntactically perfect, names a resource nobody ever created,
# and passes the completeness guard clean — a failure the golden diff catches and nothing else does.
if grep -rqF '__DR_POST_APPLY__ingress-identity-resource-id' "$gtmp/out"; then
  ok "POST-APPLY sentinel stamped for the deferred resource id"
else
  bad "POST-APPLY sentinel missing — the deferred resource id was not stamped"
fi
if grep -rqF 'userAssignedIdentities/' "$gtmp/out"; then
  bad "AUTO ran before POST-APPLY — the deferred resource id was rewritten into one that points nowhere"
else
  ok "AUTO did not reach inside the deferred resource id (POST-APPLY ran first)"
fi

cfg="$gtmp/out/core-ingress/configmap.yaml"
if grep -qF '10.200.8.0/24' "$cfg"; then
  ok "AUTO applies longest-first (the specific subnet rule beat the general prefix)"
else
  bad "AUTO did not apply longest-first — the general prefix rule shadowed the specific subnet rule"
fi
if grep -qF '__DR_DECIDE__external-dns-zone' "$cfg" && grep -qF '10.150.0.0/16' "$cfg"; then
  ok "DECIDE stamps a sentinel with no default, and keeps the value where there is one"
else
  bad "DECIDE handled wrongly — expected one sentinel and one kept default"
fi
# Absent from forbidden_residual on purpose: cutover is a customer-led routing step (ARCHITECTURE §17).
if grep -qF 'storefront.contoso.cloud' "$cfg"; then
  ok "cutover hostname survived into the overlay, as intended"
else
  bad "the build rewrote a cutover hostname"
fi

if [[ -d "$gtmp/out/data-plane-app" ]]; then
  bad "a pinned exclusion was generated anyway"
else
  ok "pinned data-plane exclusion not generated"
fi
# A pinned exclusion that no longer matches a real component is stale scope, which is a scope bug.
if grep -qF 'stale exclusion(s) not present in source: retired-legacy-app' <<<"$gout" \
   && grep -qF '"stale_exclusions":["retired-legacy-app"]' <<<"$gout"; then
  ok "stale exclusion surfaced on both stderr and the JSON contract"
else
  bad "stale exclusion was swallowed — summary was: $gout"
fi

if [[ -s "$gtmp/state/gitops-report.md" ]]; then ok "wrote gitops-report.md"; else bad "did not write gitops-report.md"; fi

# A source file that was renamed or deleted must not leave a stale copy behind in the DR overlay,
# which is why the target is wiped rather than written over.
printf 'stale\n' > "$gtmp/out/core-ingress/removed-upstream.yaml"
node engine/gitops-rewrite.mjs "$gtmp/substitutions.json" \
  --repo "$gtmp" --state-dir "$gtmp/state" >/dev/null 2>&1
if [[ -e "$gtmp/out/core-ingress/removed-upstream.yaml" ]]; then
  bad "regeneration left a stale file in the overlay"
else
  ok "regeneration wipes the overlay, so a removed source file cannot linger"
fi

# The guard, driven by an incomplete rule set — which is how a real leak happens, not by the scan
# being wrong. Same source tree, one AUTO pair missing.
gfail="$(node engine/gitops-rewrite.mjs "$gtmp/substitutions-guard-fail.json" \
         --repo "$gtmp" --state-dir "$gtmp/state-fail" 2>&1)"
gfrc=$?
if [[ $gfrc -eq 1 ]] && grep -qF '"ok":false' <<<"$gfail" \
   && grep -qF 'source region token survived' <<<"$gfail"; then
  ok "completeness guard fails the build on a residual source token (exit 1)"
else
  bad "completeness guard did not fail — expected exit 1 with a violation, got $gfrc"
  printf '%s\n' "$gfail" | head -5 | sed 's/^/      /'
fi

echo "== plugin packaging =="
# The framework ships as a plugin, and two things about that are silent when wrong.
#
# First: a plugin's agents and skills resolve ONLY by their scoped `<plugin>:<name>` name. Spawn a
# Builder by its bare name and nothing errors — you get a generic agent with no persona, quietly
# writing the estate. That is the exact failure this project exists to prevent, and no other check
# here can see it, so assert that every agent is referenced scoped and never bare.
#
# Second: ${CLAUDE_PLUGIN_ROOT} is substituted in skill and agent CONTENT only. In an engine script
# it is just an undefined shell variable, which expands to nothing and yields a path like `/engine`.
plugin_name="$(node -e 'process.stdout.write(require("./.claude-plugin/plugin.json").name)' 2>/dev/null || true)"
if [[ -n "$plugin_name" ]]; then
  ok "plugin.json parses (name: $plugin_name)"
else
  bad "plugin.json missing or unparseable"
fi
mkt_name="$(node -e 'const m=require("./.claude-plugin/marketplace.json"); process.stdout.write((m.plugins&&m.plugins[0]&&m.plugins[0].name)||"")' 2>/dev/null || true)"
if [[ -n "$mkt_name" && "$mkt_name" == "$plugin_name" ]]; then
  ok "marketplace.json lists the plugin under the same name, so it is installable"
else
  bad "marketplace entry name '$mkt_name' does not match plugin.json name '$plugin_name'"
fi

bare_refs=""
for f in agents/*.md; do
  [[ -e "$f" ]] || continue
  n="$(basename "$f" .md)"
  # A bare, quoted/backticked agent name in the Orchestrator or a skill is a resolution site.
  # Prose mentions are not delimited on both sides, so they do not match.
  bare_refs+="$(grep -rnoE "['\"\`]${n}['\"\`]" workflows/ skills/ 2>/dev/null || true)"
  if ! grep -rqoE "['\"\`]${plugin_name}:${n}['\"\`]" workflows/ skills/ 2>/dev/null; then
    bad "agent $n is never referenced by its scoped name — is it wired up at all?"
  fi
done
if [[ -n "$bare_refs" ]]; then
  bad "an agent is referenced by its BARE name, which does not resolve — it would spawn a personaless agent"
  printf '%s\n' "$bare_refs" | head -5 | sed 's/^/      /'
else
  ok "every agent is referenced by its scoped ${plugin_name}: name, never bare"
fi
# A plugin's workflows are auto-discovered and each is exposed as a dispatch skill under its
# meta.name. Give a workflow the same name as a skill directory and the generated shim SHADOWS the
# real skill: invoking it returns "call Workflow with these args" instead of the skill body, which
# for this project means skipping Phase-1 discovery, the build-plan gate and every approval gate.
# Nothing errors when that happens — the wrong thing simply loads — so assert the names are disjoint.
collision=""
for w in workflows/*.js; do
  [[ -e "$w" ]] || continue
  wname="$(sed -n '/export const meta/,/^}/p' "$w" | grep -oE "name: *'[^']+'" | head -1 | sed "s/name: *'//; s/'//")"
  [[ -n "$wname" ]] || continue
  if [[ -d "skills/$wname" ]]; then collision+="$w declares meta.name '$wname', which is also skills/$wname/"$'\n'; fi
done
if [[ -n "$collision" ]]; then
  bad "a workflow's meta.name shadows a skill of the same name"
  printf '%s' "$collision" | sed 's/^/      /'
else
  ok "no workflow meta.name shadows a skill directory"
fi
if grep -rq 'CLAUDE_PLUGIN_ROOT' engine/ 2>/dev/null; then
  bad "an engine script uses \${CLAUDE_PLUGIN_ROOT}, which is not substituted outside skill/agent content"
else
  ok "no engine script relies on \${CLAUDE_PLUGIN_ROOT} substitution"
fi

echo "== consuming-repo integration =="
# Everything above drives the engine from inside this repo, where the profile happens to sit next to
# it. That arrangement cannot fail the way a real installation fails: the engine ships in the plugin
# and the profile ships in the estate, so a path that resolves only because the two are adjacent
# looks perfectly healthy here and breaks on first contact with a customer.
#
# So build a scratch consuming repo, laid out the way `repo-map.md` and the framework convention say,
# and drive the engine from it by absolute path with only the documented defaults.
ctmp="$tmp/consuming"
mkdir -p "$ctmp/agentic-dr/profile" "$ctmp/agentic-dr/state/manifests" \
         "$ctmp/dr/terraform/storage" "$ctmp/gitops/prod/components" "$ctmp/.github/workflows"
cp -R "$PROFILE/." "$ctmp/agentic-dr/profile/"
cp fixtures/resolve/state/manifests/*.json "$ctmp/agentic-dr/state/manifests/"
cp fixtures/resolve/dr-pipeline.template.yml "$ctmp/.github/workflows/dr-estate.yml"
cp fixtures/clean-root/*.tf "$ctmp/dr/terraform/storage/"
cp -R fixtures/gitops/source/. "$ctmp/gitops/prod/components/"

# Every invocation below omits the profile/state arguments on purpose: the defaults are the contract.
if ( cd "$ctmp" && bash "$ROOT/engine/lint.sh" dr/terraform/storage ) >/dev/null 2>&1; then
  ok "lint resolves the consuming repo's profile, not one next to the engine"
else
  bad "lint could not find the profile from a consuming repo"
fi
if ( cd "$ctmp" && node "$ROOT/engine/reconcile.mjs" dr/terraform/storage \
       "$ROOT/fixtures/manifests/clean-root.json" ) >/dev/null 2>&1; then
  ok "reconcile runs against a consuming repo's DR root"
else
  bad "reconcile failed from a consuming repo"
fi
if ( cd "$ctmp" && node "$ROOT/engine/resolve.mjs" --sha deadbeef \
       --pipeline .github/workflows/dr-estate.yml ) >/dev/null 2>&1 \
   && [[ -s "$ctmp/agentic-dr/state/run-report.md" ]] \
   && grep -q 'BEGIN generated DR jobs' "$ctmp/.github/workflows/dr-estate.yml"; then
  ok "resolve writes state into the consuming repo and emits its pipeline jobs"
else
  bad "resolve did not resolve the consuming repo's state dir or pipeline"
fi
if ( cd "$ctmp" && node "$ROOT/engine/gitops-rewrite.mjs" ) >/dev/null 2>&1 \
   && [[ -f "$ctmp/gitops/dr/components/core-ingress/deployment.yaml" ]]; then
  ok "gitops-rewrite reads the consuming repo's rules and generates into its target_dir"
else
  bad "gitops-rewrite did not honour the consuming repo's source_dir/target_dir"
fi
# The convention is a default, not a hardcode.
mv "$ctmp/agentic-dr" "$ctmp/platform-dr"
if ( cd "$ctmp" && AGENTIC_DR_DIR=platform-dr bash "$ROOT/engine/lint.sh" dr/terraform/storage ) >/dev/null 2>&1; then
  ok "AGENTIC_DR_DIR relocates the framework directory"
else
  bad "AGENTIC_DR_DIR was ignored — the agentic-dr/ convention is hardcoded somewhere"
fi
# A profile that is not where the estate says must be a usage error. Exiting 0 here would report a
# clean lint on a root nothing actually checked.
lrc=0; ( cd "$ctmp" && AGENTIC_DR_DIR=nope bash "$ROOT/engine/lint.sh" dr/terraform/storage ) >/dev/null 2>&1 || lrc=$?
grc2=0; ( cd "$ctmp" && AGENTIC_DR_DIR=nope node "$ROOT/engine/gitops-rewrite.mjs" ) >/dev/null 2>&1 || grc2=$?
if [[ $lrc -eq 2 && $grc2 -eq 2 ]]; then
  ok "a missing profile is a usage error, never a silent pass"
else
  bad "missing profile did not exit 2 (lint=$lrc gitops=$grc2)"
fi

echo "== genericity =="
# This framework was extracted from one estate's repo, where everything assumed that repo's layout.
# A reintroduced estate path is not a leak — the scrub gate cannot see it, because these are
# ordinary-shaped strings. It is the regression that would quietly make the project single-tenant
# again, which is why it is asserted here instead.
#
# Scope: the BLUEPRINT only. `profile.example/` and `fixtures/` are example estate data and are
# supposed to contain concrete paths; that is the whole point of them. `tools/` is excluded because
# this file necessarily names the literals it searches for, and each is split so this comment and the
# list below cannot match themselves.
#
# Matched WITHOUT a trailing slash: the previous version of this check required one, which is exactly
# how `dr/agentic` survived in ARCHITECTURE.md — inside a parenthetical, no slash, invisible.
origin_paths=(
  "dr/""agentic"          # the origin repo's framework directory
  "dr/""terraform"        # its DR output tree            — repo-map.md owns this
  "terraform/""prod"      # its source roots              — repo-map.md
  "terraform/""connectivity"
  "terraform/""modules"   # its shared modules            — repo-map.md
  "argocd/""prod"         # its GitOps source tree        — gitops-substitutions.json source_dir
  "argocd/""dr"           # its GitOps target tree        — gitops-substitutions.json target_dir
  "gitops/""prod"         # the example profile's values, which are equally not the blueprint's business
  "gitops/""dr"
)
blueprint=(ARCHITECTURE.md README.md engine agents skills workflows docs .claude-plugin)
hits=""
for p in "${origin_paths[@]}"; do
  hits+="$(grep -rn --exclude-dir=.git -- "$p" "${blueprint[@]}" 2>/dev/null || true)"
done
if [[ -n "$hits" ]]; then
  bad "an estate path the profile owns was hardcoded into the blueprint"
  printf '%s\n' "$hits" | head -8 | sed 's/^/      /'
else
  ok "the blueprint names no estate path — every one is a pointer to a profile row"
fi

# The engine must never resolve the profile relative to its own location: it ships in the plugin, the
# profile ships in the consuming repo, and neither may assume where the other lives. Comments are
# stripped first — gitops-rewrite.mjs explains in prose why it does NOT do this, and that explanation
# must not read as a violation.
selfref="$(sed -E 's://.*$::; s:#.*$::' engine/*.mjs engine/*.sh 2>/dev/null \
           | grep -nE 'SCRIPT_DIR.*profile' || true)"
if [[ -n "$selfref" ]]; then
  bad "an engine script resolves the profile relative to itself: $selfref"
else
  ok "engine resolves the profile through arguments, not its own location"
fi

echo "== release gate =="
expect 0 "no source-estate tokens in the tree" -- bash tools/scrub-check.sh
expect 0 "no source-estate tokens in git history" -- bash tools/scrub-check.sh --history

echo
echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]] || exit 1
