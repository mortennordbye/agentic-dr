## Why

<!-- The problem this solves. Link any related issue. -->

## What

<!-- What changed. -->

## Verification

<!-- Delete the rows that don't apply. -->

- [ ] `bash tools/test.sh` passes (includes both scrub-gate modes)
- [ ] `shellcheck engine/*.sh tools/*.sh` is clean
- [ ] `claude plugin validate . --strict` passes
- [ ] Estate-specific facts stayed in the profile, not the blueprint
- [ ] Docs only, no verification needed
