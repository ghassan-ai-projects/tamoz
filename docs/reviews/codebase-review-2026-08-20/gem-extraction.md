# Gem-extraction candidates — tamoz monorepo

Scope: read-only architecture review of the 13 gems under `gems/` (branch
`sonnet-refactoring`), looking for code that could/should move to a new gem, move to a
better-fitting existing gem, or (the reverse) gems so tightly coupled that keeping them
separate buys nothing. No code, config, or files other than this report were touched.

## Methodology

1. Read all 13 `gems/*/*.gemspec` files in full to get the **real** current dependency
   graph (below), rather than assuming it from names or from `docs/CODING_STANDARD.md`
   prose.
2. Used `mcp__enola__query_insights` (`god-class`, `hotspots`, `exported-surface`,
   `cycles`, `complexity-outliers` — `dependency-depth` and `layers` produced no
   insights in this snapshot) and `mcp__enola__explore` at depth 2 on every gem's
   top-level module and on each candidate subdirectory for symbol counts, fan-in/fan-out,
   and reverse-dependents.
3. **Every cross-gem edge enola's directory-level aggregation surfaced that looked
   architecturally suspicious was verified against source with `grep` before being
   treated as evidence.** Three looked alarming at first read (`tamoz-core/circuit` →
   `tamoz-agent/healing`; `tamoz-agent/profile` → `tamoz-stream`; `tamoz-tools/skills` →
   `tamoz-stream`/`tamoz-graph`) and all three turned out to be artifacts of enola
   attributing `test/` and `test/support/` cross-references to the directory-level graph,
   not production code. None held up under `grep`; they are not reported as findings.
   This is called out because it shapes how much weight the rest of this report puts on
   enola's raw edge lists versus grep-verified coupling.
