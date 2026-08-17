#!/usr/bin/env bash
#
# demo/try.sh — stand up the fictional estate somewhere scratch, ready to build against.
#
# The estate must not be built in place (demo/README.md explains why: a run writes into the estate,
# and it pins the commit of the repo it is invoked in). Doing that by hand is four steps with two
# footguns — forgetting the initial commit, so discovery has no SHA to pin, and pointing
# --plugin-dir at the wrong tree. This does the four steps and prints the fifth.
#
# Resolving the source relative to this script is correct here and is not the thing ARCHITECTURE
# §16.13 forbids: that rule is about the engine, which ships apart from the profile and may never
# assume where it lives. This script copies its own sibling directory, which it necessarily knows.
#
# Usage:   demo/try.sh [target-dir]     (default: ~/agentic-dr-demo)
# Exit:    0 = ready, 1 = refused or a prerequisite is missing.
#
set -euo pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN="$(dirname -- "$SRC")"
TARGET="${1:-$HOME/agentic-dr-demo}"

die() { printf 'try.sh: %s\n' "$1" >&2; exit 1; }

# Never clobber. The target is where someone's experiment lives, and a second run of this script
# after a build would silently discard generated roots and run state.
if [[ -e "$TARGET" ]] && [[ -n "$(ls -A -- "$TARGET" 2>/dev/null)" ]]; then
  die "$TARGET exists and is not empty. Remove it, or pass a different path."
fi

command -v node >/dev/null 2>&1 || die "node is required (the engine's deterministic half runs on it)."
command -v git  >/dev/null 2>&1 || die "git is required (discovery pins a commit)."

mkdir -p -- "$TARGET"
# -a would carry the source's ownership and times into what is meant to be a fresh estate.
cp -R -- "$SRC"/. "$TARGET"/
rm -f -- "$TARGET/try.sh"

cd -- "$TARGET" || die "could not enter $TARGET"
git init -q
git add -A
git -c user.name="agentic-dr demo" -c user.email="demo@example.com" \
    commit -qm "fictional estate, copied from the agentic-dr demo"

printf '\n  estate ready: %s\n' "$TARGET"
printf '  pinned commit: %s\n\n' "$(git rev-parse --short HEAD)"

if ! command -v terraform >/dev/null 2>&1; then
  printf '  note: terraform is not installed. Generation and both checks still run;\n'
  printf '        only the fmt/validate step at the end of a dry run needs it.\n\n'
fi

printf '  Try the deterministic half right now — no model, no cloud, instant:\n\n'
printf '    cd %s\n' "$TARGET"
printf '    bash %s/engine/lint.sh terraform/prod/aks agentic-dr/profile/lint-patterns.txt\n' "$PLUGIN"
printf '      → exits 1 on a source root, which is the point: it is production, not DR.\n\n'
printf '    node %s/engine/gitops-rewrite.mjs\n' "$PLUGIN"
printf '      → regenerates the DR overlay; diff gitops/prod against gitops/dr to see the transform.\n\n'
printf '  Then the full build, which does spawn agents and takes a few minutes:\n\n'
printf '    claude --plugin-dir %s\n' "$PLUGIN"
printf '    /agentic-dr:dr-build dry-run\n\n'
printf '  It stops at the build-plan gate before generating anything. Nothing here reaches a cloud.\n\n'
