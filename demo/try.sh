#!/usr/bin/env bash
#
# demo/try.sh — stand up the fictional estate, then walk through it one step at a time.
#
# The estate must not be built in place (demo/README.md explains why: a run writes into the estate,
# and it pins the commit of the repo it is invoked in). Doing that by hand is four steps with two
# footguns — forgetting the initial commit, so discovery has no SHA to pin, and pointing
# --plugin-dir at the wrong tree.
#
# Interactive by default: it pauses before each step so the output can be talked over, which is the
# point when demonstrating this to a room. Every step is self-contained — a title, why it matters,
# the command it runs, and the takeaway — so a screenshot of one step carries its own argument.
#
# Resolving the source relative to this script is correct here and is not the thing ARCHITECTURE
# §16.13 forbids: that rule is about the engine, which ships apart from the profile and may never
# assume where it lives. This script copies its own sibling directory, which it necessarily knows.
#
# Usage:   demo/try.sh [target-dir] [options]
#
#   -l, --list        print the walk — titles, narration, commands — and run nothing at all
#   -s, --step N[,N]  run only these steps, reusing the estate that is already there
#       --reuse       keep an existing estate as it is, rather than asking to replace it
#   -y, --yes         no prompts: set up, run every step that needs no human, print the rest
#       --no-color    plain output (NO_COLOR in the environment does the same)
#   -h, --help        this text
#
# Exit:    0 = done, 1 = refused, aborted, or a prerequisite is missing.
#
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname -- "$SRC")"
TARGET=""
ASSUME_YES=0
USE_COLOR=1
LIST_ONLY=0
REUSE=0
SELECTED=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)   ASSUME_YES=1 ;;
    -l|--list)  LIST_ONLY=1 ;;
    --reuse)    REUSE=1 ;;
    --no-color) USE_COLOR=0 ;;
    -s|--step)  shift; SELECTED="${1:-}"; [[ -n "$SELECTED" ]] || { printf 'try.sh: --step needs a number\n' >&2; exit 1; } ;;
    --step=*)   SELECTED="${1#--step=}" ;;
    # Read to the end of the header block rather than to a pinned line number, which silently
    # truncates the help the first time someone adds a paragraph above it.
    -h|--help)  awk 'NR>2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' < "${BASH_SOURCE[0]}"; exit 0 ;;
    -*)         printf 'try.sh: unknown option %s\n' "$1" >&2; exit 1 ;;
    *)          TARGET="$1" ;;
  esac
  shift
done
[[ -n "$TARGET" ]] || TARGET="$HOME/agentic-dr-demo"
# Asking for one step means working on the estate that is already there, not rebuilding it.
[[ -n "$SELECTED" ]] && REUSE=1

INTERACTIVE=0
if [[ -t 0 ]] && [[ $ASSUME_YES -eq 0 ]]; then INTERACTIVE=1; fi

