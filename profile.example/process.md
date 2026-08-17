# Profile: process

> **Example profile.** This file is where the customer-owned DR process lives. Replace it, or point
> at the document that owns it — do not restate that document here.

The build is **one phase** of a larger process the customer owns:

| Phase | Owner | What |
| ----- | ----- | ---- |
| P1 Declare disaster | Customer | The decision to fail over. Nothing here runs before it. |
| P2 Build regional core infrastructure | **Platform team (this build)** | `/agentic-dr:failover` |
| P3 Restore data | Customer | Databases, storage, messaging. Generated empty by design. |
| P4 Deploy applications | Customer | Including re-annotating workloads with the new DR identity client ids the build reports. |
| P5 Cutover & validate | Customer | Traffic routing. Never an agent action. |

**Trigger:** a failover build starts on an explicit request from the customer's incident lead,
never on a hunch and never automatically.

**Link the authoritative runbook here.**
