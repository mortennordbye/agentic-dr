# Profile: network

> **Example profile.** Replace with your IP plan.

## CIDR transform

| Tier | Source | DR |
| ---- | ------ | -- |
| production | `10.100.0.0/16` | `10.200.0.0/16` |
| connectivity | `10.101.0.0/16` | `10.201.0.0/16` |
| hub | `10.102.0.0/16` | `10.202.0.0/16` |

**Apply semantically, never as a blind sweep.** A find/replace of `10.100.` → `10.200.` will also
rewrite a partner's fixed IP, a comment, and any unrelated address that happens to share the prefix.
Telling a region marker from a partner's allowlisted address requires understanding what the value is.

## DNS posture (cold region)

Until the DR resolver exists, DR roots use the platform's default DNS: strip the source resolver
(`10.101.1.4`) and the source firewall/P2S DNS (`10.102.0.132`), and omit any firewall-route or
firewall-private-IP wiring. Flip this once the DR firewall applies — a deliberate human step, not
generator output.

## Egress

Reserved DR egress public IPs are pre-staged in Phase 1 and bound to the DR firewall at failover.
**Partner allowlists are the reason these are pre-staged**: a partner needs the DR addresses on its
allowlist before the failover, not during it.
