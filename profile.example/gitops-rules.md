# Profile: GitOps overlay rules

> **Example profile.** Prose twin of `gitops-substitutions.json`, which is the runtime source.
> Schema: `docs/gitops-substitutions-schema.md`.

The GitOps Builder regenerates the platform/core overlay with the **same** discover-and-subtract rule
as Terraform: every component under `source_dir` is regenerated unless pinned in `exclude`.

## Value classes

| Class | Meaning | What happens |
| ----- | ------- | ------------ |
| **AUTO** | An exact source→DR token pair | Substituted verbatim |
| **POST-APPLY** | Not derivable at codegen (an identity client id, a resource id that exists only after another root applies) | Replaced with a `__DR_POST_APPLY__<slug>` sentinel for the failover step to resolve |
| **DECIDE** | Needs a human call (an on-prem allowlist) | A sensible default is kept and flagged, or a `__DR_DECIDE__<slug>` sentinel is stamped |
| **KEEP** | Environment-independent | Untouched |
| **CUTOVER** | A hostname that changes only when traffic moves | **Deliberately untouched** — cutover is a customer-led routing step, not a build rewrite |

## POST-APPLY resolution sources

Every `post_apply` slug in `gitops-substitutions.json` resolves from a **Terraform output of the DR
root that produces it**. Name that output here: Phase 6 reads this table, and without it the sentinel
is resolved by guesswork against a value that did not exist at codegen time.

| Slug | Resolved from |
| ---- | ------------- |
| `aks-identity-client-id` | the `aks` root's `aks_identity_client_id` output |

## The completeness guard

After rewriting, a scan fails the build if any `forbidden_residual` token survived. **Never commit a
leaking overlay.** Before a failover commit, `grep -rl '__DR_' <target_dir>` must come back empty: an
unresolved sentinel would sync a manifest that fails to authenticate, or trusts the wrong sources.

## The boundary

Drawn at the **repo seam**, not a component list. Everything in the platform repo is generated; the
applications' own manifests live in the deployment repo and are never touched.

> The instructive mistake: excluding the ApplicationSet component as "application GitOps" is **wrong**.
> That component is the *pointer* that aims the GitOps controller at the deployment repo. Excluding it
> produces a DR cluster with every platform service healthy and no mechanism to pull a single
> application — quietly making the customer's deployment phase impossible. **Generate the pointer;
> they own what it points at.**
