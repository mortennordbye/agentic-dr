# A fictional estate, for trying the engine without one

Everything here is invented: the customer, the regions, the address ranges, the GUIDs. It exists so
`/agentic-dr:dr-build dry-run` has something real to discover, read and transform, and so the
deterministic scripts can be run against something that looks like an estate rather than a fixture.

It is deliberately tiny, and deliberately shaped to exercise every part of a run.

## Copy it out before you run it

**Do not run a build in place.** A dry run *writes*: generated roots into the DR output tree, run
artifacts into the state directory, and a regenerated overlay into the GitOps target tree. Run it
here and those writes land in this repository's working tree, where they do not belong and where
they are one `git add -A` away from being committed into the plugin.

There is a second reason. Every run pins the commit of the repo it is invoked in, and builds the
whole estate from it. Run it here and it pins *the plugin's* commit, which is meaningless — the
pinned SHA is supposed to identify the state of an estate.

`try.sh` does the copying and the initial commit that discovery needs, then walks you through the
estate one step at a time:

```bash
bash demo/try.sh                 # → ~/agentic-dr-demo
bash demo/try.sh /some/where     # or wherever you like
bash demo/try.sh --yes           # set it up and print the commands, no prompts
```

It pauses before each step, which is the point when you are demonstrating this to a room: run the
lint, talk over the output, press enter for the next one. Each prompt takes enter to run, `s` to
skip, `q` to stop. The last step offers to launch Claude Code in the estate for a full build, and
defaults to no, because that one spawns agents and takes minutes.

With no terminal attached — piped, or under `--yes` — it sets the estate up, prints the commands and
exits, so it stays usable from a script.

It will not write into a directory that already has anything in it without asking, so a second run
cannot quietly discard a build you wanted to keep.

By hand it is the same four steps:

```bash
cp -R demo ~/agentic-dr-demo && cd ~/agentic-dr-demo
git init -q && git add -A && git commit -qm "fictional estate"
claude --plugin-dir /path/to/agentic-dr
/agentic-dr:dr-build dry-run
```

The initial commit matters: discovery pins the current commit, so an estate with no commits has
nothing to pin.

Generated Terraform lands in the DR output tree, run state in the state directory — both named by
`agentic-dr/profile/repo-map.md`, like everything else.

The deterministic half needs none of that, and runs in place safely because it only reads:

```bash
bash ../engine/lint.sh terraform/prod/aks agentic-dr/profile/lint-patterns.txt   # exits 1, correctly
```

## What is here, and why each piece exists

```
terraform/
├── modules/{vnet,law}          shared modules, read-only to the build
├── connectivity/vnet           produces the VNet + subnets          IN SCOPE
├── prod/law                    telemetry sink                        IN SCOPE
├── prod/aks                    consumes both, by name                IN SCOPE
├── prod/vm                     IaaS, not lifted and shifted          EXCLUDED
└── prod/kv                     pre-staged replication target         EXCLUDED
gitops/prod/components/         platform manifests, regenerated into the DR overlay
```

- **A real dependency chain.** `aks` reaches `connectivity/vnet` and `prod/law` through named `data`
  lookups: the cold-start problem in miniature, since neither resolves until its producer applies.
  The resolver should compute two tiers — `law` and `vnet` together, then `aks`.
- **Discovery and exclusion.** Five roots on disk, three in scope. The build plan's *will not be
  created* section should name `vm` and `kv`, with the reasons from `scope-rules.md`.
- **A value that must be deferred.** `prod/aks` pins a principal id in code. Nothing in the repo can
  derive its DR equivalent, so a Builder has to flag it rather than invent one, and `reconcile.mjs`
  has something real to agree or disagree with.
- **The vnet module trap.** `modules/vnet` defaults `network_contributor_principal_id` to the
  *source* identity. A DR root that omits the variable binds a source identity silently, which is
  why the lint checks for the DR identity's **presence**, not merely the absence of the source one.
- **DNS posture.** `connectivity/vnet` pins the source resolver, which the DR posture strips.
- **A value that must survive the transform.** The ingress overlay trusts an on-prem range that is
  *not* a source-estate token. A blind find/replace would rewrite it; the rewriter leaves it alone
  and flags it for a human to confirm. That single diff is the whole semantic-versus-lexical
  argument.

## Its profile is the example profile

`agentic-dr/profile/` is a copy of `profile.example/` from the plugin, unmodified. That is the
adoption path in miniature: the estate brings a profile, the plugin brings everything else.

## What it is not

Not a template to copy into a real repo, and not a test fixture — `fixtures/` holds those, and they
are what `tools/test.sh` asserts against. This is a demonstration estate, and nothing in the suite
depends on it.
