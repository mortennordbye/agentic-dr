# Profile: preflight

> **Example profile.** Replace the items; keep the distinction.

**This file holds decisions and judgements a build cannot make for itself. It does not hold status.**
That line matters:

- *"Does this messaging namespace want geo-pairing in DR?"* → **belongs here.** Nobody but a human
  can answer it, and recording the open question is the deliverable.
- *"Service X has not migrated yet."* → **does not belong here.** That is inventory, and discovery
  reads it from the repo. A hand-written status table goes stale silently, because nothing validates it.

The companion file is `prerequisites.md`: that one is out-of-band *provisioning*, this one is
*judgement*.

## Confirm before a build

- [ ] **Storage account failover posture.** For each replicated account, is customer-initiated
      failover acceptable, and to which region does its replication actually land?
- [ ] **Key vault replication coverage.** Which vaults are replicated to DR, and is every secret a
      workload needs to *boot* included?
- [ ] **Private DNS zone ownership.** Does the DR subscription get its own zones (bucket D), and who
      links them to the DR VNets?
- [ ] **Observability scope.** Sinks in, alerting leaves out — still true for this estate?
- [ ] **Any service whose standard pattern is known not to work in the DR region.** If one exists,
      it is a Mode 3 candidate; record it in `region-gaps.md` rather than discovering it under
      outage pressure.
