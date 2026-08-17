# Profile: identity

> **Example profile.** Replace with your identities.

| Binding | Value |
| ------- | ----- |
| DR pipeline identity | `ctso-dr-ghactions-id` — principal `00000000-0000-0000-0000-0000000000b1`, client `00000000-0000-0000-0000-0000000000b2` |
| Source pipeline identity (DR must never use) | `ctso-conn-ghactions-id` — principal `00000000-0000-0000-0000-0000000000a1` |
| Federated subject | `repo:<org>/<repo>:environment:dr` |
| CI environment | `dr` (required reviewers enabled — the server-side half of the apply gate) |

## The four isolation levels (ARCHITECTURE §1)

1. **Subscription.** The DR identity holds roles **only** in the DR subscription and **no role** on
   any source subscription. This is the hard guarantee: it does not depend on the agents behaving.
2. **State.** DR state lives only in the DR workspaces.
3. **Pipeline.** Agents trigger only the DR pipeline.
4. **Write path.** Builders write only under the DR output tree.

> **The `vnet` module trap.** If a shared VNet module defaults `network_contributor_principal_id` to
> the *source* identity, a DR root that omits the variable silently binds a source identity — and a
> token grep cannot see it, because the value lives in the module, not the root. That is why the lint
> has a **presence** check (`vnet-netcontrib`), not an absence check.
