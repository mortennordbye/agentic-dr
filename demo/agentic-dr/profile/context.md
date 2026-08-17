# Profile: context

> **Example profile.** Every value here belongs to a fictional estate. Replace the whole table.

| Binding | Value |
| ------- | ----- |
| Customer | Contoso |
| Platform / CSP team | Contoso Platform Engineering |
| DR subscription | *Contoso DR* — `00000000-0000-0000-0000-000000000003`, under the `Disaster Recovery` management group |
| Protected business flow(s) | Contoso Storefront (web & mobile) |
| Source region | West Europe — tokens `weu` / `westeurope` |
| DR region | North Europe — tokens `neu` / `northeurope` |
| DR strategy | Pilot Light (active-passive); cold standby |
| In-scope estate | production (`ctso-prod-*`) + core/connectivity (`ctso-conn-*`) only |

**Point at your own source of truth.** Where an authoritative document already records these values
(a network design doc, a subscription inventory), link it here and inline only the token the engine
resolves. A copied GUID is exactly the dynamic data that drifts.
