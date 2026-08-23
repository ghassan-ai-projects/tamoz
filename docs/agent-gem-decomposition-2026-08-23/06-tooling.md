# 06 — Static-analysis tools for this method

Short answer: **most of the six signals in [05](05-systematic-method.md) can be
run by tools you already have** — enola, RuboCop, and Reek — and the one gap
(dependency fitness) has no strong off-the-shelf Ruby answer, so it stays a small
custom script. The grep commands in [05] are the _portable_ form; the tools below
are the _accurate, enforceable_ form.

## What's already in this repo

- **enola** (MCP, AST-accurate architecture graph) — cycles, layers, hotspots,
  god-class, exported-surface, `impact_analysis`, `diff_snapshot`.
- **RuboCop 1.87** + `rubocop-ast`, `-performance`, `-minitest`.
- **Reek 6.5** — used heavily (134 files carry `:reek:` annotations).
- No Packwerk, no Sorbet.

## Tool → signal map

| Signal (from [05]) | Best tool | Have it? | Notes |
|---|---|---|---|
| 1. De-facto public API | **enola** `exported-surface` + `impact_analysis` | ✅ | AST-accurate cross-gem consumer graph — the real version of the grep. |
| 2. Inversions / cycles | **enola** `cycles`; **custom RuboCop cop** as the CI gate | ✅ | See below — a cop fixes the comment/string false positives grep produced. |
| 3. Single-consumer heavy dep | (small custom script) | ⚠️ gap | Ruby has no solid "unused/underused dependency" tool. |
| 4. Self-declared seams | none (comment mining) | — | Heuristic only; keep the grep. |
| 5. Domain gravity | **Reek** `FeatureEnvy` / `UtilityFunction`; **enola** hotspots | ✅ | Reek is method-level within a file; enola is cross-module. |
| 6. Test-location mismatch | none | — | Heuristic; corroboration only. |

## The high-value additions

### 1. A custom RuboCop cop for inversions (Signal 2) — do this

The grep in Signal 2 matched **comments and string literals**, which is exactly
why every "inversion" this pass found was a false alarm. A RuboCop cop works on
the **AST**, so it only sees real constant references — no comments, no strings.
The rule is small and stable: _a lower gem may not reference a higher gem's
namespace._

```ruby
# .rubocop/cops/tamoz/no_upward_reference.rb  (sketch)
module RuboCop::Cop::Tamoz
  class NoUpwardReference < Base
    MSG = "%<lower>s must not reference %<higher>s (layer inversion)."
    # config maps each gem path prefix to the namespaces it may NOT name
    def on_const(node)
      # resolve node's file -> owning gem; if the fully-qualified const
      # belongs to a higher gem, add_offense(node)
    end
  end
end
```

Wire it per gem via `.rubocop.yml` `require:` and an `Include:`/`Exclude:` scoped
to each gem's `lib/`. This is the single best guardrail: it turns "no foundation
gem names `Tamoz::Agent` in code" into a build failure, and it never fires on a
comment. `rubocop-ast` (already installed) is all it needs.

### 2. Turn on / watch the Reek smells that match Signal 5

Reek already runs. Two of its smells are the code-level analog of "domain
gravity":

- **`FeatureEnvy`** — a method that talks more to another object than to its own.
  That is misplaced behaviour at method granularity — the same shape as a
  misplaced _file_ at gem granularity.
- **`UtilityFunction`** — a method that depends on nothing in its own class; a
  hint the code wants to live in a shared/lower layer (e.g. the `Plan` helpers →
  `tamoz-core`).

Check `.reek.yml` isn't globally disabling these; use them as leads for Signal 5,
then confirm cross-gem with enola.

### 3. Consider Packwerk — the industry-standard boundary enforcer

[Packwerk](https://github.com/Shopify/packwerk) (Shopify) is the Ruby tool built
for _exactly_ this problem: declare each package's allowed **dependencies** and
its **public API** (a `public/` folder), and it fails the build on
privacy violations and dependency-direction violations. `graphwerk` visualizes
the result.

- **What it adds over gems:** you already get hard boundaries at `require` time
  from the gem split, but gems do **not** enforce _public vs private_ (any gem
  can reach any constant of a dependency). Packwerk adds that privacy layer and a
  declared-dependency check — the enforced form of Signals 1 and 2.
- **The trade-off:** it is a second boundary system layered on top of gems, with
  its own `package.yml` files to maintain. For a repo already committed to
  gem-per-boundary, the lighter path is **enola in CI + the custom cop above**,
  which covers the same two signals without a new framework. Adopt Packwerk only
  if you want enforced public-API privacy _within_ a gem before it is split.

## The honest gaps

- **Signal 3 (dependency fitness).** Ruby lacks a reliable equivalent of
  JavaScript's `depcheck`. `bundler-audit`/Dependabot are about CVEs and version
  bumps, not usage. The practical answer is a ~15-line script: parse each
  `*.gemspec`'s declared deps, grep each dep's top-level constant across the
  gem's `lib/`, and flag any dep used by ≤N files (this is how `ruby_llm` → 1
  file surfaced). Keep it in CI.
- **Signals 4 and 6** are comment-mining and test-topology heuristics with no
  tool; they stay manual leads, used only to corroborate 1/2/5.
- **Sorbet** would give a fully resolved constant graph you could write custom
  layer analyses against, but adopting it just for this is disproportionate —
  enola already provides the resolved graph via MCP.

## Recommended setup (least effort, most coverage)

1. **enola `set_baseline` + `diff_snapshot` in review** — Signals 1, 2, 5,
   automatically, AST-accurate.
2. **Custom RuboCop `NoUpwardReference` cop** — Signal 2 as a hard CI gate,
   false-positive-free.
3. **Reek `FeatureEnvy`/`UtilityFunction`** — Signal 5 leads (already running).
4. **A tiny gemspec-vs-usage script** — Signal 3, the one real gap.

That covers five of the six signals with tools already in the repo, plus one
small cop and one small script.
