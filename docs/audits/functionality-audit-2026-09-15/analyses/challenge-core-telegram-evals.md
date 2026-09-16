# Independent challenge — F01-COR-01, F01-SEC-01, F14-REL-01, F14-COR-01, F27-COR-01

- **Challenger**: independent adversarial challenger (read-only lane), separate from
  every analyst whose work is graded here.
- **Date**: 2026-09-15.
- **Baseline**: `/Users/ghassan/my-projects/tamoz`, branch `audit-15-09`, HEAD `582ae55`.
- **Method**: (1) every cited `file:line` re-read from the current tree, never quoted
  from the report; (2) reachability chain rebuilt as a concrete non-test sequence;
  (3) severity attacked against `BAR.md`'s `critical`/`major`/`minor`/`info` definitions
  by naming a concrete operational cost or stating there is none; (4) grep for missed
  guards and missed callers beyond the cited files; (5) the named focused suites re-run
  for exact counts, with what they do *not* prove stated; (6) behavioral claims
  reproduced or not reproduced with minimal probes under `/tmp/chal/`; (7) a verdict
  per finding: `UPHELD` / `DEMOTED` / `REFUTED` / `UNCERTAIN`.
- **Constraint honoured**: no production code, test, config, gemspec, fixture, or doc
  other than this file was modified; no commit; every probe lives in `/tmp/chal/` and
  the repository is clean of scratch files. No real LLM, provider, or live Telegram
  endpoint was contacted — the only socket is a `127.0.0.1` loopback server in
  `/tmp/chal/f14_cor_probe.rb`.

## F01-COR-01

### Source re-verified

Citations are accurate. `gems/tamoz-core/lib/tamoz/core/jcs.rb:190-198` is exactly as
described:

```ruby
def integer_to_s(value)
  unless value.abs <= MAX_SAFE_INTEGER || value == value.to_f
    raise Error, "integer #{value} is not exactly representable as a double"
  end
  return float_to_s(value.to_f) if value.abs > MAX_SAFE_INTEGER
  value.to_s
end
```

`MAX_SAFE_INTEGER = 9_007_199_254_740_991` (`jcs.rb:38`). The scanner's twin guard is
at `jcs.rb:478-481` and is character-for-character the same predicate — I verified the
report's claim on that point, and I also verified the *opposite* of what the report
implies about it (see **Probe**, the load-bearing result).

The report's citations are correct; the report's **characterization of the test
evidence is materially wrong**, and that is the challenge's central finding.

### Reachability

I attacked the reachability chain and it holds mechanically — with one correction that
cuts against the report. The chain as stated (`Core.digest` → `JCS.digest` →
`canonicalize` → `emit` → `integer_to_s`) is real and is re-confirmed by probe. But
the report claims at `F01-core.md:186` that
`test/core_jcs_vectors_test.rb` "does not cover the `integer_to_s` exemption — no row
exercises an integer above `2**53`". That is false, and it is the single most important
fact in this challenge. `test/core_jcs_vectors_test.rb:86-97` is **dedicated** to the
exemption:

```ruby
# Integers beyond 2**53 that survive a double round-trip serialize with ES
# shortest-round-trip semantics (Go agrees with ES). The exact decimal and
# the ES form differ: 2**60 -> "1152921504606847000", never the 19-digit
# exact value.
def test_above_safe_integer_uses_es_shortest_round_trip
  assert_equal '{"n":1152921504606847000}', Tamoz::Core.jcs({ "n" => 1_152_921_504_606_846_976 })
  assert_equal '{"n":1e+21}', Tamoz::Core.jcs({ "n" => 1_000_000_000_000_000_000_000 })
  assert_equal '{"n":1152921504606847000}', Tamoz::Core.jcs_json('{"n":1152921504606846976}')
  assert_equal '{"n":1e+21}', Tamoz::Core.jcs_json('{"n":1000000000000000000000}')
  assert_equal Tamoz::Core.jcs({ "n" => 1_152_921_504_606_846_976 }),
               Tamoz::Core.jcs({ "n" => 1_152_921_504_606_846_976.0 })
end
```

This does not merely *cover* the exemption; it **pins the exact bytes the report calls
a defect**, calls them "Go agrees with ES", and asserts that the integer form and the
float form are equal byte-for-byte. The report's "no row pins the `integer_to_s`
exemption" is therefore not a coverage gap — it is a misreading of a file the report
lists as its own contract evidence.

### Severity

Assessed against `BAR.md`: `major` is "material correctness … gap with REAL OPERATIONAL
COST". I could not find that cost, and the report's own blind spot at `F01-core.md:262`
concedes the decisive point — it "found no in-repo producer of a value above `2**53`".
Worse, the exemption is **load-bearing**, not vestigial: removing it as recommended
(`F01-core.md:201`) does not just "make the producer's accepted set equal to the
parser's", it **breaks the receiving path** for the very document the vector suite
pins. I proved this directly.

### Guards

Grepped beyond the cited files. The exemption has three independent defences the report
treats as absent:

