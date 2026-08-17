# GitOps overlay build report

Generated `gitops/dr/components` from `gitops/prod/components` — 2 platform/core component(s) discovered; 0 data-plane component(s) excluded.

Status: PASS — no prod infra token survived

## AUTO substitutions applied

- `ingress/configmap.yaml`: `ctso-prod-weu-` → `ctso-dr-prod-neu-` (×2)
- `ingress/configmap.yaml`: `westeurope` → `northeurope` (×1)
- `ingress/values.yaml`: `ctso-prod-weu-` → `ctso-dr-prod-neu-` (×1)
- `ingress/values.yaml`: `westeurope` → `northeurope` (×1)
- `ingress/values.yaml`: `10.100.` → `10.200.` (×1)
- `workload-identity/values.yaml`: `ctso-prod-weu-` → `ctso-dr-prod-neu-` (×2)
- `workload-identity/values.yaml`: `westeurope` → `northeurope` (×1)

## POST-APPLY — resolve after the DR estate applies (sentinel left in place)

- `workload-identity/values.yaml`: **the DR workload identity client id** — DR identities are new, with new client ids that do not exist until the identity root applies

## DECIDE — human confirmation required

- `ingress/values.yaml`: **on-prem source ranges trusted by the internal gateway** — on-prem reaches DR over the same links, so keeping the source list is usually right — but confirm it (prod default kept, confirm)
