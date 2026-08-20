# Misuse of existing code — tamoz monorepo audit

Scope: `gems/*/lib` across all 13 gems (~78K lines, 441 files), branch `sonnet-refactoring`. This is
a **read-only** audit; no code was changed to produce it.

## Methodology

Reference inventory was built by reading `gems/tamoz-core/lib/tamoz/core.rb`,
`gems/tamoz-core/lib/tamoz/error.rb`, `gems/tamoz-core/lib/tamoz/core/jcs.rb`,
`gems/tamoz-core/lib/tamoz/safe_text.rb`, `gems/tamoz-core/lib/tamoz/immutable.rb`, and
`gems/tamoz-core/lib/tamoz/circuit.rb` in full. The reachable shared surface is:

- **`Tamoz::Core`** — `.canonical` (pure key-sorting normalizer), `.jcs`/`.jcs_json` (RFC 8785 bytes),
  `.parse_json_strict`, `.digest`/`.digest_bytes`/`.normalize_digest`/`.verify_digest` (domain-separated
  SHA-256, `"sha256:"` + 64 hex), `.valid_digest?` (validates that shape via
  `Tamoz::Core::JCS::DIGEST_PATTERN`), `.secret_shaped?`/`SECRET_VALUE_PATTERNS`, `.deep_freeze`
  (JSON-shaped deep freezer), `.normalize_reconsideration`. `Tamoz::Core.jcs` is doc-commented as "the
  digest rule for anything that is hashed, persisted, compared, or replayed (CONTRACTS.md §2-3)" —
  i.e. explicitly claimed as universal, not opt-in.
- **`Tamoz::Error`** — the `Metadata` contract (`category`, `retryable?`, `user_visible?`,
  `safe_message`), `CATEGORY`/`RETRYABLE`/`USER_VISIBLE`/`SAFE_MESSAGE` class constants,
  `Error.disclosable_message(value, fallback:)` (UTF-8-force, scrub, strip control chars, truncate to
  512 bytes, freeze), `DisclosableMessage`/`FatalRuntimeFailure` opt-in markers.
- **`Tamoz::SafeText.normalize`** and **`Tamoz::Immutable.copy`** — both `private_constant`, but
  reachable from any file lexically nested under `module Tamoz` (Ruby's `private_constant` blocks only
  explicit `Tamoz::X` qualification, not bare in-scope lookup). `SafeText.normalize` is a raise-based
  string validator (bytesize/UTF-8/control-chars/pattern → frozen string or raise). `Immutable.copy` is
  a raise-based deep-copy-with-limits (`DEFAULT_MAX_DEPTH = 64`, `DEFAULT_MAX_COLLECTION_ITEMS =
  100_000`, `DEFAULT_MAX_STRING_BYTES = 1_048_576`), rejects `Tamoz::Secret`, rejects cycles.
- **`Tamoz::Circuit`** — "the ONE circuit engine" (its own header comment) for DR-2 durable circuits;
  `Tamoz::SQLite::CircuitStore` is its documented persistence adapter.
- Gem-root error classes (`Tamoz::Agent::Error`, `Tamoz::Comms::CommsError`, `Tamoz::Mcp::Error`,
  `Tamoz::Observability::ObservabilityError`, `Tamoz::Scheduler::SchedulerError`,
  `Tamoz::Stream::StreamError`, `Tamoz::Evals::Error`, `Tamoz::SQLite::Error`,
  `Tamoz::Core::ToolError`) were traced individually.

Method: grepped every other gem for the shapes named in the brief — `Digest::`, `force_encoding`,
`valid_encoding?`, control-character regexes, `sha256:`/hex-64 patterns, error-class definitions and
their parents, `SafeText`/`Immutable`/`Core.canonical` call sites, `.send(:`/`instance_variable_get`
cross-boundary reaching — then read the suspicious hits in full to check whether a real contract
difference justifies the divergence, per the calibration in the brief (the `deep_freeze` precedent).
`docs/public-api.json` was checked to confirm which per-gem surfaces are meant to be public. Every
gemspec's `dependencies:` array was read directly to confirm which gems can actually reach
`tamoz-core` (all 13 can, directly or transitively — `tamoz-core` has zero gem dependencies of its
own and every other gem depends on it directly except `tamoz-telegram`, which reaches it transitively
through `tamoz-comms`, and `tamoz-sqlite`, which reaches it transitively through `tamoz-graph` /
`tamoz-scheduler` / `tamoz-stream`).

