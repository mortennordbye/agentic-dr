# Profile: repo map

> **Example profile.** Replace with your layout.

| Binding | Value |
| ------- | ----- |
| Source roots (discovery scans these) | `terraform/prod/*`, `terraform/connectivity/*` |
| DR output roots | `dr/terraform/<component>/` |
| Framework directory | `agentic-dr/` (holds `profile/` and `state/`) |
| Name-collision rule | if a directory name occurs in **both** source tiers, disambiguate **both** by tier prefix → `prod-<name>` / `conn-<name>`. **Evaluated on the discovered folder set, before scope exclusions** — dropping one twin must not collapse the survivor onto the bare name, or the generator would target a protected pre-staged root. |
| Pre-staged / hand-authored DR roots (never regenerate) | list them here; each also needs an entry in `scope-rules.md` |
| Shared modules | `terraform/modules/` |
| Module path — source roots | `../../modules/<m>` |
| Module path — DR roots (one level deeper) | `../../../terraform/modules/<m>` |
| DR pipeline | `.github/workflows/dr-estate.yml` (manual dispatch; `plan_only` input) |
| Source pipelines (agents never invoke) | `prod-apply.yml`, `connectivity-apply.yml` |
| State backend workspace scheme | `tfc-prod-X` / `tfc-conn-X` → `tfc-dr-X`; one workspace per root |
| tfvars filename | `prod.tfvars` / `connectivity.tfvars` → `dr.tfvars` |
| Provider baseline | `azurerm ~> 4.0`, `required_version >= 1.12.2` |
