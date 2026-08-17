# Global and non-regional services

A regional DR build must not blindly clone a resource that is not regional. Cloning a global
singleton produces a second authoritative thing; cloning an already-replicated one produces waste;
*failing* to clone subscription-scoped shared infrastructure produces a DR estate that cannot resolve
its own private endpoints.

This taxonomy is framework doctrine. The per-estate assignments live in `profile/global-services.md`.

## The decision rule

Ask in order, and stop at the first yes:

1. **Is it global / non-regional?** → bucket A.
2. **Does it already replicate _to the DR region_?** → bucket B.
3. **Is it regional but with a globally-unique name?** → bucket C.
4. **Is it subscription-scoped shared infrastructure?** → bucket D.

Otherwise it is an ordinary regional resource: regenerate it normally.

## The four buckets

| Bucket | Meaning | DR handling |
| ------ | ------- | ----------- |
| **A** | Global singleton. One authoritative instance serves every region. | **Never regenerate.** Repointed at cutover, or nothing to do. A second one is not a standby, it is a conflict. |
| **B** | Global namespace, already serving the DR region. | **Nothing to do.** |
| **C** | Regional, but the name is globally unique, so the DR copy cannot reuse it. | **Regenerate under a DR name.** If it must reference the *source* region (a replication target), it cannot be generator output — pre-stage it by hand and protect it in `scope-rules.md`. |
| **D** | Subscription-scoped shared infrastructure. | **Give the DR subscription its own copy.** |

## The trap in bucket B

**Storage geo-redundancy is usually not bucket B.** Geo-redundant storage replicates to the cloud
provider's *paired* region, which is generally **not** the DR region you chose. Verify where the
replica actually lands before classifying it as already-DR-ready. If it lands somewhere else, it is
bucket C and the DR estate needs its own account.

The same caution applies to any managed service that advertises "geo-replication" without letting you
choose the target.

## Why this is a bucket and not a list

Assignments are per-estate and go stale; the four questions do not. Record the *bucket* for a service
class and let discovery find the instances — see rule 1 in `profile-contract.md`.