4. Read `docs/CODING_STANDARD.md` §6.1 ("The architecture is executable"), §6.2 ("Does
   this belong here?"), and §10 ("Gems and dependencies"), plus the plan docs for the
   three adapter-shaped gems already in the repo (`docs/COMMS_TELEGRAM_PLAN.md`,
   `docs/OBSERVABILITY_PLAN.md`, `docs/P17_WEBSEARCH_PLAN.md`) to distinguish
   deliberate architectural boundaries from accidental ones.
5. `docs/DEPENDENCY_REVIEW.md` and `docs/dependency-review.json` are third-party
   gem license/provenance review — out of scope for this task, confirmed by a glance
   and not used.
6. All 13 gems currently carry the identical version string `0.1.0.alpha.1`
   (`gems/*/lib/tamoz/*/version.rb`) and every gemspec pins its sibling dependencies to
   `"= #{OwnGem::VERSION}"` — i.e. the whole monorepo releases in lockstep today. This
   matters for the recommendations below: splitting a 14th gem out of an existing one
   does not introduce an independent release cadence to coordinate; it is purely a
   packaging/require-path change.

### The real dependency graph (from the 13 gemspecs)

```
tamoz-core            (zeitwerk only — the foundation)
├── tamoz-tools
├── tamoz-graph        (+ zeitwerk)
├── tamoz-comms
│    └── tamoz-telegram
├── tamoz-observability
│    └── tamoz-otel
├── tamoz-scheduler
├── tamoz-stream       (+ grpc, google-protobuf)
└── tamoz-mcp          (+ mcp ~>1.1)

tamoz-sqlite   → tamoz-graph, tamoz-scheduler, tamoz-stream   (+ sqlite3)
tamoz-agent    → tamoz-tools, tamoz-graph, tamoz-sqlite, tamoz-comms, tamoz-observability   (+ ruby_llm)
tamoz-evals    → tamoz-core, tamoz-agent, tamoz-sqlite, tamoz-mcp
```

Notable, already-known-intentional: **`tamoz-agent` does not depend on `tamoz-mcp`** —
confirmed both by the gemspec and by the duck-typed contract documented in
`gems/tamoz-agent/lib/tamoz/agent/mcp_capability_source.rb` ("tamoz-agent holds no hard
dependency on tamoz-mcp: everything here is duck-typed"). `tamoz-evals` is the only gem
that depends on both `tamoz-agent` and `tamoz-mcp`, and per CODING_STANDARD.md §6.1 it
deliberately "stays outside the production runtime graph" (`docs/QUALITY_PROGRAM.md`
§Q7) — it exists to drive both halves of the stack for conformance testing, which is
why it is allowed a dependency shape nothing else has.

## Executive summary

One well-evidenced **High** finding: `gems/tamoz-mcp/lib/tamoz/mcp/websearch.rb` plus
`.../websearch/` (832 lines, 4 files, ~24% of `tamoz-mcp`) is a self-contained,
load-path-isolated HTTP-egress adapter that uses almost none of the rest of `tamoz-mcp`
and is consumed only by an operator-side script and the evals harness — not by
`tamoz-mcp`'s own core require path. It is the same shape of decision this codebase has
already made twice (`tamoz-comms`/`tamoz-telegram`, `tamoz-observability`/`tamoz-otel`),
and CODING_STANDARD.md §6.2 states the rule directly: an HTTP-capable integration
"is an adapter behind an existing contract, or it is its own gem." Recommend extracting
it to a `tamoz-mcp-websearch` gem.

Two **Medium** findings, both inside `tamoz-evals`: it reimplements a simpler,
non-byte-compatible version of `tamoz-core`'s canonical-JSON/digest and deep-freeze
utilities despite already requiring `tamoz-core` directly (this is a duplication issue
more than an extraction one — flagged briefly per the task's instructions, since a
separate pass covers duplication in depth); and its `harness/` subdirectory holds 84%
of the gem's lines (10,449 of 12,431) behind a real, one-directional internal seam,
which is worth knowing about but not urgent to act on.

No **reverse-merge** candidates survived scrutiny. The two gem pairs connected by a
single dependency edge with no other consumer of the downstream gem — `tamoz-otel` →
`tamoz-observability` and `tamoz-telegram` → `tamoz-comms` — both turned out to be
deliberate isolation boundaries, documented in their own plan docs, that exist
specifically so a minimal boot of the upstream gem never loads an HTTP client. That is
the exact pattern the `tamoz-mcp-websearch` recommendation below asks to extend to
`tamoz-mcp`, so instead of a merge candidate it reads as supporting precedent for the
High finding.

Several other duplication-shaped leads were investigated and ruled out because the
duplication is explicitly deliberate, not the "no shared gem exists" kind the task
asks about: `Tamoz::Agent::Profile::EgressValidator` (agent-side egress validation)
and `Tamoz::Mcp::Websearch::EgressPolicy` (mcp-side egress validation) validate
overlapping shapes on purpose, named in `docs/P17_WEBSEARCH_PLAN.md` as "duplication
only across the gem boundary... per the P8-E precedent" — the same
`tamoz-agent`-does-not-depend-on-`tamoz-mcp` boundary the task pre-ruled out. Likewise
`Tamoz::Agent::SkillSet` and `Tamoz::Tools::Skills::Catalog` looked like they might
overlap by name; they are complementary (wire-digest verification vs. filesystem
compilation), not duplicates. And `gems/tamoz-sqlite`'s `comms_store.rb` /
`comms_decision_store.rb` implement `Tamoz::Comms::CommsStore` structurally without
requiring `tamoz-comms` at all — its own comment names this "dependency rule 9," the
same store/contract split already used for `tamoz-scheduler`'s `ScheduleStore` (whose
gemspec says outright: "the SQLite store lives in tamoz-sqlite").

## High

### 1. `tamoz-mcp/websearch` — extract to a `tamoz-mcp-websearch` gem

**The code in question:**
- `gems/tamoz-mcp/lib/tamoz/mcp/websearch.rb` (81 lines) — credential-hygiene helpers
  and the egress-budget mapping.
- `gems/tamoz-mcp/lib/tamoz/mcp/websearch/egress_policy.rb` (295 lines) — validates an
  `egress:` declaration (allowlisted hosts, schemes, byte/timeout budgets, circuit
  config) and classifies addresses for SSRF-safety (private-range/IP-literal checks).
- `gems/tamoz-mcp/lib/tamoz/mcp/websearch/egress_client.rb` (292 lines) — the actual
  `net/http` dialer: per-hop resolve → classify → pin → connect, with redirect-hop
  limits and response-size bounding.
- `gems/tamoz-mcp/lib/tamoz/mcp/websearch/egress_circuit.rb` (164 lines) — a
  websearch-scoped circuit breaker with typed reset evidence.

832 lines / 4 files total — 24% of `tamoz-mcp`'s 3,407 lines / 17 files. The other 13
files (2,575 lines: `errors.rb`, `canonical_json.rb`, `shared_constants.rb`,
`bounded_text.rb`, `server_config.rb`, `circuit_supervision.rb`, `supervisor.rb`,
`http_supervisor.rb`, `catalog.rb`, `invocation.rb`, `elicitation.rb`, `version.rb`,
`mcp.rb`) are the gem's actual stated mission per its gemspec: "Immutable server
admission, catalog, invocation, and supervision over the official MCP SDK."

**Current coupling — this is the load-bearing evidence:**

- `gems/tamoz-mcp/lib/tamoz/mcp.rb`, the gem's core require path, requires all 13
  non-websearch files and **not** `websearch`. `websearch.rb`'s own top comment says
  why: "NOT required by `tamoz/mcp.rb`: the dialer and HTTP stack live here, and only
  the operator-side server (`script/websearch_adapter`) and the test suite load this
  file — Tamoz's own core load path never pulls in a socket-capable dependency." This
  is an existing, deliberate isolation the packaging does not yet reflect.
- Reverse-dependents confirmed via `enola explore` + grep, not assumed: only
  `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb` (via an explicit
  `require "tamoz/mcp/websearch"` at its P17 case-18 test scenario, lines ~1966–2510)
  and `script/websearch_adapter` (the operator-side MCP server executable, 191 lines)
  touch `Tamoz::Mcp::Websearch` at all. Nothing else in `tamoz-mcp`, `tamoz-agent`, or
  anywhere else in the tree references it.
- Forward coupling to the rest of `tamoz-mcp` is narrow and enumerable — checked by
  grep across all 4 files, not inferred: `Tamoz::Mcp::ValidationError` (subclassed
  once, in `egress_policy.rb`), `Tamoz::Mcp::CircuitPolicyError` (raised in
  `egress_circuit.rb`), `Tamoz::Mcp::ServerConfig::Budgets` (built in `websearch.rb`),
  and `Tamoz::Mcp::CanonicalJSON.dump` (used once, in `egress_circuit.rb`'s
  `conditions_digest`). It does **not** touch `Supervisor`, `CircuitSupervision`,
  `Catalog`, `Invocation`, `HttpSupervisor`, or `Elicitation` — the actual "governed
  MCP client/host" machinery that is the rest of the gem's reason to exist. It also
  never references the third-party `mcp` gem directly (that only happens in
  `script/websearch_adapter`, which builds an `MCP::Server` — the SDK's *server-side*
  API — directly; `tamoz-mcp`'s own `Supervisor`/`Catalog`/`Invocation` machinery is
  *client-side*, for governing servers Tamoz calls out to, so websearch and the rest
  of `tamoz-mcp` are not just loosely coupled, they play opposite roles in the MCP
  protocol).
- `gems/tamoz-evals/lib/tamoz/evals/harness/agent_smoke_corpus.rb` also uses
  `Tamoz::Mcp::Catalog.compile` and `Tamoz::Mcp::Supervisor.new` elsewhere in the same
  file (confirmed by grep) — i.e. evals already needs both halves of `tamoz-mcp`
  regardless of this split, so extraction would not shrink evals' footprint, only make
  the two roles addressable separately.

**Recommended action: extract to a new `tamoz-mcp-websearch` gem**, depending on
`tamoz-mcp` (for the 2 error base classes, `ServerConfig::Budgets`, and
`CanonicalJSON`) and transitively `tamoz-core`. This is not a borderline call: the
authors have already drawn this exact boundary at the file level and documented the
reason (keep socket-capable code out of the core load path); making it a gemspec
boundary turns a comment-enforced convention into something Bundler enforces. It also
matches a pattern already used twice: `tamoz-observability`/`tamoz-otel` split for the
identical reason (`docs/OBSERVABILITY_PLAN.md`: "`tamoz-otel` with only
`tamoz-observability`; a minimal boot loads no HTTP client and no exporter") and
`tamoz-comms`/`tamoz-telegram` for the analogous transport-adapter reason. §6.2 of
CODING_STANDARD.md states the general rule this instantiates: "An integration with one
named external service living inside a core gem... is an adapter behind an existing
contract, or it is its own gem."

**What would need to change** (described, not implemented): a new
`gems/tamoz-mcp-websearch/` directory with its own gemspec (mirroring
`gems/tamoz-otel/tamoz-otel.gemspec`'s shape — single dependency on the parent gem,
pinned to the same lockstep version) and `lib/tamoz/mcp/websearch/version.rb`; move the
4 files and update `gems/tamoz-mcp-websearch.gemspec`'s `require_relative` chain;
update the two real consumers (`script/websearch_adapter`'s `$LOAD_PATH` line and
`require`, and `agent_smoke_corpus.rb`'s `require "tamoz/mcp/websearch"`) plus
`gems/tamoz-evals/tamoz-evals.gemspec` and `Gemfile` to add the new gem; add
`tamoz-mcp-websearch` to `test/dependency_isolation_test.rb`'s clean-process checks
(CODING_STANDARD.md §6.1: "a new boundary is added to the test in the same commit that
creates it"). One naming wrinkle worth deciding explicitly rather than defaulting: the
two existing adapter gems (`tamoz-otel`, `tamoz-telegram`) both use a **sibling**
top-level namespace (`Tamoz::OTel`, `Tamoz::Telegram`), not one nested under the parent
gem's module, even though they depend on the parent. Following that convention exactly
would mean renaming `Tamoz::Mcp::Websearch` → `Tamoz::Websearch`, which ripples through
all the call sites named above; keeping the existing `Tamoz::Mcp::Websearch` nesting
while still shipping it as a separate gem is equally valid Ruby and much less
disruptive. Either is defensible; it should be a deliberate choice, not an accident of
which files got moved first.

## Medium

### 1. `tamoz-evals/harness/` holds 84% of the gem's code behind a real internal seam

**The code in question:** `gems/tamoz-evals/lib/tamoz/evals/harness/` — 26 files,
10,449 lines (agent memory/smoke corpora, heuristic evaluation, 11 `sqlite_*` scenario
files driving fault-injected SQLite conformance runs, `subprocess_runner.rb`). The rest
of the gem — `artifact.rb`, `schema.rb`, `verifier.rb`, `case.rb`, `result.rb`,
`evidence.rb`, `canonical_json.rb`, `deep_freeze.rb`, `duplicate_key_detector.rb`,
`benchmark/` (5 files), `cli.rb` — is 18 files, 1,982 lines: the canonical-artifact
format, verification, and release-gate layer the gemspec actually names ("Canonical
artifacts, conformance suites, comparison, and release gates").

**Current coupling:** confirmed one-directional by grep, not assumed from directory
size. `gems/tamoz-evals/lib/tamoz/evals/cli.rb` (the `tamoz-eval` executable's entry
point) references `Harness::` directly — so harness is live, first-class code the
gem's own CLI drives, not a dead corner. `harness/*.rb` in turn uses the "core" layer's
`CanonicalJSON`/`DeepFreeze` (bare-referenced, same namespace) to seal its own
evidence, but none of harness/'s 26 files are required by, or referenced from,
`artifact.rb`/`schema.rb`/`verifier.rb`/`case.rb`/`result.rb`/`evidence.rb` — the
format/verification layer does not reach into the scenario-runner layer. Nothing
outside `tamoz-evals` touches `harness/` (grepped `tamoz-agent`, `tamoz-mcp`,
`tamoz-sqlite` — zero hits), consistent with evals' documented stay-outside-production
charter.

**Recommended action: leave alone, but the seam is real if this gem's growth ever
forces the question.** This is presented as Medium rather than High because none of
the usual forcing functions apply today: `tamoz-evals` is already isolated from the
production dependency graph (so a split doesn't reduce anyone's transitive footprint),
nothing outside the gem depends on it at all (so a split doesn't let a smaller consumer
avoid pulling in the scenario runners), and the monorepo's lockstep versioning means
there's no independent-release benefit either. The internal boundary between "artifact
format + verification" and "scenario execution engines" is clean enough that a future
`tamoz-evals` (format/verification) + `tamoz-evals-harness` (scenario runners,
depending on the former) split would be mechanical if the gem's size ever becomes a
maintenance problem on its own — but there's no evidence that day has arrived.

### 2. `tamoz-evals` reimplements `tamoz-core`'s canonical-JSON and deep-freeze — brief note

Flagged briefly per the task's framing (a separate pass covers duplication in depth);
from the gem-extraction angle the useful question is whether this points at a missing
dependency or an under-promoted core contract, and the evidence points clearly at the
latter.

`gems/tamoz-evals/lib/tamoz/evals/canonical_json.rb` (85 lines,
`Tamoz::Evals::CanonicalJSON`) and `gems/tamoz-evals/lib/tamoz/evals/deep_freeze.rb`
(20 lines, `Tamoz::Evals::DeepFreeze`) duplicate the *purpose* of
`gems/tamoz-core/lib/tamoz/core/jcs.rb`'s `Tamoz::Core::JCS` (516 lines — a full RFC
8785 canonicalizer with a hand-rolled strict JSON scanner, ES-number serialization,
and UTF-16-code-unit key sort) and `Tamoz::Core.deep_freeze`
(`gems/tamoz-core/lib/tamoz/core.rb:145-158`). They are not byte-compatible with each
other: Evals sorts keys with Ruby's default `String#<=>` via `.keys.sort`, where
`Core::JCS` explicitly sorts by `key.encode("UTF-16BE").b` to match RFC 8785; Evals
serializes through stdlib `JSON.generate` after a lightweight normalize step, where
Core hand-emits bytes to control float/integer representation exactly. `Evals::
DeepFreeze.call` also skips the `dup` that `Core.deep_freeze` does before freezing
strings, which is a narrower behavioral gap worth a look independent of the
extraction question.

**This is not a missing-dependency gap**: `gems/tamoz-evals/lib/tamoz/evals.rb:9`
already has `require "tamoz/core"` — `Tamoz::Core::JCS` and `Tamoz::Core.deep_freeze`
are already loaded in every process that loads `tamoz-evals`, and ~24 files under
`harness/` alone call `Evals::CanonicalJSON`/`Evals::DeepFreeze` today. So the fix this
angle suggests is not "add a dependency," it's "route evals' ~24 call sites at
`Tamoz::Core::JCS`/`Tamoz::Core.deep_freeze` instead," possibly after promoting a
thin `content_digest`/`file_digest`-shaped convenience method into `Core::JCS` to match
the call shape evals actually uses, so `Tamoz::Core::JCS` becomes unambiguously the one
shared canonical-JSON surface instead of the model competing with a parallel evals-only
reimplementation.

## Low

### 1. `tamoz-sqlite`'s 67 files are a flat namespace with several large naming clusters, not individually investigated

`gems/tamoz-sqlite/lib/tamoz/sqlite/` has no subdirectories at all — every file sits
directly under one namespace, so the task's first dimension ("a cohesive
sub-directory... with few internal dependents") does not apply structurally the way it
does for gems with real subdirectories. There are, however, sizeable naming clusters
that were not individually traced for internal-vs-external fan-in given the size of
this review: `effect_*` (12 files, 1,474 lines — the effect journal/ledger/lifecycle),
`checkpoint_*` (7 files, 1,384 lines), `request_inbox_*` (7 files), `thread_*` (3
files, deletion/tombstone/purge), plus `comms_*` (5 files — already checked, see
above; intentional structural-contract split, not a finding) and `schedule_store.rb`
(the scheduler's equivalent). All of these appear to share `wire.rb`,
`transaction.rb`, and `connection_pool.rb` as common low-level primitives, which is
consistent with genuine intra-gem cohesion rather than accidental bundling, but that
impression was not verified with the same grep-every-edge rigor applied to the High and
Medium findings above. Worth a closer pass if `tamoz-sqlite`'s size (13,350 lines, the
largest gem after `tamoz-agent`) becomes a standalone concern; not evidenced strongly
enough here to recommend action.

## Coverage

- **tamoz-agent** — partially reviewed. Read the full file listing (128 files); used
  `enola explore` on all four candidate subdirectories (`healing/`, `improvement/`,
  `memory/`, `profile/`) and grep-verified every cross-gem edge enola surfaced for
  them (all were false signals — see Methodology). Concluded these four, despite their
  size, are genuinely part of one cohesive "deliberative agent runtime" domain (the
  gemspec's own "plan, review, execute, verify, remember, and improve" names memory
  and improvement explicitly) and cross-reference each other's digest domains too
  tightly for a clean split. Also sized the CLI cluster (`cli.rb` + 11 `cli_*.rb`
  files, 3,926 lines, ~15% of the gem) and judged it non-extractable porcelain over the
  runtime rather than a library concern — not deep-dived further. Did not individually
  review `session_*.rb` (12 files), `worker*.rb`, or the remaining ~40 flat files
  beyond the god-class/hotspot signals already surfaced by enola.
- **tamoz-core** — fully reviewed. `capability/` (7 symbols, 2 dependents, tiny) and
  `circuit/` (79 symbols, real cross-gem fan-in from `tamoz-agent`, `tamoz-sqlite`,
  `tamoz-tools` — correctly a shared core contract) both checked; no findings.
- **tamoz-comms** — reviewed at gemspec/file-listing level (22 files, flat namespace,
  no subdirectories). Not individually explored per-file given no structural signal
  invited it; its `tamoz-telegram` split was checked as the reverse-merge dimension
  (ruled out, deliberate).
- **tamoz-evals** — fully reviewed. Both Medium findings above; also traced
  `canonical_json.rb`/`deep_freeze.rb` call sites and the `harness/` vs. rest-of-gem
  dependency direction by grep, not just line counts.
- **tamoz-graph** — reviewed at gemspec/file-listing level; the one subdirectory
  (`memory_checkpointer/`, 354 lines total) is trivially small, no finding.
- **tamoz-mcp** — fully reviewed; the High finding above.
- **tamoz-observability** — reviewed at gemspec/file-listing level (18 files, flat).
  Its `tamoz-otel` split checked as the reverse-merge dimension (ruled out,
  deliberate, documented in `docs/OBSERVABILITY_PLAN.md`).
- **tamoz-otel** — reviewed as half of the observability/otel pair; no finding.
- **tamoz-scheduler** — reviewed at gemspec/file-listing level (8 files, small,
  cohesive). Its SQLite-store split checked under dimension 2 (ruled out — its own
  gemspec names the split as deliberate: "the SQLite store lives in tamoz-sqlite").
- **tamoz-sqlite** — partially reviewed. Confirmed its three-way dependency split
  (7 files touch `Tamoz::Graph`, 1 touches `Tamoz::Scheduler`, 2 touch
  `Tamoz::Stream`) is proportionate, not a hidden near-100%-fan-out case; confirmed
  `comms_store.rb`/`comms_decision_store.rb` are an intentional structural-contract
  implementation of `Tamoz::Comms::CommsStore` with no gemspec dependency on
  `tamoz-comms` at all (the file's own comment names this "dependency rule 9"). Did
  not individually trace the internal naming clusters — see Low finding above.
- **tamoz-stream** — reviewed at gemspec/file-listing level, plus the one insight
  enola raised for it. The `exported-surface` insight ("gems/tamoz-stream/contracts
  exports 35 of 35 symbols") was chased down and explained, not left as a loose end:
  those symbols are protobuf message types generated from
  `gems/tamoz-stream/contracts/runtime-v1.proto` into
  `lib/tamoz/stream/gen/runtime-v1_pb.rb` — a cross-language wire contract shared with
  the sibling Go repo, not hand-written Ruby API surface, so a "narrow the public API"
  fix does not apply and this is not a gem-extraction finding.
- **tamoz-telegram** — reviewed as half of the comms/telegram pair (already a working
  example of the adapter-gem pattern cited in the High finding); no finding.
- **tamoz-tools** — reviewed. `skills/` subdirectory explored (101 symbols, 12
  dependents across `tamoz-agent`, `tamoz-evals/harness`, and — per grep-verified,
  real edges — nothing outside the gem beyond those); it is explicitly named in the
  gemspec description ("the skills descriptor surface") and legitimately belongs
  where it is. Confirmed `Tamoz::Agent::SkillSet` (wire-digest verification) and
  `Tamoz::Tools::Skills::Catalog` (filesystem compiler) are complementary, not
  duplicative, by reading both.

No gem was entirely unreached; the partial-review notes above are the honest limit of
depth given the size of the codebase (78K lines / 441 files) relative to this pass.
