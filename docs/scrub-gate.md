# The scrub gate

`tools/scrub-check.sh` is this repository's release gate. It exists because the framework was
extracted from a private production estate into a public repo, and a leaked identifier cannot be
taken back: GitHub keeps unreachable objects retrievable through the API for a period, so a
force-push does not reliably retract a blob that was pushed once.

It is the same technique the framework applies to generated Terraform (`engine/lint.sh`), turned
around and pointed at the framework itself. That is not a cute symmetry — it is the same argument. A
deterministic check cannot hallucinate, and this is not a judgement call.

## The design problem, and the answer

A gate that greps for a specific identifier has to *contain* that identifier. Commit it to a public
repo and you have published the exact string you were trying to suppress.

So the public gate checks **shapes, not tokens**. It finds every GUID-, IPv4- and hostname-shaped
string in the tree and fails on any that is not one of this repo's documented example values. It
names nothing, so it leaks nothing.

That is also strictly stronger for the thing that matters. A token list only catches identifiers
somebody remembered to add; a shape check catches every real-looking identifier, including ones from
an estate nobody has thought about yet.

## What it cannot do

A shape check cannot catch a bare word: a company name, a person, an internal system, a project
codename. Nothing about `acme` looks different from `contoso`.

**Keep a private supplementary list outside this repository** and point the checker at it:

```bash
SCRUB_PATTERNS=/path/to/private-patterns.txt bash tools/scrub-check.sh
```

That list belongs in your own private repo, not here. Same reasoning as above.

## Modes

```bash
bash tools/scrub-check.sh              # working tree
bash tools/scrub-check.sh --history    # every commit patch, plus the tree
bash tools/scrub-check.sh --stdin      # a stream, e.g. git log -p | ...
bash tools/scrub-check.sh path/to/file # specific paths
```

`--history` matters because rewriting a file does not remove what an earlier commit recorded. Run it
before any push.

## Format

Tab-separated; `#` comments and blank lines ignored. Matching is case-insensitive.

```
FORBIDDEN  <ere>                    <reason>
EXTRACT    <find-ere>  <allow-ere>  <reason>
```

`EXTRACT` is the shape check: pull every match of `find-ere`, discard the ones matching `allow-ere`,
and report what remains. Reporting the offending *value* is safe by definition — it is something that
should not have been in the tree — and it is what makes the failure fixable.

## Two deliberate accommodations

**SVG path data is stripped before scanning.** A run of path coordinates like `8.205 11.385.6.113`
matches the IPv4 shape constantly. `d="..."` attributes are removed from `.html`/`.svg` files first,
the same move `lint.sh` makes when it strips HCL comments. Coordinates are not prose and cannot carry
an identifier, so nothing detectable is lost.

**Hostnames require three labels.** `a.b.tld` is the shape an internal FQDN leaks in. Two-label
domains are not matched, because there is no shape that separates a JavaScript property access
(`det.io`) or a spec URL (`w3.org`) from a real corporate domain. Bare company domains are the
private list's job.

## If it fails

Do not push. Fix the file, then re-run both the tree and history modes. If the token is already in a
local commit, rewrite the local history before pushing rather than adding a fixup commit on top.
