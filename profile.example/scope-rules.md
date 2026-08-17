# Profile: scope rules (the exclusion guardrail)

> **Example profile.** Replace the entries; keep the doctrine.

Discovery enumerates every root under the source-root locations (`repo-map.md`) on the pinned commit.
This file is the **only hand-maintained scope artifact**: it lists what to **drop**, and why.
**Inclusions are discovered; only exclusions are pinned.** Security-reviewed — changing it changes
what DR builds.

The failure mode this ordering chooses is a *needless* DR root, visible in review, rather than a
*silently missing* one that nobody notices until DR day.

## Exclude by rule

- any root under `dev`, `test`, or `stage` — DR scope is production + connectivity only.
- anything not managed in this repo.

## Excluded roots

| Root | Why | Detail |
| ---- | --- | ------ |
| `prod/vm` | IaaS VMs are not lifted and shifted. | — |
| `prod/dr-sync-function` | The function that *implements* replication into DR. Cloning a push-to-DR sync into the DR estate is nonsensical and would leak source region/identity. | `global-services.md` |
| `prod/kv` | Its DR equivalent is a pre-staged vault (a replication target), which references the **source** region and so cannot be generator output. | `global-services.md` bucket C |
| `prod/front-door`, `connectivity/public-dns`, `connectivity/acr` | Global singletons, or already replicating to the DR region. | `global-services.md` buckets A, B |
| `alerts`, `action-group`, `grafana` | Alerting/dashboard **leaves** — pure consumers, nothing depends on them, so excluding them costs nothing at build time. | — |

## Protected DR roots — excluded from regeneration only

Hand-authored DR roots stay live and in-scope Terraform; an operator may still need to edit them by
hand during a failover. **The generator must never overwrite them.** List them in `repo-map.md`.

## Telemetry sinks are IN scope

The observability stack splits by dependency direction. The **sinks** (log analytics, metrics
workspaces) stay in scope because things depend on them: a compute root resolves them by name through
a `data` lookup, and **a `data` lookup at a non-existent workspace fails the plan in a cold region**.
Excluding them would force every workload Builder to strip monitoring wiring. An empty sink costs
approximately nothing, and telemetry is forward-flowing, so it stays consistent with the data-plane
boundary. Order them before their consumers.

The alerting **leaves** above are the opposite case: nothing depends on them, so dropping them is free.
