# Profile: transform rules

> **Example profile.** Replace the values; the dimensions are fixed by the blueprint (ARCHITECTURE §5).

The authoritative rule set a Component Builder applies to turn a source root into its DR equivalent.
**Apply semantically, never as blind find/replace.**

| # | Dimension | Rule |
| - | --------- | ---- |
| 1 | Name prefix | `ctso-prod-*` → `ctso-dr-prod-neu-*`; `ctso-conn-*` → `ctso-dr-conn-neu-*` |
| 2 | Region tokens | `weu`→`neu`; `West Europe`→`North Europe`; `westeurope`→`northeurope` |
| 3 | CIDR | see `network.md` |
| 4 | Workspace | `tfc-prod-X` / `tfc-conn-X` → `tfc-dr-X` |
| 5 | Module path | `../../modules/` → `../../../terraform/modules/` |
| 6 | tfvars filename | `prod.tfvars` / `connectivity.tfvars` → `dr.tfvars` |
| 7 | Subscription | leave `var.subscription_id` (OIDC, runtime) — **never hardcode** |
| 8 | Tags | `Environment` → `"DR"`; cost/ownership tags unchanged |
| 9 | Net-contributor identity | **must be set explicitly** to the DR identity — see the trap in `identity.md` |
| 10 | DNS | strip source resolver and firewall IPs; default DNS until the DR resolver exists |
| 11 | Module versions | read each module's `variables.tf` live; never copy a stale proof-of-concept |
| 12 | Cross-component refs | rewrite `data`-lookup target names to DR; **refuse to copy a hardcoded source value → blackboard it** |
| 13 | Fully-qualified resource ids | rewrite **both halves** — the subscription id *and* every resource-group/resource name inside the id. An id whose target only exists after another DR root applies is not derivable at codegen → blackboard it. |

## Invariant lint

The lint is committed as an **executable**, not prose: `engine/lint.sh` reads its token set from
**`lint-patterns.txt` — the single source, and the only place the patterns are written down.** Each
pattern there carries its own reason, so this file describes the *shape* of the check rather than
restating the list. A mirrored copy here would be one more thing to keep in sync, and the file it
mirrored would win anyway.

`lint.sh` strips HCL comments before matching, so a provenance comment naming the source estate does
not trip it.