`mcp__enola__explore` was used on `Tamoz::Core` to sanity-check reverse-dependents; the existing
snapshot's `generate_snapshot`/`set_baseline`/`diff_snapshot` were deliberately not invoked per
instructions.

## Executive summary

The dominant pattern in this audit is **not** a single missed call site — it's that the single most
foundational shared contract in the codebase, "canonicalize a JSON-shaped value deterministically
(optionally domain-separated-digest it)," has **no single owner in practice** despite having an
explicit, doc-commented owner in principle (`Tamoz::Core::JCS` / `Tamoz::Core.jcs` /
`Tamoz::Core.digest` / `Tamoz::Core.canonical`). At least six other independent implementations of
"walk a Hash/Array, sort/stringify/bound it, maybe hash it" exist across six gems, each invented
separately, each diverging from `Tamoz::Core`'s version in a different, mostly undocumented way. One
of the six (`tamoz-mcp`'s `CanonicalJSON`) documents *why* it can't reuse a sibling gem's copy, but
never asks why it doesn't build on `tamoz-core`'s, which it already depends on directly. This is
High severity because it is pervasive (touches digest/persistence correctness guarantees in at least
5 of the 13 gems) and because the fragmentation is largely invisible — nothing fails today, but a
change to the "one true" canonicalization rule in `tamoz-core` would silently fail to propagate to
five other places that believe they implement the same rule.

Below that, the same "reinvented instead of reused" shape repeats at smaller scale: a text-sanitizing
helper duplicated with different truncation/scrub semantics, four-plus independent control-character
regexes with genuinely different character coverage, and a couple of clean, low-risk stragglers from
digest-pattern and secret-pattern consolidation work already done elsewhere this session.

Positive findings worth stating up front, since they were explicitly asked to be checked and are easy
to get wrong by omission: the `secret_shaped?`/`SECRET_VALUE_PATTERNS` consolidation has **no
stragglers** — every one of the ~10 call sites across `tamoz-agent` and `tamoz-mcp` correctly
delegates to `Tamoz::Core`. Every gem-root error class in every gem (`tamoz-agent`, `tamoz-comms`,
`tamoz-evals`, `tamoz-mcp`, `tamoz-observability`, `tamoz-scheduler`, `tamoz-stream`, `tamoz-sqlite`,
tool errors in `tamoz-core`/`tamoz-tools`) inherits `Tamoz::Error` and carries the `Metadata` contract
— the one exception (`Tamoz::Mcp::OutputLimitError`, see Low) is deliberate and documented. The
`assert_depth!`/`MAX_ARGUMENT_DEPTH` duplication between `tamoz-agent` and `tamoz-mcp` was confirmed
to match the known non-issue exactly (no gem edge exists between them) and is not flagged below.

## High

- **`gems/tamoz-evals/lib/tamoz/evals/canonical_json.rb`, `gems/tamoz-mcp/lib/tamoz/mcp/canonical_json.rb`, `gems/tamoz-comms/lib/tamoz/comms/canonical.rb`, `gems/tamoz-observability/lib/tamoz/observability/content_policy.rb:119-150`, `gems/tamoz-observability/lib/tamoz/observability/correlation.rb:27-29`, `gems/tamoz-sqlite/lib/tamoz/sqlite/boundary_registry.rb:400-409`** — six independent reimplementations of "canonicalize a JSON-shaped value" outside `Tamoz::Core::JCS`/`Tamoz::Core.canonical`, each used as the digest mechanism for its own gem's durable/wire identity.
  - The existing correct alternative: `Tamoz::Core.jcs`/`Tamoz::Core.canonical`/`Tamoz::Core.digest`/`Tamoz::Core.valid_digest?` (`gems/tamoz-core/lib/tamoz/core.rb:69-118`, backed by `gems/tamoz-core/lib/tamoz/core/jcs.rb`), doc-commented as the digest rule for "anything that is hashed, persisted, compared, or replayed."
  - What each does and whether it's a safe drop-in:
    - `Tamoz::Evals::CanonicalJSON` (evals, used in 17 files across the harness) — sorts keys, NFC-normalizes strings, **rejects `Float` entirely** ("floating-point values are forbidden; use scaled integers"), depth limit 100. This is a **real, documented contract difference** (JCS supports floats with exact ECMAScript serialization for Go interop; evals deliberately refuses them). Not a safe drop-in as-is.
    - `Tamoz::Mcp::CanonicalJSON` (mcp, used in 5 files: `invocation.rb`, `elicitation.rb`, `catalog.rb`, `websearch/egress_circuit.rb`, `supervisor.rb` — i.e. the digest mechanism for the whole gem's catalog/invocation/circuit identity) — its own comment says: *"Mirrors the tamoz-evals canonicalizer's rules (duplicated deliberately: tamoz-mcp may not depend on tamoz-evals)."* That's accurate (`tamoz-evals` depends on `tamoz-mcp`, so the reverse would cycle) — but it's a non-sequitur as a reason not to use `Tamoz::Core::JCS`, which `tamoz-mcp` already depends on directly (`tamoz-mcp.gemspec` lists `tamoz-core`). It also differs from JCS in a way that matters: `dump` finishes with plain `JSON.generate` (`canonical_json.rb:16`), so float serialization follows Ruby's `JSON` gem, not JCS's ECMAScript-exact `format_number` — the two would **not** produce byte-identical output for the same float in all cases. Not a safe drop-in without resolving the float-serialization gap, but the NFC-normalization + sorted-keys shape is otherwise redundant with `Tamoz::Core.canonical` + `Tamoz::Core.jcs`.
    - `Tamoz::Comms::Canonical` (comms, used in 8 files across `tamoz-comms` and `tamoz-agent`: `surface_descriptor.rb`, `decision_record.rb`, `interrupt_digest.rb`, `approval_prompt.rb`, `pairing_challenge.rb`, `delivery.rb`, `agent/delivery_drainer.rb`, `agent/comms_gateway.rb`) — not even JSON-shaped output (a custom `{k:v,k:v}` / `[v,v]` wire format), and natively accepts `Time` (converts to ISO-8601 internally) where JCS requires the caller to pre-stringify. **Real contract difference** (ergonomic, but real) — not a mechanical swap.
    - `Tamoz::Observability::ContentPolicy#canonicalize` (`content_policy.rb:119-150`, feeding the `@digest` computed at line 26) — sorts Hash keys, recurses Array, and: rejects `Tamoz::Secret` with `SensitiveValueError`, enforces a depth limit of `64`, enforces a string-byte limit of `1_048_576`. Those three numbers/behaviors are not approximately similar to `Tamoz::Immutable.copy` (`gems/tamoz-core/lib/tamoz/immutable.rb`) — they are **identical**: `DEFAULT_MAX_DEPTH = 64` (immutable.rb:5), `DEFAULT_MAX_STRING_BYTES = 1_048_576` (immutable.rb:7), and the same `SensitiveValueError` class for the same reason ("Tamoz::Secret is not permitted"). `ContentPolicy` is lexically nested `module Tamoz; module Observability; class ContentPolicy` (content_policy.rb:6-8), exactly the nesting that already lets `tamoz-graph`, `tamoz-agent`, and `tamoz-sqlite` reach `Immutable`/`SafeText` by bare name despite `private_constant`. This strongly reads as "modeled on `Immutable.copy`'s contract, then hand-copied rather than called." Likely a safe-or-near-safe drop-in for `Immutable.copy` itself (which already does depth+size+Secret validation) composed with `Tamoz::Core.jcs` for the sort-and-serialize step — worth verifying the `MAX_CONTENT_ENTRIES = 64` item-count check (which `Immutable.copy` also has, at `100_000`, a different number) before swapping.
    - `Tamoz::SQLite::BoundaryRegistry#canonicalize` (`boundary_registry.rb:400-409`, feeding `canonical_json`/`digest` at lines 395-310) — structurally identical to `Tamoz::Core.canonical` (sort Hash keys, recurse Array, passthrough scalar) minus the `String(key)` coercion `Core.canonical` does. No documented reason for the divergence. This one looks like a safe drop-in for `Tamoz::Core.canonical(value)` feeding `Tamoz::SQLite::Wire.digest` — `Wire.digest` (`wire.rb:64-71`) intentionally takes pre-serialized bytes with its own versioned domain separator (`"#{domain}\0v#{DIGEST_VERSION}\0"`), which is a real and separate concern from JCS's domain rule, so only the local `canonicalize` (not `Wire.digest`) is the redundant part.
    - `Tamoz::Observability::Correlation.canonical` (`correlation.rb:27-29`) — a narrow one-off (`"[#{values.map { |v| JSON.generate(v.to_s) }.join(',')}]"`) used only to build `trace_id`/`span_id` from 2-3 scalar strings. Named `canonical`, inviting confusion with `Tamoz::Core.canonical`. This one is almost certainly a safe drop-in: `Tamoz::Core.digest("tamoz.trace.v1\n", [thread_id, execution_id]).delete_prefix("sha256:")[0, TRACE_ID_BYTES * 2]` reproduces the same inputs→digest shape, and that exact `Tamoz::Core.digest(...).delete_prefix('sha256:')[...]` idiom is already used correctly elsewhere in the codebase (`gems/tamoz-agent/lib/tamoz/agent/healing/effect_identity.rb:49`, `gems/tamoz-agent/lib/tamoz/agent/memory/admission.rb:438`).
  - Suggested action: this is not "make everyone call `Tamoz::Core.jcs`" — two of the six (`Evals::CanonicalJSON`'s float rejection, `Comms::Canonical`'s non-JSON wire format + `Time` support) have real, if undocumented-as-such, reasons to diverge and should stay separate, but *say so* in a comment the way `Tamoz::Mcp::CanonicalJSON` already half-does. The other three (`Observability::ContentPolicy`, `Observability::Correlation`, `SQLite::BoundaryRegistry`) look like they could be rebuilt on `Tamoz::Core.canonical`/`Tamoz::Immutable.copy`/`Tamoz::Core.digest` with no behavior change, and should be tried first. Either way, the ambiguity itself — six teams independently answering "how do I canonicalize a value for a digest" — is the thing worth resolving at an architectural level, not each site in isolation.

- **`gems/tamoz-mcp/lib/tamoz/mcp/websearch/egress_circuit.rb:34`** — `COMMAND_DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/` is a byte-for-byte duplicate of `Tamoz::Core::JCS::DIGEST_PATTERN` (`gems/tamoz-core/lib/tamoz/core/jcs.rb:43`), hand-rolled instead of calling `Tamoz::Core.valid_digest?`.
  - The existing correct alternative: `Tamoz::Core.valid_digest?(value)` (`core.rb:116-118`).
  - Used only as a pure boolean check at line 153: `digest.is_a?(String) && COMMAND_DIGEST_PATTERN.match?(digest)`. `Tamoz::Core.valid_digest?(digest)` alone (which internally checks `is_a?(String)` too) is functionally identical — **safe, zero-risk drop-in**, no contract difference at all.
  - This is exactly the class of straggler the brief flagged as already-fixed elsewhere this session ("digest-pattern validation consolidated to reuse `Tamoz::Core.digest`") — this one file in `tamoz-mcp/websearch/` appears to have been missed by that pass. Suggested action: replace the local constant and its one use with `Tamoz::Core.valid_digest?`.

## Medium

- **`gems/tamoz-mcp/lib/tamoz/mcp/bounded_text.rb:14-22`** — `BoundedText.bound` reimplements the same five-step "sanitize untrusted text" algorithm as `Tamoz::Error.disclosable_message` (`gems/tamoz-core/lib/tamoz/error.rb:64-72`): force UTF-8 → scrub invalid encoding → strip control characters via `gsub` → `strip` → truncate to a byte budget via `byteslice` + `rstrip` → freeze. Both were clearly written to solve the identical problem ("bound one untrusted/disclosable string before it reaches a prompt, transcript, or durable record").
  - The existing correct alternative: `Tamoz::Error.disclosable_message(value, fallback:)`.
  - Real (if narrow) differences prevent a pure swap: `disclosable_message`'s scrub replaces invalid bytes with `"?"`, `BoundedText`'s with `""`; `disclosable_message` uses `DISCLOSURE_CONTROL_CHARACTERS = /[[:cntrl:]]+/u` (POSIX class, includes C1 control codes 0x80-0x9F, collapses consecutive runs to one space via the `+` quantifier), `BoundedText` uses its own `CONTROL_CHARACTER_PATTERN = /[\x00-\x1f\x7f]/` (byte-range, excludes C1, no run-collapsing — N consecutive control bytes become N spaces, not one); `disclosable_message` appends `"..."` on truncation and returns a caller-supplied `fallback` when the result is empty, `BoundedText` does neither; the byte budget is a fixed constant (512) in one and a parameter in the other.
  - `BoundedText` was itself *just* extracted this session to dedupe three call sites within `tamoz-mcp` (catalog/elicitation/invocation) — the dedup was correct as far as it went, but it didn't look up to `tamoz-core` (already a direct dependency) for the more general "sanitize + bound" primitive it was rebuilding a second time.
  - Suggested action: not a safe drop-in today because of the control-char coverage and truncation-suffix differences — but worth deciding whether `Error.disclosable_message` should grow an optional byte-budget/scrub-char parameter that both call sites share, versus documenting explicitly why MCP's untrusted-server-text bounding needs to diverge from core's error-message bounding (e.g. is excluding C1 control codes from the strip actually correct for `BoundedText`'s inputs, or is that an accidental gap?).

- **Control-character regex fragmentation** (supporting evidence for the finding above, but with a wider blast radius): at least four independently-defined patterns exist for "what counts as a control character to strip/reject":
  - `Tamoz::SafeText::CONTROL_CHARACTERS = /[ -]/u` (`gems/tamoz-core/lib/tamoz/safe_text.rb:5`) — doubly private (`private_constant :CONTROL_CHARACTERS` inside `SafeText`, `private_constant :SafeText` inside `Tamoz`), so even code that successfully reaches `SafeText.normalize` via lexical nesting cannot see the pattern itself.
  - `Tamoz::Error::DISCLOSURE_CONTROL_CHARACTERS = /[[:cntrl:]]+/u` (`gems/tamoz-core/lib/tamoz/error.rb:57`) — public, but broader (includes C1 0x80-0x9F) and run-collapsing.
  - `Tamoz::Agent::Profile::CONTROL_CHARACTER_PATTERN = /[\x00-\x1f\x7f]/` (`gems/tamoz-agent/lib/tamoz/agent/profile.rb:141`) and **`Tamoz::Mcp::CONTROL_CHARACTER_PATTERN = /[\x00-\x1f\x7f]/`** (`gems/tamoz-mcp/lib/tamoz/mcp/shared_constants.rb:26`) — byte-for-byte identical regex, near-identical comment ("C0 controls plus DEL. Newlines in argv corrupt every downstream log, prompt, and receipt that renders the command"), in two gems with no dependency edge between them. Per the known non-issue precedent for `assert_depth!`, the *agent/mcp pair specifically* is a structural consequence of the boundary and is not itself flagged — but unlike `assert_depth!`, a shared home for this one **already exists** (`Tamoz::SafeText::CONTROL_CHARACTERS`) and is reachable the same lexical way `SafeText.normalize` already is from both `tamoz-agent` and (were it used) `tamoz-mcp`; it's the double-privacy on the constant itself, not the gem boundary, that's actually blocking reuse here.
  - Inline, uncounted `[[:cntrl:]]` uses: `gems/tamoz-tools/lib/tamoz/tools/skills.rb:176`, `gems/tamoz-tools/lib/tamoz/tools/skills/catalog.rb:121`, `gems/tamoz-tools/lib/tamoz/tools/skills/frontmatter.rb:71`, `gems/tamoz-sqlite/lib/tamoz/sqlite/request_staleness.rb:69`.
  - Suggested action: resolving this needs the same decision as `deep_freeze` did — pick which character class (byte-range C0+DEL, or POSIX cntrl including C1) is actually correct for "text that must never corrupt a log/prompt/transcript," name it once somewhere every gem can reach (or make `SafeText::CONTROL_CHARACTERS` non-doubly-private), and treat every other definition as either an alias or a documented, deliberate divergence.

- **`gems/tamoz-agent/lib/tamoz/agent/sealed_build.rb:33-38`** — `canonical_fingerprint`/`fingerprint` compute `"sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical_document))}"` directly, where `canonical_document`/`document` are Ruby Hash literals. The class's own comment states the goal explicitly: *"the frozen protocol regenerates byte-identically across processes and machines."*
  - The existing correct alternative: `Tamoz::Core.digest(domain, value)` / `Tamoz::Core.jcs(value)` — which make that guarantee a structural property of the encoding (sorted keys, exact number formatting) rather than an accident of Ruby Hash insertion order. `JSON.generate` on a Hash preserves *insertion* order, not a canonical order; today's fixed hash literals happen to insert fields in the same order every call, so this is not currently broken, but nothing enforces that a future edit (a conditionally-omitted key, a reordered literal, a merged-in Hash) keeps preserving it, and there is no test vector pinning the byte output the way JCS's shared vectors do.
  - Not a byte-identical drop-in without care: switching to `Tamoz::Core.jcs`/`digest` would change the actual output bytes (JCS's minimal string-escape table and number formatting differ from `JSON.generate`'s), which would change every previously-recorded `canonical_fingerprint`/`fingerprint` value — a compatibility break for anything that persisted or compared against the old value, not merely a refactor.
  - Suggested action: at minimum decide (and comment) that this fingerprint's determinism is *intentionally* insertion-order-based rather than JCS-based; better, migrate it to `Tamoz::Core.digest` with a version bump if backward compatibility isn't required, since the whole point of this class is the guarantee JCS already exists to provide.

## Low

- **`gems/tamoz-mcp/lib/tamoz/mcp/errors.rb:128`** — `Tamoz::Mcp::OutputLimitError < MCP::Client::RequestHandlerError`, the one error class in `tamoz-mcp` that does not descend from `Tamoz::Mcp::Error`/`Tamoz::Error` and so does not carry `category`/`retryable?`/`user_visible?`/`safe_message`. This is deliberate and well-documented in place: *"Subclasses the SDK's handler error so existing SDK rescue paths keep working, but carries the typed class Invocation classifies on."* Not a misuse finding — flagged only so it's on record that any code generically dispatching on `Tamoz::Error`'s `Metadata` contract (`category`, `retryable?`, etc.) needs to special-case this one class rather than assume universal support; worth a quick check that `Invocation`'s classification path (mentioned in the comment) is in fact the only place that touches it.

- **Bare 64-char-hex digest pattern (no `"sha256:"` prefix)** — `Tamoz::Tools::ToolArgumentValidator::SHA256_HEX_PATTERN = /\A[0-9a-f]{64}\z/` (`gems/tamoz-tools/lib/tamoz/tools/tool_argument_validator.rb:31`, **explicitly commented** as distinct from `Tamoz::Core::JCS::DIGEST_PATTERN`'s prefixed wire format — a good example of documenting a real divergence rather than silently duplicating) versus the same bare regex defined independently and *without* comment in `Tamoz::Comms::DecisionRecord#validate_hex!` (`gems/tamoz-comms/lib/tamoz/comms/decision_record.rb:237`) and `Tamoz::Comms::PairingChallenge#validate!` (`gems/tamoz-comms/lib/tamoz/comms/pairing_challenge.rb:63`). This is more duplication-between-peers than misuse of an ignored tool, since `tamoz-core` has no "bare hex64" primitive to point at either — noted for completeness since all three independently reinvent the same fragment, but it belongs at most on the duplication agent's list; not pursued further here.

- **`gems/tamoz-stream/lib/tamoz/stream/decision_builder.rb:234-240`** — `deep_dup` (recursive Hash/Array rebuild, no freeze, no key-stringification, no validation) is yet another entry in the same family as the High-severity canonicalization list, but its actual job — a *mutable* deep copy for isolation, not a canonical/frozen one — has no existing match anywhere in `Tamoz::Core`/`Tamoz::Immutable` (both of those freeze). Noted as a data point for the broader pattern, not flagged as misuse on its own: nothing today provides what this method actually needs.

## Coverage

- **tamoz-core** — fully reviewed. Read `core.rb`, `error.rb`, `core/jcs.rb`, `safe_text.rb`, `secret.rb`, `immutable.rb`, `circuit.rb` in full; this is the reference inventory itself.
- **tamoz-mcp** (17 files) — fully reviewed. Read `shared_constants.rb`, `bounded_text.rb`, `canonical_json.rb`, `errors.rb` in full; `websearch/egress_circuit.rb` and `invocation.rb` in relevant part; every other file's digest/error/encoding shapes swept by grep.
- **tamoz-comms** (22 files) — fully reviewed. Read `canonical.rb` in full; `decision_record.rb`, `pairing_challenge.rb`, `errors.rb` in relevant part; remainder swept by grep.
- **tamoz-observability** (18 files) — fully reviewed. Read `content_policy.rb` and `correlation.rb` in full/near-full; `errors.rb` confirmed via grep; remainder swept.
- **tamoz-telegram** (5 files, 371 lines) — fully reviewed given its size; confirmed it defines no local error classes and correctly raises `Tamoz::Comms::*` errors throughout.
- **tamoz-otel** (5 files, 418 lines) — fully reviewed given its size; no custom error classes, no misuse patterns found.
- **tamoz-scheduler** (8 files, 927 lines) — fully reviewed given its size; `errors.rb` confirmed aligned to `Tamoz::Error`, `Schedule`'s digest field correctly validated via `Tamoz::Core.valid_digest?`.
- **tamoz-tools** (24 files) — partially reviewed. `tool_argument_validator.rb`, `skills.rb`, `skills/catalog.rb`, `skills/frontmatter.rb`, `skills/values.rb` inspected directly; `Tamoz::Core.canonical`/digest usage confirmed correct throughout via grep; the remaining files (patch/creation/read operations, `check_receipt.rb`, `toolbox.rb`) were swept by grep for the target shapes but not individually read end-to-end.
- **tamoz-agent** (128 files, 25615 lines — the largest gem) — partially reviewed. Every file was swept by grep for digest/encoding/control-char/error-class shapes and for `SafeText`/`Immutable`/`Core.canonical` usage (all found correct where used); `errors.rb`, `profile.rb`, `sealed_build.rb`, `mcp_capability_source.rb` read in full or near-full. The bulk of the gem's business logic (session/episode/healing/memory/improvement internals) was not read file-by-file, so file-local misuse that doesn't match any of the grepped shapes could exist unseen.
- **tamoz-evals** (44 files, 12431 lines) — partially reviewed. `canonical_json.rb` and `errors.rb` read in full; usage breadth of `CanonicalJSON` across the harness confirmed by grep (17 files); most harness files (`sqlite_*`, `heuristic_*`, `memory_*`) were not individually read beyond grep hits.
- **tamoz-sqlite** (67 files, 13350 lines — second largest) — partially reviewed. `wire.rb` read in full; `boundary_registry.rb` read in the relevant sections; `SafeText` usage confirmed correct across ~10 files by grep; `migrator.rb`'s per-migration checksums and most of the 67 files were swept by grep only, not individually read.
- **tamoz-graph** (48 files, 5516 lines) — partially reviewed. `circuit`-adjacent files, `identifier.rb`, `checkpoint_codec.rb` structure, and error-class usage swept by grep; no individual full reads beyond confirming `Tamoz::Circuit`/`Tamoz::Error` subclasses are used correctly (no gem-local error root, reuses core's directly).
- **tamoz-stream** (25 files, 4237 lines) — partially reviewed. `errors.rb` confirmed aligned via grep; `episode_stream.rb`'s digest handling confirmed correct via grep; `decision_builder.rb`'s `deep_dup` read directly (Low finding above); remainder swept by grep only.

No gem was entirely unreached. The gems marked "partially reviewed" are the four largest by line count
(`tamoz-agent`, `tamoz-sqlite`, `tamoz-evals`, `tamoz-graph`/`tamoz-stream`), where full file-by-file
reading was not feasible in this pass; coverage there relied on grep sweeps across every file for the
specific shapes named in the brief (hand-rolled digests, `force_encoding`, control-char regexes,
non-`Tamoz::Error` error roots, disconnected `SafeText`/`Immutable`/`Core.canonical` reimplementations)
rather than reading each file end-to-end, so a misuse pattern that doesn't match one of those greppable
shapes could exist unseen in those four gems.