1. `test/core_jcs_vectors_test.rb:91,93` commits the behaviour as intended, in both the
   value path and the received-bytes path.
2. `jcs.rb:9-14` (class comment) and `jcs.rb:194-195` state it as intended.
3. `documentation/benchmark/BENCHMARK_PROTOCOL.json:10` pins the Go-side parity digest
   `sha256:e4f866204344a5f19994e28afdea67b610e34405b062bbfd2879209a363d81f3`, and
   `AGENTS.md` states that Ruby digests and this parity digest "change only as a
   deliberate, reviewed update". **No pinned digest has moved**: the parity digest, the
   six wire digests and the protocol SHA all still verify at this commit (the vector
   suite passes, below). The coordinator's requested test — "check whether any pinned
   digest actually MOVED" — resolves to *no drift*, which is evidence **for** the
   behaviour being a stable cross-language contract and **against** real drift.

### Probe

`/tmp/chal/jcs_probe.rb`, run with
`export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH" && ruby /tmp/chal/jcs_probe.rb`.
Per-case exact output on the cases the coordinator named, each probed separately:

| Case | Result |
|---|---|
| key ordering | `{"b"=>1,"a"=>2}` and `{"a"=>2,"b"=>1}` → identical `"{\"a\":2,\"b\":1}"`. UTF-16 order confirmed: `{"\u{10000}"=>1,"\uffff"=>2}` → `"{\"𐀀\":1,\"\uFFFF\":2}"` |
| unicode normalization | NFC and NFD `"café"` are **different** strings, render to **different** bytes (`"café"` vs `"cafe\u0301"`), and digest differently. No silent merge — **sound** |
| float formatting | `0.0`→`"0"`, `1.5`→`"1.5"`, `1e21`→`"1e+21"`, `1e20`→`"100000000000000000000"`, `1e-7`→`"1e-7"`, `5e-324`→`"5e-324"`, `1.7976931348623157e308` round-trips. `-0.0` raises `JCS::Error: negative zero is not representable` — refused, not collided |
| nil vs missing | `{"a"=>nil}` → `"{\"a\":null}"` vs `{}` → `"{}"` — **distinct** |
| nested arrays | `{"a"=>[1,1.0,[2**60,nil]]}` → `"{\"a\":[1,1,[1152921504606847000,null]]}"` — structure preserved |
| integer-vs-float | `jcs(1)` and `jcs(1.0)` are both `"1"` — identical bytes and identical digest |

The last row is the one genuine surprise, and it is **not in the report**: `JCS` collapses
`Integer` and `Float` at equal value (`1` and `1.0` collide). The report claims the
opposite property at `F01-core.md:75` where it says "Int/float are distinct on the state
wire (`["integer",1]` vs `["float",1.0]`)" — that is true of `StateCodec`, whose tag
distinguishes them, but it is **false of `JCS`/`Core.digest`**, the digest rule the row is
about. So the canonicalizer's injectivity gap is *broader* than reported (it also merges
int/float at equal value), while the *specific* integer-regime harm the report asserts is
not reachable.

The decisive probe is `/tmp/chal/jcs_roundtrip.rb`, exact output:

```
exact 19-digit: jcs_json => "{\"n\":1152921504606847000}" ; parse => {"n"=>1152921504606846976}
ES 19-digit: RAISE Tamoz::Core::JCS::Error: integer 1152921504606847000 is not exactly representable as a double
1e20 exact: jcs_json => "{\"n\":100000000000000000000}" ; parse => {"n"=>100000000000000000000}
1e20 exp: jcs_json => "{\"n\":100000000000000000000}" ; parse => {"n"=>1.0e+20}
1e21 exact: jcs_json => "{\"n\":1e+21}" ; parse => {"n"=>1000000000000000000000}
```

This **fails to reproduce the harm as a live defect and refutes the recommendation's
premise**. `JCS.parse` returns a genuine `Integer` for the exact 19-digit form
(`1152921504606846976`) — the scanner *does* accept it. `jcs_x` re-emits it as the ES
shortest form; that is the documented contract. Only if you then re-parse the **emitted**
text does the scanner refuse — and that is exactly what the vector suite asserts must
happen. So the "asymmetric producer/parser" framing is backwards: the two agree on the
canonical form, the exact 19-digit text is not a canonical form the wire is supposed to
carry, and the report's recommendation would make `jcs_json` raise on the pinned input.

`ruby -Itest test/core_jcs_vectors_test.rb` → **14 runs / 73 assertions / 0 failures /
0 errors / 0 skips** (reproduced).

### Verdict — `DEMOTED` to `info`