# Colour only when a terminal is watching, so piped output stays clean.
if [[ -t 1 ]] && [[ $USE_COLOR -eq 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  CY=$'\033[36m'; GN=$'\033[32m'; RD=$'\033[31m'; YL=$'\033[33m'
else
  B=""; DIM=""; R=""; CY=""; GN=""; RD=""; YL=""
fi
HR="$(printf '─%.0s' {1..78})"
HR_SHORT="$(printf '─%.0s' {1..52})"

die() { printf '\n  %stry.sh: %s%s\n\n' "$RD" "$1" "$R" >&2; exit 1; }

# Home-relative paths keep the header readable, and readable on a projector. The tilde comes from a
# variable because a literal one in the replacement is either expanded or quoted into the output.
TILDE='~'
pretty() { printf '%s' "${1/#$HOME/$TILDE}"; }

# Wrap prose to a fixed width so every screenshot has the same measure.
wrap() { # text  indent  width  colour
  local line
  while IFS= read -r line; do
    printf '%s%s%s%s\n' "$2" "${4:-}" "$line" "${4:+$R}"
  done < <(printf '%s\n' "$1" | fold -s -w "${3:-74}" | sed 's/ *$//')
}

# Labels are padded by character count rather than by printf's %-11s, which pads by *byte* and so
# under-pads any label with a ✓ or a ▸ in it — a one-column drift that shows up in a screenshot.
PAD="           "
field() { # label  text  [label-colour]
  local line first=1
  while IFS= read -r line; do
    if [[ $first -eq 1 ]]; then
      printf '  %s%s%s%s  %s\n' "${3:-$DIM}" "$1" "$R" "${PAD:${#1}}" "$line"; first=0
    else
      printf '               %s\n' "$line"
    fi
  done < <(printf '%s\n' "$2" | fold -s -w 62 | sed 's/ *$//')
}

# Values here carry their own colour codes, which fold would miscount, so they are never wrapped.
kv() { printf '  %s%s%s%s  %s\n' "$DIM" "$1" "$R" "${PAD:${#1}}" "$2"; }

takeaway() { # the one line a slide should keep
  printf '\n'
  field "✓ takeaway" "$1" "$B$GN"
}

# Ask a yes/no question. Default is encoded in the prompt: [Y/n] yes, [y/N] no.
ask() {
  local prompt="$1" default="$2" reply
  # Written out rather than folded into an || group: under set -e the short form works, but only
  # because of an exemption that is easy to break with an innocent edit.
  if [[ $INTERACTIVE -eq 0 ]]; then
    [[ "$default" == "y" ]] && return 0
    return 1
  fi
  read -r -p "$prompt " reply || reply=""
  reply="${reply:-$default}"
  [[ "$reply" == [Yy]* ]] && return 0
  return 1
}

# ---------------------------------------------------------------- the walk ----
# Narration lives in these arrays so --list can print the whole walk without an estate, and so a
# step's text is edited in one place rather than in the middle of the code that runs it.
STEP_TITLE=(
  "THE ESTATE — what a run discovers"
  "THE INVARIANT LINT — the leakage tripwire"
  "THE GITOPS REWRITER — semantic, not find-and-replace"
  "THE FULL BUILD — where the agents come in"
)
STEP_BLURB=(
  "Terraform roots on disk. Discovery finds every one of them on the pinned commit; the profile's scope rules drop the few that must never be regenerated. Inclusions are discovered, only exclusions are pinned — so a new root is in scope by default, and a silently missing DR root is never the quiet outcome."
  "One question, asked of one root: does anything in here still point at live production? This root IS production, so every answer is yes — which is exactly what a generated DR root must never look like. A plain text search, no model, about a second."
  "It regenerates the DR overlay from the production manifests — the whole tree, from nothing, on every run. Region, load-balancer address and telemetry workspace are rewritten; one value is kept and handed to a human instead."
  "Everything so far was deterministic: no model, repeatable, an exit code you can gate on. This step spawns one Builder agent per in-scope root, and the engine above checks their work. It stops at the build-plan gate before generating anything, and it never reaches a cloud."
)
STEP_WATCH=(
  "five roots, three in scope — and the reason each exclusion gives"
  "nine failures, all of them source-estate leakage"
  "the one line that does NOT change"
  "the gate: nothing is generated until a human approves the plan"
)
STEP_CMD=(
  "reads terraform/ and agentic-dr/profile/scope-rules.md"
  "bash %s/engine/lint.sh terraform/prod/aks agentic-dr/profile/lint-patterns.txt"
  "node %s/engine/gitops-rewrite.mjs"
  "claude --plugin-dir %s   →   /agentic-dr:dry-run"
)
STEP_TAKEAWAY=(
  "Scope is a decision the estate owns, in one reviewable file — not something a model infers per run."
  "A generated DR root that looked like this is rejected before any plan runs."
  "Rewritten where it is a source-estate token, kept where it is not. That single line is the whole semantic-versus-lexical argument."
  "The agents write; the deterministic engine checks. That is why this is auditable rather than hopeful."
)
STEP_COUNT=${#STEP_TITLE[@]}
TAKEAWAY=""

step_header() {
  local n="$1" idx=$(( $1 - 1 )) cmd
  printf '\n%s%s%s\n' "$CY" "$HR" "$R"
  printf ' %s%sSTEP %s of %s%s   %s%s%s\n' "$B" "$CY" "$n" "$STEP_COUNT" "$R" "$B" "${STEP_TITLE[$idx]}" "$R"
  printf '%s%s%s\n\n' "$CY" "$HR" "$R"
  wrap "${STEP_BLURB[$idx]}" "  " 74 "$DIM"
  printf '\n'
  if [[ -n "${STEP_WATCH[$idx]}" ]]; then field "▸ watch for" "${STEP_WATCH[$idx]}" "$YL"; fi
  # shellcheck disable=SC2059  # the entry is the format string, by design
  cmd="$(printf "${STEP_CMD[$idx]}" "$(pretty "$PLUGIN")")"
  field "runs" "$cmd"
  printf '\n'
}

# Pause before a step so its output can be introduced. Returns 1 if the step is skipped.
prompt_step() {
  [[ $INTERACTIVE -eq 1 ]] || return 0
  local reply
  read -r -p "  ${DIM}[enter] run   [s] skip   [q] quit${R}  › " reply || reply="q"
  case "$reply" in
    [Ss]*) printf '  %sskipped%s\n' "$DIM" "$R"; return 1 ;;
    [Qq]*) printf '  %sstopping here. The estate is ready at %s%s\n\n' "$DIM" "$(pretty "$TARGET")" "$R"; exit 0 ;;
    *) printf '\n' ;;
  esac
}

