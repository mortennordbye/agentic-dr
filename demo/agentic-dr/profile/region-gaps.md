# Profile: region-parity gaps & adaptive-remediation log

The durable record of **Mode 3** (adaptive remediation) outcomes — region-parity gaps in the DR
region and the invariant-safe workaround chosen for each. Blueprint:
`../ARCHITECTURE.md` §3 (Mode 3 + hard invariants) and §16.10 (write-back).

**Why this file exists (not `transform-rules.md`).** A region-parity workaround is **point-in-time** —
it is correct only until the DR region gains the missing SKU/feature/zone. Folding it into the
mechanical `transform-rules.md` would carry a stale hack forever. Here it lives with an explicit
**revisit trigger**, so a fix is neither lost to one run nor frozen into the transform.

**How entries arrive.** An approved **and applied** Mode 3 remediation auto-drafts a PR adding an
entry below (the `dr-dynamic-remediator` agent drafts it; a human reviews — never auto-merged). The
agent only ever proposes options that preserve the four hard invariants (no public exposure of an
internal service, egress through the controlled path, no weaker isolation/encryption/TLS,
DR-estate-only); entries here inherit that guarantee.

## Entry format

```
### <component> — <short gap title>
- **Date / SHA:** <when applied> / <pinned main SHA of the build>
- **Gap:** <what is unavailable or behaves differently in the DR region>
- **Diagnosis:** <root cause, grounded in evidence>
- **Workaround applied:** <the surgical change or manual step>
- **Invariants preserved:** <one line attesting all four hold>
- **Revisit trigger:** <the condition under which this hack should be removed — e.g. "SKU X GA in
  the DR region", "zone 3 available for service Y">
```

## Gaps

_None recorded yet._ Mode 3 has not produced an applied remediation. Entries appear here as the DR
estate is exercised against the live DR region.
