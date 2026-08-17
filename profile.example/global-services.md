# Profile: global & non-regional services

> **Example profile.** The four buckets are framework doctrine (`docs/global-services.md`); the
> assignments below are estate-specific. Replace the assignments, keep the buckets.

A regional DR build must not blindly clone a resource that is not regional. Route each one:

**The decision rule.** Ask in order: (1) is it global//non-regional? (2) does it already replicate
**to the DR region**? (3) is its name globally unique? (4) is it subscription-scoped shared infra?

| Bucket | Meaning | DR handling | Example assignments |
| ------ | ------- | ----------- | ------------------- |
| **A** | Global singleton | **Never regenerate.** Repointed at cutover, or nothing to do. | Front Door, public DNS zones |
| **B** | Global namespace, already DR-ready | **Nothing to do** — it already serves the DR region. | Geo-replicated container registry |
| **C** | Regional, but globally-unique name | **Regenerate under a DR name**, or pre-stage by hand when it must reference the source region. | Key vaults, storage accounts |
| **D** | Subscription-scoped shared infra | **Give the DR subscription its own copy.** | `privatelink.*` private DNS zones, the network hub |

> **Geo-redundant storage is not bucket B.** Storage geo-redundancy targets the cloud provider's
> *paired* region, which is generally **not** your chosen DR region. Check the pairing before
> assuming a replicated resource is already DR-ready; if it lands elsewhere, it is bucket C.
