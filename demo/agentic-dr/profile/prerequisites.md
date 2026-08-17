# Profile: out-of-band prerequisites

> **Example profile.** These gate every apply. **The agents emit this checklist; they never perform it.**

| # | Prerequisite | Owner | Why it cannot be automated here |
| - | ------------ | ----- | ------------------------------- |
| 1 | Resource providers registered in the DR subscription | Platform | Subscription-level operation, outside the DR estate's Terraform |
| 2 | One state workspace per DR root | Platform | Created out of band; the pipeline authenticates to it |
| 3 | The `dr` CI environment with OIDC secrets and required reviewers | Platform | This is the server-side half of the apply gate — self-provisioning it would defeat it |
| 4 | Quota and availability-zone confirmation in the DR region | Platform | A cold region has no quota history; a failover is the worst time to discover a limit |
| 5 | Bootstrap secrets replicated into the DR key vault | Platform | The build wires workloads to an already-populated vault; it never owns secret population |
| 6 | Data restore | **Customer** | The data plane is not ours (ARCHITECTURE §1) |

A new workspace usually needs its working directory set by hand before a remote plan can resolve
relative module paths. Confirm it before the first plan rather than during a failover.
