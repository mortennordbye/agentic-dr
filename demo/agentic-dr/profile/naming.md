# Profile: naming

> **Example profile.** Replace with your estate's scheme.

Scheme: `<org>-<env>-<tier>-[<region>]-<workload>-<type>`

| Source | DR |
| ------ | -- |
| `ctso-prod-*` | `ctso-dr-prod-neu-*` |
| `ctso-conn-*` | `ctso-dr-conn-neu-*` |

Tags every DR resource carries: `Environment = "DR"` (the invariant lint enforces this), plus the
estate's own cost/ownership tags carried through unchanged (`CostCenter`, `Department`).

Global-namespace resources (storage accounts, container registries, key vaults) must additionally
satisfy their own uniqueness rules — see `global-services.md` bucket C.
