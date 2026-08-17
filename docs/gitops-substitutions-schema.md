# `gitops-substitutions.json` schema

Runtime source for `engine/gitops-rewrite.mjs`. The prose twin lives in `profile/gitops-rules.md`.

## Top level

| Key | Type | Meaning |
| --- | ---- | ------- |
| `source_dir` | string | repo-relative source overlay (read-only to the build) |
| `target_dir` | string | repo-relative generated DR overlay (wiped and regenerated each run) |
| `exclude` | string[] | components discovery drops. **Keep it empty unless you mean it** — a stale entry is reported as a warning, never swallowed |
| `auto` | rule[] | `{from, to, why}` exact token substitutions |
| `post_apply` | rule[] | `{slug, kind, match, what, why}` values not derivable at codegen |
| `decide` | rule[] | `{slug, match, default_kept, what, why}` values needing a human call |
| `forbidden_residual` | rule[] | `{pattern, why}` the completeness guard |
| `post_apply_placeholder_prefix` | string | default `__DR_POST_APPLY__` |
| `decide_placeholder_prefix` | string | default `__DR_DECIDE__` |

`post_apply[].kind` is `token` (replace every occurrence of `match`) or `line-value` (replace the
scalar value of a `<key>: <value>` line, where `match` is the key).

## Rewrite order is load-bearing

The engine applies **POST-APPLY first, then DECIDE, then AUTO**, and that order is not arbitrary:

A POST-APPLY sentinel frequently *contains* a token the AUTO sweep would otherwise rewrite — a full
resource id carrying the source name prefix, for example. Stamping the sentinel first removes the
token before either the AUTO pass or the completeness scan can see it. Run AUTO first instead and you
get a half-rewritten resource id that looks plausible, passes the guard, and points nowhere.

Within AUTO, rules are applied **longest-first**, so a token that is a prefix of another cannot
partially shadow it.

## The completeness guard

After rewriting, every generated file is scanned for `forbidden_residual` patterns. Any hit exits 1.

**Cutover hostnames are deliberately not in that list.** They legitimately survive into the DR
overlay, because moving traffic is a customer-led routing step, not something the build rewrites.

## Sentinels must not reach a failover commit

`grep -rl '__DR_' <target_dir>` must be empty before committing a failover build. An unresolved
sentinel syncs a manifest that fails to authenticate, or trusts the wrong sources.
