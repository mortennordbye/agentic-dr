# DR build plan

| Binding | Value |
| ------- | ----- |
| Pinned SHA | `04ad658add13abffb8305ee738b7fed932c08f07` |
| Customer / estate | Contoso — Storefront (prod + connectivity) |
| Source region → DR region | West Europe (`weu`) → North Europe (`neu`) |
| DR subscription | `00000000-0000-0000-0000-000000000003` (Disaster Recovery mgmt group) |
| DR strategy | Pilot Light, active-passive, cold standby |
| Source roots scanned | `terraform/prod/*`, `terraform/connectivity/*` |
| DR output tree | `dr/terraform/<component>/` |
| DR pipeline | `.github/workflows/dr-estate.yml` |
| Mode | _selected at the approval gate_ |

Discovery is **enumerate then subtract**: every root under the source-root locations on the pinned
commit, minus the `scope-rules.md` exclusions. Inclusions are discovered, only exclusions are pinned.

**Collision check.** Discovered folder set *before* exclusions: `prod/{aks, kv, law, vm}`,
`connectivity/{vnet}`. No directory name occurs in both tiers, so no tier-prefix disambiguation is
required and all components keep their flat names.

---

## 1. Will be created

| Component | Source root | DR root | DR name | Region | CIDR | Workspace |
| --------- | ----------- | ------- | ------- | ------ | ---- | --------- |
| `vnet` | `terraform/connectivity/vnet` | `dr/terraform/vnet` | `ctso-dr-conn-neu-vnet` (RG `ctso-dr-conn-neu-network-rg`) | northeurope | `10.201.0.0/16` — `snet-aks` `10.201.8.0/22`, `snet-endpoint` `10.201.12.0/24` | `tfc-dr-vnet` |
| `law` | `terraform/prod/law` | `dr/terraform/law` | `ctso-dr-prod-neu-law` (RG `ctso-dr-prod-neu-observability-rg`) | northeurope | — | `tfc-dr-law` |
| `aks` | `terraform/prod/aks` | `dr/terraform/aks` | `ctso-dr-prod-neu-aks` (RG `ctso-dr-prod-neu-aks-rg`) | northeurope | service `10.200.240.0/20`, dns svc ip `10.200.240.10` | `tfc-dr-aks` |