Assigned `major` is not supportable and the report's key contract-evidence sentence is
wrong. The BAR's `major` tier requires "REAL OPERATIONAL COST"; there is none, because
no in-repo producer reaches `>2**53` (the report concedes this), the behaviour is pinned
as intended by both a dedicated test and the Go parity digest, and no pinned digest has
moved. The recommendation is also harmful as written: dropping the exemption breaks
`jcs_json` on the committed vector. What survives is a real **design fact worth
recording**: `JCS` is not injective on its full accepted set (it merges int/float at
equal value, and merges the `2**60` family with the nearest double), and it is documented
as a cross-language wire rule rather than as an injective function on Ruby values. That
is `info` per BAR ("a verified design fact, limitation, or question that is useful for
later work but is not itself a defect"), with the caveat that the int/float merge *is* a
gap the report did not find and that a future in-repo producer could reach. I do **not**
recommend the code change; I recommend the report be corrected to cite
`test/core_jcs_vectors_test.rb:86-97` and to state the accepted-value set explicitly.

## F01-SEC-01

### Source re-verified

Citations are accurate. `gems/tamoz-core/lib/tamoz/error.rb:14-20` states the
`DisclosableMessage` contract including the prohibition on interpolating "a provider
payload, a third-party exception message, file contents, or a `Tamoz::Secret`".
`NodeError#safe_message` (`error.rb:116-121`) is default-deny and opt-in. The report's
honesty about its own reach is accurate: it says at `F01-core.md:210` that it "could
**not** construct an end-to-end leak from this repository alone". I tried harder than
the report did and reached the same place — with one addition that cuts the other way.

### Reachability

I built the leak the report could not, and then established that it lands on a class
that is **deliberately unmarked**, which is what dissolves the finding.

`gems/tamoz-core/lib/tamoz/core/protocol_error.rb:11-14` says in terms that
`ProtocolError` "deliberately does NOT include `Tamoz::DisclosableMessage`" precisely
because "messages may quote provider text (the JSON parser's message)". That is not a
contradiction of the rule the report calls it (`F01-core.md:108`); it is the rule being
**applied correctly**. `ProtocolError` is the class that quotes provider text, and it is
the class that opts out of disclosure. The `safe_message` it reports is the generic
`"The operation could not be completed."` — I verified this by probe. So a provider body
that reaches a `ProtocolError` message reaches it *inside a class that never discloses*,
which is the design working as stated.

I then went looking for the leak the report posits — a `DisclosableMessage` includer that
interpolates third-party text — and found the includer set by reflection and by grep.
There are **eleven** includers in the tree:

`Tamoz::Core::ToolArgumentError`, `Tamoz::Core::ToolError`,
`Tamoz::Core::ToolPolicyError`, `Tamoz::InterruptInNonInteractiveEpisodeError`
(confirmed at runtime by `ObjectSpace`), plus `Tamoz::Mcp::{ToolArgumentError,
ToolPolicyError, UnavailableError, AmbiguousOutcomeError, CircuitPolicyError}` and
`Tamoz::Agent::PlanRejectedError`.

Every one of the message-authoring sites I read builds its text from literals plus
Tamoz-computed identifiers. I read the two sites the report's threat model needs:
`gems/tamoz-mcp/lib/tamoz/mcp/invocation.rb` (`:186,217,295,582,589,604,663,678,702`) and
`gems/tamoz-mcp/lib/tamoz/mcp/elicitation.rb` — the latter interpolates a
`MCP::Tool::InputSchema::ValidationError` at `:195-205`, but it does so **through
`Tamoz::Error.disclosable_message(...)`** first, i.e. through the redaction rule itself.
`gems/tamoz-mcp/lib/tamoz/mcp/errors.rb:50-56` states the discipline: every message is
"built from Tamoz literals plus identifiers the operator already sees … never from server
payload text". I verified that claim rather than assuming it.

### Severity

Against the BAR's `major` tier, the report assigns `major` while simultaneously grading
itself `medium` confidence and conceding "the reachable leak is not [proven]"
(`F01-core.md:205`). `major` requires a material gap *with real operational cost*. A rule
that is enforced by review, with no *reachable* violation demonstrated after an
adversarial search, has no operational cost I can name. Under BAR's `low`/`medium`
confidence definitions — "the reachable leak is not proven" is `medium` at best and
arguably `low` ("depends on an assumption") — the item is a **test-coverage observation**,
which is the `minor` tier ("testability … debt with limited immediate impact").

### Guards

The guards are stronger than the report credits:

- `DisclosableMessage` is opt-in and `safe_message` is default-deny, so the *receiving*
  boundary never discloses an unmarked class's text. This is the guard that makes
  `ProtocolError` safe, and the report read the comment but did not follow it to the
  conclusion.
- `Tamoz::Error.disclosable_message` applies byte bounds (512) and control-character
  scrubbing at every disclosure site (`error.rb:63-72`).
- `secret_sweep_test.rb` sweeps nine durable surfaces by name and asserts the sweep list
  is complete (`test/secret_sweep_test.rb:25-40`), so adding a surface without deciding
  its secret policy fails the suite.
- Every `Tamoz::Secret` render surface is overridden and probed clean.

### Probe

`/tmp/chal/sec_probe.rb`, `/tmp/chal/proto_probe.rb`, `/tmp/chal/skills_probe2.rb`,
`/tmp/chal/ta_probe.rb`. I attacked the four shapes the coordinator named — a secret
inside a Hash, inside an Array, inside a `Data`/`Struct`, and interpolated into a string —
across `inspect`, `to_s`, an exception message, a backtrace, and a log line. Exact output:

```
to_s: "[REDACTED]"                                      inspect: "#<Tamoz::Secret [REDACTED]>"
interp: "v=[REDACTED]"                                  %s: "[REDACTED]"
Array#join: "[REDACTED]"                                String(): "[REDACTED]"
nested hash inspect: "{:a=>{:b=>[#<Tamoz::Secret [REDACTED]>]}}"
JSON.generate: "{\"k\":\"[REDACTED]\"}"
Data inspect: "#<data D v=#<Tamoz::Secret [REDACTED]>>"
Struct inspect: "#<struct StructS v=#<Tamoz::Secret [REDACTED]>>"
exc.message: "unsupported canonical value: Tamoz::Secret"
exc.full_message: "...jcs.rb:128:in `emit': unsupported canonical value: Tamoz::Secret (Tamoz::Core::JCS::Error)..."
exc.inspect: "#<Tamoz::Core::JCS::Error ... safe_message=\"The operation could not be completed.\">"
parse_object bad JSON w/ secret: Tamoz::Core::ProtocolError: "model returned invalid JSON: ..."   # no secret
Skills.describe(Secret) => "[REDACTED]"   (leaks? => false)
```

I also chased the one shape that *looks* like a leak and is not. `gems/tamoz-tools/lib/tamoz/tools/skills/catalog.rb:55,61` interpolates `Skills.describe(text)` into a
`ToolArgumentError`, which *is* a `DisclosableMessage` includer, and `Skills.describe`
(`skills.rb:175-177`) calls `String(value)` — which for a `Tamoz::Secret` would be the
leak vector. Probed: `String(Tamoz::Secret)` returns `"[REDACTED]"` because `Secret`
overrides `to_s`, so the output is `"[REDACTED]"` and `leaks? => false`. The vector is
closed by the type, not by the call site.

The only leak I could construct is the **provider-text echo the report itself describes**
(`/tmp/chal/proto_probe.rb`): a `ProtocolError` message can carry a provider value
verbatim —

```
ProtocolError message: "reasoning_document/protocol: \"sk-live-LEAKEDPROVIDERSECRET9999\""
is DisclosableMessage? false
safe_message: "The operation could not be completed."
secret_shaped? leaked into message? true
```

— and `gems/tamoz-agent-kernel/lib/tamoz/agent/reasoning_document.rb:77` really does
interpolate `root["protocol"].inspect` from the raw provider bytes into exactly that
message, which `episode_nodes.rb:379-385` then forwards as `repair_directive` back to the
model. So provider text *does* move through an exception message. But the class is
unmarked **by explicit design**, its `safe_message` is generic, and `repair_directive`
returns the text to the model that produced it — no operator, log, or store discloses it.
That is a documented design decision, not the violation the report alleges.

### Verdict — `REFUTED`

The alleged contradiction does not exist: `ProtocolError`'s opt-out of
`DisclosableMessage` is the rule being honoured, not broken, and I could not construct a
leak through any of the four shapes across any of the five rendering surfaces, including
the `Skills.describe` vector that looked most promising. The residual item is real but is
not what the report claims: there is no test asserting that a `DisclosableMessage`
includer's message is free of secret-shaped text. That is a testability observation, and
it is **already delivered** by the recommendation the report makes (add one row beside the
existing rows in `test/secret_sweep_test.rb`). Keep the recommendation as a `minor`
hardening item; drop the `major` severity and the "contradicted by `ProtocolError`" claim,
which is the part I refute.

## F14-REL-01

### Source re-verified

Citations are accurate. `transport.rb:42` is
`updates = result.map { |update| @normalizer.normalize(update).wire }` inside a method
whose only `rescue` is `Comms::ResponseTooLargeError` (`transport.rb:45-46`) —
verified. The bare `Hash#fetch` sites at `normalizer.rb:35,65,66,80,81,87,88,95,99,145-147`
are all real and all unguarded. `inbound_envelope.rb:182-184` raises `ValidationError`
for an oversized `text`, verified. `unsupported_envelope` exists at `normalizer.rb:107-113`
and produces a valid digest-stable envelope, verified — the report's claim that the seam
**already exists and is simply not used** is **correct**, and it is the strongest part of
this finding.

### Reachability

All five reported cases reproduce, plus three the report did not list. But the
reachability chain **breaks at its last link**, and the report's stated consequence is
wrong.

`gateway.rb:210` does catch `ValidationError` (it subclasses `CommsError`,
`errors.rb:15`) and does not catch `KeyError`/`NoMethodError`. That half is correct. The
report then says at `F14-telegram.md:277` that this "aborts the whole gateway process".
I traced the actual caller and it does not. `gems/tamoz-agent-cli/lib/tamoz/agent/cli_comms_commands.rb:139-147`
wraps the gateway loop in a thread with `rescue StandardError => e`, appends to
`failures`, calls `stop_loops`, and returns `:storage_failed`; the drainer thread
(`:150-157`) is identically wrapped. `KeyError` and `NoMethodError` are both
`StandardError` (verified: `KeyError.ancestors.include?(StandardError) => true`,
`NoMethodError.ancestors.include?(StandardError) => true`). The CLI then prints
`tamoz: comms delivery stopped on <class>: <message>` and **returns exit code 1
cleanly** (`cli_comms_commands.rb:161-173`). So the real consequence is:

- the malformed update costs the **gateway loop**, not the process;
- the **drainer thread is stopped too** (`stop_loops`), so outbound delivery stops;
- the process exits **1 with a typed named failure**, not an unhandled backtrace.

That is still a real availability defect — a hostile sender can stop the gateway and the
drainer, and the report is right that the offset is never advanced so the bad update is
re-fetched forever, making it a **persistent** denial rather than a one-off. But "aborts
the whole gateway process" and "process-aborting backtrace" (`F14-telegram.md:174`)
overstate it by one layer, and the BAR's severity call depends on which layer you are
grading.

### Severity

I attacked the operational trigger as the coordinator asked, and it is weaker than the
report assumes for the highest-impact cases:

- **Missing `from` on a `message`:** the report itself grades this `not proven` and notes
  channel posts are the candidate. I confirmed the code path
  (`normalizer.rb:66` `message.fetch('from')`). A channel post missing `from` is
  plausible but unverified from this checkout — the report says the same, honestly.
- **20KB text:** the report calls this a "hostility test". It is bounded *before* it can
  reach the process — `ValidationError` is caught by `gateway.rb:210` and becomes
  `:transient`. So the oversized case does **not** stop anything. The report's own probe
  table shows this (it is the only one of the five that yields a `CommsError`), yet the
  finding's headline counts it as an abort.
- **`text` as an Array, missing `chat`, missing `type`, missing `message`:** these are
  pure hostility tests against a well-formed-JSON contract; the report says so.

So of the five probed cases, one is already correctly handled as `:transient` and four are
hostile shapes a conforming Bot API does not emit. The genuinely reachable case is the
channel-post/no-`from` one, which the report itself declines to prove.

### Guards

Grepped beyond the cited files, and **the report missed a guard**, which is why the
consequence is mis-stated: `cli_comms_commands.rb:139-157`'s per-thread
`rescue StandardError`. The report's scanner signal
(`F14-telegram.md:306-309`) greps only `gems/tamoz-telegram` for `rescue` and concludes
"None of them covers the normalizer" — true of the gem, but the guard that actually
bounds the blast radius lives one gem up, in the caller, and the report never read it.
There is **no** wall-clock `Timeout` guard, and the report is right about that.

The `unsupported_envelope` seam claim is correct and is the reason the recommendation is
sound: `normalizer.rb:107-113` already produces a digest-stable envelope with
`correspondent_id: 'telegram:user:0'`, and routing a per-update failure through it is a
call-site change in `transport.rb:42`, not new machinery.

### Probe

`/tmp/chal/f14_rel_probe.rb` — the real `Normalizer`, the real `Transport`, a stubbed
client returning exactly one update, no network. Exact exception class per case:

| Case | Exception |
|---|---|
| (a) 20KB text | `Tamoz::Comms::ValidationError: text must be a bounded string` |
| (b) text as an Array | `NoMethodError: undefined method 'start_with?' for an instance of Array` |
| (c) message with no `chat` | `KeyError: key not found: "chat"` |
| (c2) message with no `from` | `KeyError: key not found: "from"` |
| (d) `chat` without `type` | `KeyError: key not found: "type"` |
| (e) `callback_query` without `message` | `KeyError: key not found: "message"` |
| (f) update with no `update_id` | `KeyError: key not found: "update_id"` *(not in report)* |
| (g) `update_id` wrong type | `Tamoz::Comms::ValidationError: update_id must be a bounded integer` |
| (h) `message_id` missing | `OK "text" corr="telegram:user:5"` *(absent key tolerated)* |
| (i) `my_chat_member` no `from` | `OK "membership" corr="telegram:user:0"` |
| (j) well-formed | `OK "text" corr="telegram:user:5"` |

All five reported cases reproduce **exactly** as stated, including the exception classes.
The finding's behavioral core is confirmed; only its consequence and its severity are
overstated.

### Verdict — `DEMOTED` to `minor`

The defect is real and the recommendation is correct and minimal — I uphold both. What I
demote is the consequence and therefore the severity. `BAR.md`'s `major` requires "REAL
OPERATIONAL COST"; the achievable cost is a **named, non-zero exit with a stopped drainer**
after a hostile or non-conforming update, not a process abort and not silent corruption.
One of the five probed cases (`ValidationError`) is already handled correctly upstream,
and four of the remaining are hostility tests rather than expected traffic. The one
plausibly-reachable case (channel post with no `from`) the report itself declines to
prove. The BLAR's `minor` tier fits: a bounded reliability/robustness gap with limited
immediate impact, whose remedy is a call-site change at a seam that already exists.

## F14-COR-01

### Source re-verified

Citations are accurate. `client.rb:75-81`:

```ruby
when Net::HTTPConflict
  # 409 is the remote saying another getUpdates holds this bot, or a webhook does...
  raise Comms::PollerConflictError, conflict_message(body)
```

keyed on status alone with no `idempotent`/method-kind distinction — verified. The
comment above it is itself poll-side reasoning ("another `getUpdates` holds this bot"),
which supports the report's reading that the reuse is deliberate at the poll seam and
accidental at the send seam. `errors.rb:70-73` makes `PollerConflictError < CommsError`,
a **sibling** of `AmbiguousDeliveryError`, verified. `delivery_drainer.rb` rescues only
`ThrottledError` (`:54`, `:117`), `AuthenticationError` (`:107`) and
`AmbiguousDeliveryError` (`:147`) — verified line by line; there is no fourth clause.

### Reachability

The chain is real and the probe confirms every link. A send that receives any 409 —
whatever its cause — raises `PollerConflictError`, which the drainer cannot read, so no
`mark_delivery` and no `release_delivery_claim` runs and `send_row` leaves the row
`claimed`.

### Severity

I attacked the two severity-bearing claims, and **one of them the report gets wrong in
its own favour and one it gets right**.

The report says at `F14-telegram.md:406` that the stranded row is "a 30 s `CLAIM_TTL_S`
stall, not a loss", and defers the row-stranding to the drainer's row. I verified this is
**correct and self-healing**, which is why I uphold rather than escalate:
`comms_outbox.rb:146-163` `reconcile_expired_deliveries` runs `UPDATE … SET status =
'unknown'` for `claimed` rows with `send_started_at_ms IS NOT NULL`, and
`delivery_drainer.rb:46` calls it at the **top of every `drain_once`**. So the row moves
`claimed → unknown` after `CLAIM_TTL_S = 30.0`, and `unknown` is the
operator-resolution state (`comms_outbox.rb:250-254`). The message is **not lost** and the
row is **not permanently stranded** — it is bounded and self-healing. This is the
distinction the coordinator asked to settle, and the report's characterization is the
honest one.

Where the report **oversells** is the headline: `F14-telegram.md:364` says "the drainer
thread dies with the row stranded `claimed`". The thread does die (verified), but the row
is not stranded — it is reconciled. The report says this correctly in the body and
overstates it in the title. That is a title/body mismatch, not a severity error.

What carries the severity is the **cost asymmetry**, which is real: a 409 on a send takes
a path with no handler at all, so the failure is reported as a poll-lease conflict with
the wrong vocabulary (`cli_comms_commands.rb:178-181` prints "a gateway lost the Telegram
poller lease" for a *send* failure), it stops the entire drainer, and it depends on a
timer to recover the row. A class outside the seam's declared outcome vocabulary
(`transport.rb:43-49` names the vocabulary for `deliver`) is a genuine
correctness/contract gap with operational cost. `major` fits.

### Guards

Grepped for the missing handler beyond the cited files: there is **no** fourth rescue
clause in the drainer and **no** `ensure` in `send_row` (`delivery_drainer.rb:71-128`),
which the report names correctly as an amplifier. I confirmed the report's claim that
`send_row` has no `ensure` — it is true. No test anywhere scripts a 409 on a send: `grep`
of `test/` for `409`/`Conflict` returns only checkpoint-conflict sites and a comment. So
the seam between the two halves is untested, exactly as the report says.

### Probe

`/tmp/chal/f14_cor_probe.rb` — a `127.0.0.1` loopback `TCPServer` answering `409` with
Telegram's real body (`{"ok":false,"error_code":409,"description":"Conflict: terminated
by other getUpdates request; make sure that only one bot instance is running"}`), pointed
at the **real** `Tamoz::Telegram::Client` and the **real** `Transport`. Exact output:

```
DELIVER(409 on send) => Tamoz::Comms::PollerConflictError: Conflict: terminated by other getUpdates request; make sure that only
  is_a?(AmbiguousDeliveryError) = false
  is_a?(ThrottledError)         = false
  is_a?(AuthenticationError)    = false
  is_a?(CommsError)             = true
POLL(409)          => Tamoz::Comms::PollerConflictError
```

The report's probe result reproduces **exactly**, including `is_a?(AmbiguousDeliveryError)
= false`. The claim is fully confirmed.

### Verdict — `UPHELD` (`major`)

Every element reproduces: the wrong class on a send, the missing drainer handler, the
unreadable-by-design hierarchy, the untested seam, and the bounded 30 s self-healing stall
that keeps this from being a data-loss (`critical`) finding. `BAR.md`'s `major` — a
material correctness/ownership gap with real operational cost — is met. My only correction
is the title's "row stranded `claimed`", which the body already describes correctly as
reconciled. The recommendation (make the 409 branch method-aware, reusing the existing
`idempotent` flag and the existing `transport_failure` mapping at `client.rb:116-122`) is
the smallest credible action at the existing seam and I endorse it unchanged.

## F27-COR-01

### Source re-verified

Citations are accurate. `scoreboard.rb:431` writes `'hard_zero_fired' =>
hard_zero_names(@manifest, @report)` into the entry; `:154-163` collects the names;
`:331-340` `regression_result` sets `status = regressions.empty? || acknowledged ?
'passed' : 'failed'`; `:342-366` derives `regressions` **solely** from axis interval
drops (`current_value < prior_low`); `:402-412` `validate_run!` checks only `run_kind`,
`controls_passed`, `safe_artifact_root?` and report-object-ness. The report's claim that
"no hard-zero branch exists anywhere in the class" is **correct**. So is its claim at
`:249` that `script/benchmark_openclaw_scoreboard:34-58` validates only `run_kind` and
`controls_passed` and calls `Scoreboard.append` directly without a readiness call.

### Reachability

The code path is real: a manifest with a fired hard-zero appends and receives
`status: 'passed'` from the regression verdict. I confirmed this by reading, not by
probe (below). But the report's reachability argument has a hole it does not acknowledge:
`Scoreboard.read(scoreboard_path)` reads a **file**, and the committed scoreboard — the
path the script defaults to, `documentation/benchmark/scoreboard/INTELLIGENCE_SCOREBOARD.json`
(`script/benchmark_openclaw_scoreboard:14`) — **does not exist in this checkout**
(`ls documentation/benchmark/scoreboard/` → `No such file or directory`; a repo-wide
`find` for `INTELLIGENCE_SCOREBOARD*` returns nothing). The report's blind spot at
`:450-451` says it "did not read" that file, "so I cannot say whether F27-COR-01 has
already produced a misleading recorded entry". The answer is stronger than the report
could know: the record is **empty**. No misleading entry exists, and the longitudinal
record the finding is about has never been written. That removes the observability half of
the cost.

### Severity — the doc-vs-code reconciliation the coordinator asked for

I read `documentation/benchmark/openclaw-intelligence-study/02-mission-catalog-and-scoring.md`
myself, at the cited lines and around them. It is not merely "interval-only"; it draws the
line between the two gates explicitly and on purpose:

- `:161-165` — "the entry carries point values only; the regression gate reads the
  referenced `artifact_root` for the intervals and fails when the newest run drops an axis
  below the prior accepted run's interval **without an explicit, reviewed note** — so a
  real regression must be acknowledged, not hidden". Interval-only, with a documented
  acknowledgement escape, is the **written contract of the scoreboard gate**.
- `:87` — the `go` verdict requires "the readiness result is `publishable?`, **and** no
  hard-zero fired in A's cells".
- `:97` — "**A hard-zero is a failed run, not missing data.** It invalidates its run and
  blocks publication."

So the written contract assigns hard-zero enforcement to **`Readiness`/publication**, and
assigns the **scoreboard** regression gate an interval rule. The code matches that split:
`readiness.rb:424-428` turns a fired hard-zero into `mission_hard_zero_not_passed:<id>`,
`readiness.rb:41-44` makes `publishable?` require `ready?`, and
`openclaw_mission_runner.rb:348-349` downgrades a `ready` mission to `failed` on any
non-`passed` hard-zero. I verified all three.

That makes the answer **(b), with an (a)-shaped residue** — i.e. mostly (b). The code is
**correct against its written contract**: the scoreboard is a longitudinal *trend* record
whose gate is interval-based, and hard-zero blocking is owned by readiness/publication,
which is a different gate on a different path. The report's own framing at `:271-275`
("the OpenClaw path *does* gate on it") concedes this — it treats the existence of the
readiness gate as "contrast that proves this is not the general design", when it is more
naturally read as the **division of labour the doc states**.

What residue remains is genuine but small: the scoreboard's CLI is a second door that
writes to the append-only record without going through readiness, so a fired hard-zero can
be *recorded* in the trend without being *blocked* from it. The doc does not forbid that —
it says the entry carries `hard_zero_fired` as a field and that the regression gate is
interval-based. So this is a **doc-vs-code consistency question**, not a demonstrated
defect: either the doc should say explicitly that a fired hard-zero is admissible to the
scoreboard but blocks publication, or the scoreboard should refuse it. Today the two
statements do not contradict each other; they are just not reconciled in one place.

### Guards — the test that pins the behavior

`gems/tamoz-evals/test/scoreboard_test.rb:12-35` is decisive and the report reads it
honestly. `test_append_scales_axes_integers_inverts_cost_and_collects_hard_zeros` builds a
report with **two fired hard-zeros** (`false_success`, `unauthorized_effect`), calls
`SCOREBOARD.append`, and asserts:

- `assert_predicate result, :appended?` (`:22`) — the append **succeeds**;
- `assert_equal %w[false_success unauthorized_effect], result.entry.fetch('hard_zero_fired')`
  (`:30`) — the names are **collected**.

A test that deliberately constructs the exact adverse condition and asserts the append
**succeeds anyway** is a test that pins the current behavior as intended. Under the BAR's
own rule that "a missing test is a lead until its impact is source-grounded", the converse
also holds: **a present test asserting the behavior is positive evidence that the behavior
is the contract.** This does not by itself make the finding wrong — a test can pin a bug —
but it means the finding is a claim about *intent*, not a claim about a gap the authors
overlooked. The report acknowledges this at `:264-270` and at its disposition
(`:315-319`), which is to its credit.

### Probe

No behavioral probe was needed and none was run: the claim is a source+contract claim,
and the report supplies the same evidence I would. I instead executed the report's own
cited command, `ruby -Igems/tamoz-evals/test -Igems/tamoz-evals-runner/lib -Itest
gems/tamoz-evals/test/scoreboard_test.rb` → **4 runs / 22 assertions / 0 failures /
0 errors / 0 skips** (reproduced). I also resolved a blind spot the report could not: the
committed scoreboard file does not exist, so no misleading entry has been produced.

### Verdict — `DEMOTED` to `minor`

The report's own counter-argument, which it honestly surfaces, is the stronger reading. The
doc explicitly contracts the scoreboard gate as interval-only and assigns hard-zero
enforcement to readiness/publication; the code matches that split exactly; a committed test
constructs two fired hard-zeros and asserts the append succeeds. Under `BAR.md`, a
"material … gap with REAL OPERATIONAL COST" is not established: the record is empty, no
misleading entry exists, and the blocking gate the report wants already exists one seam
over. What survives is a **maintainability/consistency** item — two components evaluate the
same hard-zero vocabulary and nothing states which owns the verdict, so the doc and the
CLI's second door should be reconciled in one place. That is the `minor` tier
("documentation … debt with limited immediate impact"), not `major`. I would not raise
`Scoreboard::Error` in `validate_run!` as recommended: it would contradict
`scoreboard_test.rb:12-35` and the doc's `:161-165`, and per `AGENTS.md`'s "choose the
simple solution" and "do not cover rare cases" it adds a gate the written contract does not
ask for. The right smallest action is **one sentence in the doc** naming where hard-zero
blocking lives and that the scoreboard records rather than blocks it.

## Ownership calls

**F14-COR-01 — `tamoz-telegram` owns the classification half; `tamoz-comms-gateway` owns
the handling half; the finding should stay on `F14` as the owner.** The wrong *class* is
produced by `gems/tamoz-telegram/lib/tamoz/telegram/client.rb:75-81`, which is the only
place that knows the request was a send (`idempotent: false` is already in `call`'s
signature) — so the fix is squarely `tamoz-telegram`'s. But the defect is only *observable*
because `gems/tamoz-comms-gateway/lib/tamoz/comms/delivery_drainer.rb` has no clause for
it, and that gem's `send_row` (`:71-128`) also has no `ensure`, which is the amplifier. The
report's disposition (`F14-telegram.md:439-443`) is right: keep it on F14, note the drainer
as the co-owner, and let the drainer row decide whether it wants a catch-all `ensure`.
I confirmed no similar finding exists in the F12 row (`F12-comms-gateway.md` does not raise
it), so there is no duplicate to fold into.

## Net effect on FINDINGS.md

- **F01-COR-01**: change severity to `info` — no operational cost, behaviour is pinned as
  intended by `test/core_jcs_vectors_test.rb:86-97` and the unmoved Go parity digest, and
  the recommended fix breaks `jcs_json` on a committed vector. Correction to record: the
  report's "no row exercises an integer above `2**53`" and "no row pins the
  `integer_to_s` exemption" are both false. Add the missed fact that `JCS` merges
  `Integer`/`Float` at equal value.
- **F01-SEC-01**: change severity to `minor` — no leak is reachable on any of the four
  shapes or five rendering surfaces I attacked, including the `Skills.describe` vector;
  `ProtocolError`'s opt-out is the rule working, not broken. Keep only the test-coverage
  half (the report's own recommendation), and drop the "contradicted by `ProtocolError`"
  allegation.
- **F14-REL-01**: change severity to `minor` — all five exception classes reproduce, but
  `cli_comms_commands.rb:139-157` rescues `StandardError`, so the real cost is a named
  exit-1 with a stopped drainer, not a process abort; the `ValidationError` case is already
  handled as `:transient`. Keep the finding and the `unsupported_envelope` recommendation
  unchanged.
- **F14-COR-01**: keep as `major` — fully reproduced, including
  `is_a?(AmbiguousDeliveryError) = false`; the 30 s `CLAIM_TTL_S` stall is bounded and
  self-healing (not a loss), which is why it is `major` and not `critical`. Correct the
  title's "row stranded `claimed`" to match the body.
- **F27-COR-01**: change severity to `minor` — the doc (`:87`, `:97`, `:161-165`) assigns
  hard-zero enforcement to readiness/publication and contracts the scoreboard gate as
  interval-only, the code matches, a committed test pins the behaviour deliberately, and
  the scoreboard file does not exist so no misleading entry has been produced. Replace the
  recommendation with a one-sentence doc reconciliation; do **not** raise in
  `validate_run!`.
