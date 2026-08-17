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
# point when demonstrating this to a room. With no TTY it sets the estate up, prints the commands
# and exits, so it stays usable from a pipe or a script.
#
# Resolving the source relative to this script is correct here and is not the thing ARCHITECTURE
# §16.13 forbids: that rule is about the engine, which ships apart from the profile and may never
# assume where it lives. This script copies its own sibling directory, which it necessarily knows.
#
# Usage:   demo/try.sh [target-dir] [-y|--yes]
# Exit:    0 = done, 1 = refused, aborted, or a prerequisite is missing.
#
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname -- "$SRC")"
TARGET=""
ASSUME_YES=0

for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '3,19p' -- "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) printf 'try.sh: unknown option %s\n' "$arg" >&2; exit 1 ;;
    *) TARGET="$arg" ;;
  esac
done
[[ -n "$TARGET" ]] || TARGET="$HOME/agentic-dr-demo"

INTERACTIVE=0
if [[ -t 0 ]] && [[ $ASSUME_YES -eq 0 ]]; then INTERACTIVE=1; fi

# Colour only when a terminal is watching, so piped output stays clean.
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
else
  B=""; DIM=""; R=""
fi

die() { printf 'try.sh: %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
rule() { printf '%s────────────────────────────────────────────────────────────%s\n' "$DIM" "$R"; }

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

# Pause before a step so its output can be introduced. Returns 1 if the step is skipped.
step() {
  local n="$1" title="$2" blurb="$3"
  rule
  printf '%s[%s] %s%s\n' "$B" "$n" "$title" "$R"
  printf '%s%s%s\n\n' "$DIM" "$blurb" "$R"
  [[ $INTERACTIVE -eq 1 ]] || return 0
  local reply
  read -r -p "  enter to run, s to skip, q to quit: " reply || reply="q"
  case "$reply" in
    [Ss]*) say "  skipped"; return 1 ;;
    [Qq]*) say "  stopping here. The estate is ready at $TARGET"; exit 0 ;;
    *) printf '\n' ;;
  esac
}

# ---------------------------------------------------------------- set-up ------
command -v node >/dev/null 2>&1 || die "node is required (the engine's deterministic half runs on it)."
command -v git  >/dev/null 2>&1 || die "git is required (discovery pins a commit)."

if [[ -e "$TARGET" ]] && [[ -n "$(ls -A -- "$TARGET" 2>/dev/null)" ]]; then
  say ""
  say "  ${B}$TARGET already exists and is not empty.${R}"
  say "  ${DIM}It may hold a build worth keeping, so nothing is overwritten without a yes.${R}"
  say ""
  if ask "  replace it? [y/N]" "n"; then
    rm -rf -- "$TARGET"
  else
    die "left alone. Pass a different path: demo/try.sh /some/where"
  fi
fi

mkdir -p -- "$TARGET"
# -a would carry the source's ownership and times into what is meant to be a fresh estate.
cp -R -- "$SRC"/. "$TARGET"/
rm -f -- "$TARGET/try.sh"

cd -- "$TARGET" || die "could not enter $TARGET"
git init -q
git add -A
git -c user.name="agentic-dr demo" -c user.email="demo@example.com" \
    commit -qm "fictional estate, copied from the agentic-dr demo"

printf '\n  %sestate ready%s  %s\n' "$B" "$R" "$TARGET"
printf '  pinned commit  %s\n' "$(git rev-parse --short HEAD)"
if ! command -v terraform >/dev/null 2>&1; then
  printf '  %snote: terraform is missing. Everything below still runs; only the fmt/validate\n' "$DIM"
  printf '  step at the end of a full dry run needs it.%s\n' "$R"
fi
printf '\n'

if [[ $INTERACTIVE -eq 0 ]]; then
  say "  Run these from $TARGET:"
  say ""
  say "    bash $PLUGIN/engine/lint.sh terraform/prod/aks agentic-dr/profile/lint-patterns.txt"
  say "    node $PLUGIN/engine/gitops-rewrite.mjs"
  say "    claude --plugin-dir $PLUGIN     then:  /agentic-dr:dry-run"
  say ""
  exit 0
fi

# ---------------------------------------------------------------- the walk ----
if step "1/3" "The invariant lint, against a production root" \
   "It asks one question: does anything here still point at live production? This root is
  production, so every answer is yes. A plain text search, no model, about a second."; then
  # Exits 1 by design. Under set -e that would end the script, so the status is taken deliberately.
  lint_status=0
  bash "$PLUGIN/engine/lint.sh" terraform/prod/aks agentic-dr/profile/lint-patterns.txt || lint_status=$?
  printf '\n  %sexit %s — a generated DR root that looked like this would be rejected before any plan.%s\n' \
         "$DIM" "$lint_status" "$R"
fi

if step "2/3" "The GitOps rewriter, and the diff that matters" \
   "It regenerates the DR overlay from the production manifests. Watch the line that does
  NOT change: the on-prem range is not a source-estate token, and a blind sweep would have
  rewritten it."; then
  node "$PLUGIN/engine/gitops-rewrite.mjs" >/dev/null
  printf '  %s%s%s\n\n' "$DIM" "gitops/prod/components/ingress/values.yaml → gitops/dr/..." "$R"
  diff -u gitops/prod/components/ingress/values.yaml \
          gitops/dr/components/ingress/values.yaml | tail -n +3 || true
fi

if step "3/3" "The full build" \
   "This one spawns a Builder per in-scope root and takes a few minutes. It stops at the
  build-plan gate before generating anything, and it never reaches a cloud."; then
  if ! command -v claude >/dev/null 2>&1; then
    say "  claude is not on PATH — install Claude Code, then run:"
    say "    cd $TARGET && claude --plugin-dir $PLUGIN"
  elif ask "  launch Claude Code here now? [y/N]" "n"; then
    say ""
    say "  ${B}Once it opens, run:${R}  /agentic-dr:dry-run"
    say ""
    exec claude --plugin-dir "$PLUGIN"
  else
    say "  when you are ready:"
    say "    cd $TARGET && claude --plugin-dir $PLUGIN"
    say "    /agentic-dr:dry-run"
  fi
fi

rule
printf '\n  estate: %s   %sreset it with: git checkout -- . && git clean -fd%s\n\n' "$TARGET" "$DIM" "$R"
