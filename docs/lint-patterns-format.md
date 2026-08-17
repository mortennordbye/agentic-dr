# `lint-patterns.txt` format

The invariant lint (`engine/lint.sh`, ARCHITECTURE §11) is committed as an **executable, not prose**.
This file documents its input format; the pattern set itself lives in your profile and is the single
place those tokens are written down.

## Why a grep and not a model

The lint is the cheap, mechanical half of correctness: *a deterministic check cannot hallucinate*.
Agents are used only where judgement is required. This one is not.

It is **necessary but not sufficient**. The real semantic gate is a human reading the `terraform
plan` (ARCHITECTURE §10). A green lint on a plan that wires the wrong region is still a failure.

## Format

Tab-separated. Blank lines and `#` comments ignored.

```
FORBIDDEN    <ere>        <reason>
REQUIRED     <ere>        <reason>
CONDITIONAL  <rulekey>    <arg>
```

- **FORBIDDEN** — any match fails the root. Source-estate leakage.
- **REQUIRED** — absence fails the root. A DR marker that must be present.
- **CONDITIONAL** — one of four rules implemented in `lint.sh`, applied only when its precondition holds.

Patterns are POSIX ERE and must work with **both BSD and GNU grep**, so no `\d`, no lookaround, no
non-greedy quantifiers.

## The four conditional rulekeys

| rulekey | Precondition | Checks |
| ------- | ------------ | ------ |
| `marker-if-regional` | the root references `azurerm` | the DR marker (`arg`) is present |
| `cidr-if-network` | the root declares `address_space` / `address_prefixes` | the DR tier CIDR (`arg`) is present |
| `env-tag-dr` | an `Environment` tag is assigned | every assignment carries the value `arg` |
| `vnet-netcontrib` | the root instantiates the shared `vnet` module | `network_contributor_principal_id` is set to `arg` |

Two of these encode failure modes worth understanding:

**`marker-if-regional` — markers only where they apply.** A root driving no cloud resources (a pure
Kubernetes/GitOps root) legitimately carries neither a DR name prefix nor a region token. Requiring
them there is a false positive. This is a **property of the root, re-evaluated every build**, not a
standing exemption for a named root: a root can stop qualifying the day someone adds a key vault
lookup to it.

**`vnet-netcontrib` — a presence check, not an absence check.** If the shared module defaults that
variable to the *source* identity, a root that simply omits it silently binds a source identity. A
token grep cannot see that, because the offending value lives in the module, not in the root. The
only check that catches it is asserting the variable is set.

## Comments are stripped first

`lint.sh` strips `/* */`, `//` and `#` comments before matching, so a provenance comment naming the
source estate does not trip the lint. It is a tripwire, not a parser: a `#` inside a string literal is
also stripped. That is a documented, accepted trade-off.

## Every pattern carries its reason

The reason column is not decoration. A bare regex tells the next engineer nothing about why a token
is forbidden, and this file is the only place the set exists — the prose rules file describes the
*shape* of the checks and deliberately does not restate the list.