**Expected tiering** (confirmed by the Workflow's DAG, not by this file):

1. **Tier 1 — `vnet`, `law`** — no upstream dependencies; both are resolved *by name* by tier 2.
   `law` is a telemetry **sink**, in scope by `scope-rules.md`: a `data` lookup at a non-existent
   workspace fails the plan in a cold region.
2. **Tier 2 — `aks`** — depends on both tier-1 roots through `data` lookups
   (`azurerm_subnet.aks` → the DR VNet, `azurerm_log_analytics_workspace.this` → the DR LAW).

**Transform points worth naming up front** (`transform-rules.md`):

- `vnet`: `azurerm_virtual_network_dns_servers` (source resolver `10.101.1.4`) is **stripped** —
  DR uses platform default DNS until the DR resolver exists (`network.md`, rule 10). Flipping this
  back is a deliberate human step, never generator output.
- `vnet`: `network_contributor_principal_id` must be set **explicitly** to the DR identity
  `…-0000000000b1`. The shared module defaults it to the *source* pipeline identity `…-00000000a1`,
  which a token grep cannot see — hence the lint's `vnet-netcontrib` **presence** check.
- All roots: `dr.tfvars` carries the **DR** subscription `…-000000000003`. The source tfvars pin
  `…-000000000001` is forbidden by the lint.
- All roots: module path `../../modules/` → `../../../terraform/modules/` (DR roots sit one level deeper).
- `aks`: must expose an `aks_identity_client_id` output — Phase 6 reads it to resolve the GitOps
  `__DR_POST_APPLY__aks-identity-client-id` sentinel (`gitops-rules.md`).

## 2. Will NOT be created (and why)

| Root | Why |
| ---- | --- |
| `terraform/prod/vm` | `scope-rules.md` — IaaS VMs are not lifted and shifted. |
| `terraform/prod/kv` | `scope-rules.md` + `global-services.md` bucket C — the DR equivalent is a **pre-staged** vault (a replication target) that references the source region, so it cannot be generator output. Secret population is prerequisite #5. |

**Pinned exclusions with no matching root on this commit** (recorded so the gap is visible rather
than silent — no action, but `scope-rules.md` is carrying entries this estate does not have):
`prod/dr-sync-function`, `prod/front-door`, `connectivity/public-dns`, `connectivity/acr`,
`alerts`, `action-group`, `grafana`.

**Protected / pre-staged DR roots:** none pinned in `repo-map.md` for this estate. `dr/terraform/` is
empty on the pinned commit, so nothing hand-authored is at risk of being overwritten.

**Global / already-replicated services:** none in the discovered set beyond `prod/kv` above.

**GitOps overlay:** `gitops/dr/components` already exists from a prior run and **will be
regenerated** from `gitops/prod/components` (2 platform/core components: `ingress`,
`workload-identity`). It is not a Terraform root and does not appear in the table above.

## 3. Will need manual work

### Out-of-band prerequisites (`prerequisites.md`) — Platform team, gate every apply

1. Resource providers registered in the DR subscription.
2. One state workspace per DR root: `tfc-dr-vnet`, `tfc-dr-law`, `tfc-dr-aks` — each with its
   working directory set by hand, or a remote plan cannot resolve the relative module paths.
3. The `dr` CI environment with OIDC secrets **and required reviewers** (the server-side half of the
   apply gate).
4. Quota and availability-zone confirmation in North Europe (`Standard_D4s_v5` ×3 for the AKS system
   pool). A cold region has no quota history.
5. Bootstrap secrets replicated into the pre-staged DR key vault.
6. **Data restore — customer-owned** (ARCHITECTURE §1).

### Preflight judgements (`preflight.md`) — every item is currently unsettled

- [ ] Storage account failover posture — which region replication actually lands in.
- [ ] Key vault replication coverage — is every boot-critical secret included in the DR vault?
- [ ] Private DNS zone ownership (bucket D) — does the DR subscription get its own zones, and who
      links them to the DR VNets?
- [ ] Observability scope — sinks in (`law`), alerting leaves out. Still true?
- [ ] Any service whose standard pattern is known not to work in North Europe → Mode 3 candidate.

### Predicted blackboard residue (from a static scan — the Builders confirm)

| Item | Root | Why it cannot be generated |
| ---- | ---- | -------------------------- |
| `azurerm_role_assignment.cluster_admin` `principal_id = …-0000000000c7` | `aks` | A principal id pinned in code, not looked up. Nothing in the source derives its DR equivalent; a Builder must **defer** it, never invent one (rule 12). |
| DR DNS resolver | `vnet` | Source resolver stripped; DR runs on default DNS until a DR resolver exists. Re-wiring is a human step. |
| Cold-region `data` lookups | `aks` | The DR subnet and DR LAW resolve only **after** tier 1 applies. A cold plan-only run is partial by design (§6.3). |
| `__DR_POST_APPLY__aks-identity-client-id` | GitOps overlay | Resolves in Phase 6 from the `aks` root's `aks_identity_client_id` output. |
| `__DR_DECIDE__gateway-trusted-ips` (`10.150.0.0/16`) | GitOps overlay | On-prem allowlist on the internal gateway — prod default kept, needs human confirmation. |

### Region-parity gaps

`region-gaps.md` records none. Mode 3 has not produced an applied remediation for this estate.

### Customer-owned, outside this build

Data restore (P3), application deployment incl. re-annotating workloads with the new DR identity
client ids (P4), and cutover/validation (P5) — `process.md`.
