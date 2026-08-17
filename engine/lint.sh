#!/usr/bin/env bash
#
# engine/lint.sh — invariant lint for generated DR Terraform roots (ARCHITECTURE §11, §16.14).
#
# Deterministic, NO LLM. The single committed source of the leakage tripwire: it runs on every
# generated DR root, before any plan, and fails the component on source-estate leakage or a missing
# DR marker. It is necessary-but-not-sufficient — human review of the `terraform plan` is the real
# semantic gate (§10).
#
# Customer-agnostic: every token lives in the patterns file (default profile/lint-patterns.txt), so
# this script holds only the generic check mechanisms. A new customer edits the patterns file, not
# this script.
#
# Usage:   lint.sh <dr-root-dir> [patterns-file]
# Exit:    0 = pass, 1 = lint violation(s), 2 = usage / environment error.
#
set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" ]]; then
  echo "usage: lint.sh <dr-root-dir> [patterns-file]" >&2
  exit 2
fi
# The engine ships separately from the estate it lints, so the patterns file is resolved against the
# consuming repo's `<AGENTIC_DIR>/profile` convention, never against this script's own directory.
AGENTIC_DIR="${AGENTIC_DR_DIR:-agentic-dr}"
PATTERNS="${2:-$AGENTIC_DIR/profile/lint-patterns.txt}"

[[ -d "$ROOT" ]]     || { echo "lint: not a directory: $ROOT" >&2; exit 2; }
[[ -f "$PATTERNS" ]] || { echo "lint: patterns file not found: $PATTERNS" >&2; exit 2; }

# --- Stage a comment-stripped copy of the root's Terraform sources -------------------------------
# Strips /* block */ (possibly multi-line) then # and // line comments. A tripwire, not a parser:
# a '#'/'//' inside a string literal is also stripped (vanishingly rare in this estate; accepted).
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

shopt -s nullglob
sources=("$ROOT"/*.tf "$ROOT"/*.tfvars)
shopt -u nullglob
if [[ ${#sources[@]} -eq 0 ]]; then
  echo "lint: no .tf/.tfvars files in $ROOT" >&2
  exit 2
fi
for f in "${sources[@]}"; do
  perl -0pe 's{/\*.*?\*/}{}gs' "$f" | sed -E 's://.*$::; s:#.*$::' > "$tmp/$(basename "$f")"
done

# --- Run the checks ------------------------------------------------------------------------------
fail=0
violation() { printf '  \xE2\x9C\x97 %s\n' "$1"; fail=1; }

while IFS=$'\t' read -r kind a b _rest; do
  # skip comments / blanks
  [[ -z "${kind:-}" || "${kind:0:1}" == "#" ]] && continue

  case "$kind" in
    FORBIDDEN)
      if hits="$(grep -rnE -- "$a" "$tmp" 2>/dev/null)"; then
        # report the offending file:line (strip the temp dir prefix)
        first="$(printf '%s\n' "$hits" | head -n1 | sed "s|$tmp/||")"
        violation "FORBIDDEN [$b]: /$a/ — e.g. $first"
      fi
      ;;
    REQUIRED)
      grep -rqE -- "$a" "$tmp" 2>/dev/null \
        || violation "REQUIRED [$b]: /$a/ not found in any source file"
      ;;
    CONDITIONAL)
      rulekey="$a"; arg="$b"
      case "$rulekey" in
        cidr-if-network)
          if grep -rqE 'address_space|address_prefixes' "$tmp" 2>/dev/null; then
            grep -rqE -- "$arg" "$tmp" 2>/dev/null \
              || violation "CONDITIONAL [cidr-if-network]: root declares network space but no DR tier CIDR ($arg) is present"
          fi
          ;;
        env-tag-dr)
          # any present `Environment` tag assignment must carry value "$arg"
          if bad="$(grep -rnE 'Environment[[:space:]]*[:=]' "$tmp" 2>/dev/null | grep -vE "\"$arg\"")"; then
            first="$(printf '%s\n' "$bad" | head -n1 | sed "s|$tmp/||")"
            violation "CONDITIONAL [env-tag-dr]: an Environment tag is set to a value other than \"$arg\" — $first"
          fi
          ;;
        vnet-netcontrib)
          if grep -rqE 'modules/vnet' "$tmp" 2>/dev/null; then
            grep -rqF -- "$arg" "$tmp" 2>/dev/null \
              || violation "CONDITIONAL [vnet-netcontrib]: root uses the vnet module but does not set network_contributor_principal_id to the DR identity ($arg)"
          fi
          ;;
        marker-if-regional)
          # Only roots that provision regional Azure resources must carry the DR marker. A
          # region-agnostic root (no azurerm provider/resource/data — e.g. a pure GitOps/Kubernetes
          # root) legitimately has neither the DR name prefix nor the DR region token; requiring
          # them there is a false positive. The FORBIDDEN source-token checks still apply to it.
          if grep -rqE 'azurerm' "$tmp" 2>/dev/null; then
            grep -rqE -- "$arg" "$tmp" 2>/dev/null \
              || violation "CONDITIONAL [marker-if-regional]: regional root (references azurerm) is missing required DR marker /$arg/"
          fi
          ;;
        *)
          echo "lint: unknown CONDITIONAL rulekey '$rulekey' in $PATTERNS" >&2
          exit 2
          ;;
      esac
      ;;
    *)
      echo "lint: unknown pattern kind '$kind' in $PATTERNS" >&2
      exit 2
      ;;
  esac
done < "$PATTERNS"

if [[ $fail -ne 0 ]]; then
  echo "lint: FAIL — $ROOT"
  exit 1
fi
echo "lint: PASS — $ROOT"
exit 0