# --- step 1: the estate ---------------------------------------------------------------------------
# The excluded set and its reasons are read out of the profile rather than restated here, so the
# walk keeps telling the truth if the profile changes.
excluded_reason() {
  awk -v want="$1" '
    /^## Excluded roots/ { t = 1; next }
    t && /^## /          { exit }
    t && /^\| `/ {
      split($0, f, "|"); roots = f[2]; why = f[3]
      gsub(/`/, "", roots); gsub(/[ \t]/, "", roots); gsub(/\*/, "", why)
      sub(/^[ \t]+/, "", why); sub(/[ \t]+$/, "", why)
      n = split(roots, a, ",")
      for (i = 1; i <= n; i++) if (a[i] == want) {
        if (length(why) > 44) why = substr(why, 1, 43) "…"
        print why; exit
      }
    }' agentic-dr/profile/scope-rules.md
}

step_estate() {
  local d name why lookups in_scope=0 excluded=0
  for d in terraform/*/*/; do
    [[ -d "$d" ]] || continue
    # modules/ is shared read-only code, not a root — repo-map.md names it as such.
    case "$d" in terraform/modules/*) continue ;; esac
    compgen -G "$d*.tf" >/dev/null || continue
    name="${d#terraform/}"; name="${name%/}"
    why=""; why="$(excluded_reason "$name")"
    if [[ -n "$why" ]]; then
      excluded=$(( excluded + 1 ))
      printf '    %-22s %s✗ excluded%s  %s%s%s\n' "$name" "$RD" "$R" "$DIM" "$why" "$R"
    else
      in_scope=$(( in_scope + 1 ))
      printf '    %-22s %s✓ in scope%s\n' "$name" "$GN" "$R"
      # No data lookups is a normal answer, and under pipefail an empty grep would end the walk.
      lookups=""
      lookups="$(grep -ho 'data "azurerm_[a-z_]*"' "$d"*.tf 2>/dev/null \
                 | sed 's/data "//; s/"$//' | sort -u | tr '\n' ',' | sed 's/,/, /g; s/, $//' || true)"
      if [[ -n "$lookups" ]]; then
        printf '      %s↳ resolves %s by name%s\n' "$DIM" "$lookups" "$R"
      fi
    fi
  done
  printf '\n    %s%s roots on disk  ·  %s in scope  ·  %s excluded by agentic-dr/profile/scope-rules.md%s\n' \
         "$DIM" "$(( in_scope + excluded ))" "$in_scope" "$excluded" "$R"
  TAKEAWAY="Scope is a decision the estate owns, in one reviewable file — not something a model infers per run. $in_scope roots build, $excluded do not."
}

# --- step 2: the invariant lint -------------------------------------------------------------------
step_lint() {
  local out status=0 hits
  # Exits 1 by design. Under set -e that would end the script, so the status is taken deliberately.
  out="$(bash "$PLUGIN/engine/lint.sh" terraform/prod/aks agentic-dr/profile/lint-patterns.txt)" || status=$?
  hits="$(printf '%s\n' "$out" | grep -c '✗' || true)"
  printf '%s\n' "$out" | sed -E "s/^(  ✗.*)/${RD}\1${R}/; s/^(lint: FAIL.*)/${B}${RD}\1${R}/; s/^(lint: PASS.*)/${B}${GN}\1${R}/; s/^/  /"
  TAKEAWAY="$hits leakage checks failed, exit $status. A generated DR root that looked like this is rejected before any plan runs."
}

# --- step 3: the GitOps rewriter ------------------------------------------------------------------
step_gitops() {
  local json k v changed
  [[ -e gitops/dr ]] || printf '  %sgitops/dr does not exist yet — the rewriter creates the whole tree.%s\n\n' "$DIM" "$R"
  json="$(node "$PLUGIN/engine/gitops-rewrite.mjs")"

  # The engine already publishes its decisions as JSON. Reading them back beats narrating them
  # here, where they would drift the first time a rule changes.
  # shellcheck disable=SC2016  # this is JavaScript, not shell — nothing here should expand
  node -e '
    const j = JSON.parse(process.argv[1])
    console.log(`generated\t${j.generated_components.join(", ")}   (${j.applied_count} substitutions applied)`)
    for (const d of j.post_apply) console.log(`deferred\t${d.what}`)
    for (const d of j.decide)     console.log(`confirm\t${d.what}`)
    for (const v of j.violations) console.log(`violation\t${v.what || v}`)
  ' "$json" | while IFS=$'\t' read -r k v; do
    printf '    %s%-10s%s %s\n' "$CY" "$k" "$R" "$v"
  done

  printf '\n  %s%s%s\n' "$DIM" \
         "gitops/prod/components/ingress/values.yaml → gitops/dr/components/ingress/values.yaml" "$R"
  changed="$(diff -u gitops/prod/components/ingress/values.yaml \
                     gitops/dr/components/ingress/values.yaml | grep -c '^+[^+]' || true)"
  diff -u gitops/prod/components/ingress/values.yaml \
          gitops/dr/components/ingress/values.yaml \
    | tail -n +3 \
    | sed -E "s/^(-.*)/${RD}\1${R}/; s/^(\+.*)/${GN}\1${R}/; s/^(@@.*)/${DIM}\1${R}/; s/^/    /" || true
  TAKEAWAY="$changed lines rewritten; the on-prem range deliberately not. Rewritten where it is a source-estate token, kept where it is not — that is the whole semantic-versus-lexical argument."
}

# --- step 4: the full build -----------------------------------------------------------------------
step_build() {
  if ! command -v claude >/dev/null 2>&1; then
    printf '  %sclaude is not on PATH — install Claude Code, then run:%s\n' "$DIM" "$R"
    printf '    cd %s && claude --plugin-dir %s\n' "$(pretty "$TARGET")" "$(pretty "$PLUGIN")"
  elif ask "  ${DIM}launch Claude Code in the estate now? [y/N]${R}" "n"; then
    printf '\n  %sOnce it opens, run:%s  /agentic-dr:dry-run\n\n' "$B" "$R"
    exec claude --plugin-dir "$PLUGIN"
  else
    printf '  %swhen you are ready:%s\n' "$DIM" "$R"
    printf '    cd %s && claude --plugin-dir %s\n' "$(pretty "$TARGET")" "$(pretty "$PLUGIN")"
    printf '    /agentic-dr:dry-run\n'
  fi
}

run_step() {
  case "$1" in
    1) step_estate ;;
    2) step_lint ;;
    3) step_gitops ;;
    4) step_build ;;
  esac
}

banner() {
  printf '\n  %s%sagentic-dr%s %s— a walkthrough on a fictional estate%s\n' "$B" "$CY" "$R" "$B" "$R"
  printf '  %s%s%s\n\n' "$CY" "$HR_SHORT" "$R"
  wrap "A DR estate kept as a parallel copy of production drifts, and you find out on DR day. This regenerates it from current main instead — agents write the Terraform, deterministic scripts check it." "  " 74 "$DIM"
  printf '\n'
  wrap "Everything here is invented: the customer, the regions, the address ranges, the GUIDs. Nothing reaches a cloud. Every step runs locally." "  " 74 "$DIM"
  printf '\n'
}

# ---------------------------------------------------------------- --list ------
if [[ $LIST_ONLY -eq 1 ]]; then
  banner
  for i in $(seq 1 "$STEP_COUNT"); do step_header "$i"; done
  printf '%s%s%s\n\n' "$CY" "$HR" "$R"
  printf '  %srun it:%s  demo/try.sh            %s(all %s steps, one pause before each)%s\n' "$B" "$R" "$DIM" "$STEP_COUNT" "$R"
  printf '           demo/try.sh --step 3   %s(just that one, on an estate already set up)%s\n\n' "$DIM" "$R"
  exit 0
fi

# ---------------------------------------------------------------- set-up ------
command -v node >/dev/null 2>&1 || die "node is required (the engine's deterministic half runs on it)."
command -v git  >/dev/null 2>&1 || die "git is required (discovery pins a commit)."

banner

FRESH=1
if [[ -e "$TARGET" ]] && [[ -n "$(ls -A -- "$TARGET" 2>/dev/null)" ]]; then
  if [[ $REUSE -eq 1 ]]; then
    FRESH=0
  elif [[ $INTERACTIVE -eq 1 ]]; then
    printf '  %s%s already exists and is not empty.%s\n' "$B" "$(pretty "$TARGET")" "$R"
    wrap "It may hold a build worth keeping, so nothing is overwritten without a yes." "  " 74 "$DIM"
    printf '\n'
    read -r -p "  ${DIM}[enter] reuse it   [d] delete and rebuild   [q] quit${R}  › " reply || reply="q"
    case "$reply" in
      [Dd]*) rm -rf -- "$TARGET" ;;
      [Qq]*) die "left alone. Pass a different path: demo/try.sh /some/where" ;;
      *)     FRESH=0 ;;
    esac
  else
    die "$(pretty "$TARGET") exists and is not empty. Pass --reuse to work in it, or a different path."
  fi
fi

if [[ $FRESH -eq 1 ]]; then
  mkdir -p -- "$TARGET"
  # -a would carry the source's ownership and times into what is meant to be a fresh estate.
  cp -R -- "$SRC"/. "$TARGET"/
  rm -f -- "$TARGET/try.sh"

  # A build run inside demo/ leaves transients behind: run state, and the provider binaries
  # `terraform init` drops into every generated root. They are git-ignored there, so they are easy to
  # leave lying around, and cp -R takes them regardless. Carried into a fresh estate they hand over a
  # half-built one — resolve.mjs reads a stale manifest as a component that is already built, and the
  # walk below then demonstrates the wrong thing.
  rm -rf -- "$TARGET/agentic-dr/state/manifests" "$TARGET/agentic-dr/state/build.lock"
  find "$TARGET" \( -name .terraform -o -name .terraform.lock.hcl \) -prune -exec rm -rf -- {} +

  cd -- "$TARGET" || die "could not enter $TARGET"
  git init -q
  git add -A
  git -c user.name="agentic-dr demo" -c user.email="demo@example.com" \
      commit -qm "fictional estate, copied from the agentic-dr demo"
else
  cd -- "$TARGET" || die "could not enter $TARGET"
  [[ -d agentic-dr/profile ]] || die "$(pretty "$TARGET") does not look like the demo estate (no agentic-dr/profile)."
fi

if [[ $FRESH -eq 1 ]]; then
  kv "estate" "$(pretty "$TARGET")   ${DIM}fresh copy${R}"
else
  kv "estate" "$(pretty "$TARGET")   ${DIM}reused as it stands${R}"
fi
kv "commit" "$(git rev-parse --short HEAD)   ${DIM}what a run pins and builds from${R}"
kv "plugin" "$(pretty "$PLUGIN")"
if command -v terraform >/dev/null 2>&1; then
  kv "terraform" "$(terraform version -json 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).terraform_version)}catch{console.log("present")}})')"
else
  kv "terraform" "${YL}not installed${R} ${DIM}— only the fmt/validate step of a full run needs it${R}"
fi

# ---------------------------------------------------------------- the walk ----
if [[ -n "$SELECTED" ]]; then
  STEPS="${SELECTED//,/ }"
else
  STEPS="$(seq 1 "$STEP_COUNT" | tr '\n' ' ')"
fi

for n in $STEPS; do
  if [[ ! "$n" =~ ^[1-9][0-9]*$ ]] || [[ "$n" -gt "$STEP_COUNT" ]]; then
    die "there is no step $n. There are $STEP_COUNT — see demo/try.sh --list."
  fi
  step_header "$n"
  prompt_step || continue
  TAKEAWAY=""
  run_step "$n"
  [[ -n "$TAKEAWAY" ]] || TAKEAWAY="${STEP_TAKEAWAY[$(( n - 1 ))]}"
  takeaway "$TAKEAWAY"
done

# ---------------------------------------------------------------- close -------
printf '\n%s%s%s\n' "$CY" "$HR" "$R"
printf ' %sWHAT THIS SHOWED%s\n\n' "$B" "$R"
printf '  %s·%s exclusions are pinned and reviewable; inclusions are discovered\n' "$CY" "$R"
printf '  %s·%s the deterministic half is a correctness oracle, not another opinion\n' "$CY" "$R"
printf '  %s·%s the agents write the estate, the engine decides whether it may ship\n\n' "$CY" "$R"
kv "estate" "$(pretty "$TARGET")"
kv "reset" "${DIM}cd $(pretty "$TARGET") && git checkout -- . && git clean -fd${R}"
kv "again" "${DIM}demo/try.sh --step 3        one step, on this same estate${R}"
printf '\n'
