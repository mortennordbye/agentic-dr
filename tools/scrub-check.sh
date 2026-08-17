#!/usr/bin/env bash
#
# tools/scrub-check.sh — the release gate for this repository.
#
# This project was extracted from a private Azure estate. Every identifier belonging to that estate
# must stay out of the published tree AND out of the git history, because the repository is public:
# a force-push does not reliably retract a leaked blob.
#
# Deterministic, no LLM. Same technique as the framework's own invariant lint (ARCHITECTURE §11),
# pointed at this repository rather than at a generated Terraform root.
#
# Usage:
#   scrub-check.sh                 # scan the working tree (excluding .git)
#   scrub-check.sh --history       # scan every blob in every commit as well
#   scrub-check.sh --stdin         # scan stdin (e.g. `git log -p | scrub-check.sh --stdin`)
#   scrub-check.sh <path>...       # scan specific paths
#
# Exit: 0 = clean, 1 = forbidden token found, 2 = usage / environment error.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PATTERNS="${SCRUB_PATTERNS:-$SCRIPT_DIR/scrub-patterns.txt}"

[[ -f "$PATTERNS" ]] || { echo "scrub: patterns file not found: $PATTERNS" >&2; exit 2; }

mode="tree"
paths=()
case "${1:-}" in
  --history) mode="history" ;;
  --stdin)   mode="stdin" ;;
  --help|-h) sed -n '3,18p' "$0"; exit 0 ;;
  "")        ;;
  *)         mode="paths"; paths=("$@") ;;
esac

# Read the patterns file into parallel arrays. The reason column is what makes a failure actionable:
# a bare regex tells the next person nothing about why a match is a problem.
kinds=()
finds=()
allows=()
reasons=()
while IFS=$'\t' read -r kind a b c; do
  [[ -z "${kind:-}" || "${kind:0:1}" == "#" ]] && continue
  case "$kind" in
    FORBIDDEN) kinds+=("FORBIDDEN"); finds+=("$a"); allows+=("");   reasons+=("${b:-unspecified}") ;;
    EXTRACT)   kinds+=("EXTRACT");   finds+=("$a"); allows+=("$b"); reasons+=("${c:-unspecified}") ;;
    *) echo "scrub: unknown pattern kind '$kind' in $PATTERNS" >&2; exit 2 ;;
  esac
done < "$PATTERNS"

[[ ${#finds[@]} -gt 0 ]] || { echo "scrub: no patterns loaded from $PATTERNS" >&2; exit 2; }

# The scan target is materialised once, so history and tree modes share one matching loop.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
haystack="$tmp/haystack"

case "$mode" in
  stdin)
    cat > "$haystack"
    ;;
  history)
    # Every commit patch reachable from any ref, so a token that existed only in a deleted or
    # amended file is still caught. The working tree is scanned separately below.
    #
    # SVG path data is stripped here as it is in tree mode: this mode sees one flat stream rather
    # than files, so the per-extension strip cannot apply. Nothing else is exempt — because the
    # patterns file checks shapes rather than tokens, it passes its own checks.
    ( cd "$REPO_ROOT" && git log --all -p --no-color ) 2>/dev/null \
      | perl -pe 's/\sd="[^"]*"/ /g' > "$haystack" || {
      echo "scrub: not a git repository: $REPO_ROOT" >&2; exit 2; }
    ;;
  *)
    :
    ;;
esac

# Build the file list for tree/paths mode. Excludes .git and generated/vendored trees. The patterns
# file is NOT exempt: it checks shapes, not tokens, so it satisfies its own checks — which is worth
# keeping true, since an exempt file is a blind spot.
list_files() {
  local -a roots
  if [[ ${#paths[@]} -gt 0 ]]; then roots=("${paths[@]}"); else roots=("$REPO_ROOT"); fi
  find "${roots[@]}" \
    -type d \( -name .git -o -name node_modules -o -name .terraform \) -prune -o \
    -type f -print 2>/dev/null || true
}

fail=0
report() {
  printf '  \xE2\x9C\x97 %s\n' "$1"
  fail=1
}

# scan_one <file> <label> — apply every pattern to one file.
scan_one() {
  local target="$1" label="$2" i hit offenders
  # SVG path data is a run of coordinates like "8.205 11.385.6.113", which matches the IPv4 shape
  # about as often as it matches nothing. Strip `d="..."` attributes first — the same move lint.sh
  # makes when it strips HCL comments before matching. Coordinates are not prose and cannot carry an
  # identifier, so nothing detectable is lost.
  case "$target" in
    *.html|*.svg)
      perl -0pe 's/\sd="[^"]*"/ /gs' "$target" > "$tmp/stripped" 2>/dev/null && target="$tmp/stripped"
      ;;
  esac
  for i in "${!finds[@]}"; do
    if [[ "${kinds[$i]}" == "FORBIDDEN" ]]; then
      if hit="$(grep -inE -m1 -- "${finds[$i]}" "$target" 2>/dev/null)"; then
        report "${reasons[$i]} — ${label}:${hit%%:*}"
      fi
    else
      # EXTRACT: pull every match of the find pattern, drop the ones the allow pattern accepts, and
      # report whatever is left. Reporting the offending VALUE is safe here (it is, by definition,
      # something that should not have been in the tree) and is what makes the failure fixable.
      # `|| true` is load-bearing: under `set -e` + `pipefail`, a grep that simply finds nothing
      # returns 1 and would abort the whole run — silently turning "clean" into "failed".
      offenders="$(grep -ioE -- "${finds[$i]}" "$target" 2>/dev/null \
                   | grep -ivE -- "${allows[$i]}" 2>/dev/null | sort -u | head -5 || true)"
      if [[ -n "$offenders" ]]; then
        report "${reasons[$i]} — ${label}: $(printf '%s' "$offenders" | tr '\n' ' ')"
      fi
    fi
  done
}

scan_stream() { scan_one "$1" "$2"; }

scan_tree() {
  local f rel
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # Skip binaries; a PNG will never carry a readable token and would produce noise.
    if ! grep -qI . "$f" 2>/dev/null; then continue; fi
    rel="${f#"$REPO_ROOT"/}"
    scan_one "$f" "$rel"
  done < <(list_files)
}

case "$mode" in
  stdin)         scan_stream "$haystack" "stdin" ;;
  history)       scan_stream "$haystack" "git history"; scan_tree ;;
  tree|paths)    scan_tree ;;
esac

if [[ $fail -ne 0 ]]; then
  echo
  echo "scrub: FAIL — forbidden source-estate tokens present. Do NOT push."
  exit 1
fi
echo "scrub: PASS — no forbidden source-estate tokens (mode: $mode)"
exit 0
