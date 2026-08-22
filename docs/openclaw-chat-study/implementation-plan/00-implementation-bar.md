# Implementation bar

This is the end-state bar for the OpenClaw communication redesign, not a feature
checklist. The work is complete only when a bounded turn is admitted, executed,
and delivered through the durable CLI and Telegram with one coherent lifecycle,
task truth and delivery truth kept distinct, and the evidence below committed.

## End-state contract

Given an operator-bound correspondent submitting a turn through Telegram or the
durable CLI, Tamoz must be able to:

1. admit the turn durably before any external acknowledgement is considered
   sent, and return a stable, non-authorizing request reference;
2. project a small closed lifecycle — `accepted → queued | running | waiting |
   blocked → completed | failed | stopped` — that both surfaces render
   differently but interpret identically;
3. keep task state and delivery state (`pending | delivered | failed | unknown`)
   as separate axes in every projection, so `completed + delivery=unknown` is
   never collapsed into `failed`;
4. show bounded, coalesced, semantic progress for slow work without streaming
   model tokens or leaking plan prose, tool output, secrets, or lease detail;
5. resume after worker or gateway restart without duplicating an external send,
   losing the request reference, or replaying a completed effect;
6. treat an ambiguous external send as `unknown` and hand resolution to an
   operator, never a blind retry;
7. answer `/status` from durable request, session, effect, and outbox facts —
   never a live guess or an in-memory cache treated as authority;
8. keep the command grammar and the Gateway handlers in lockstep, so no declared
   command parses as known while being unavailable; and
9. include only confirmed successful terminal deliveries in assistant
   conversation history.

The communication layer is a projection over existing seams. Discovery,
untrusted message content, callback data, and model output never grant
authority, change a reviewed plan, manufacture approval evidence, or replace an
effect or delivery identity. Perceived usefulness is measured by the
communication benchmark (`../benchmark-protocol/`); plumbing tests and a green
suite are not usefulness evidence.

## End-state acceptance matrix

| Area | Must be true | Required proof |
| --- | --- | --- |
| Identity and admission | Every accepted turn commits durably before acknowledgement and carries a stable request reference; inbound identity includes the real normalized/raw payload digest; Telegram update/message/quoted/callback IDs stay distinct. | Admission, reference, and identity-conflict tests plus the canonical happy-path composition test. |
| Delivery correctness | Only the current owner/fence/attempt crosses a send boundary or records its result; ambiguous sends become `unknown`; typed auth/storage failures surface an operator-visible state; no blind retry. | Stale-owner takeover, post-send-unknown, and permanent-auth-failure cases in the delivery fault matrix. |
| Lifecycle projection | CLI and Telegram share one closed state vocabulary and reason-code registry; `/status` exposes both task and delivery axes; progress is bounded, coalesced, and out of model context. | Cross-surface parity and `/status`-during-work tests; progress-coalescing bound test. |
| Command parity | The registry and handlers agree; `/help`, `/status`, `/cancel`, `/whoami`, `/new`, `/redirect` are implemented or removed from the closed grammar, each with auth, persistence, rendering, and tests. | Command-parity test; first-contact-and-control journey. |
| Recovery honesty | Cancellation shows requested → observed → terminal; restart preserves reference, sequence, task state, and safe delivery state; recovery exposes a safe operator handle. | Restart boundary matrix and cancellation-state tests. |
| Context integrity | Pending/unknown terminal output never enters conversation history; progress/control messages never become model context. | Delivery-then-context test proving history inclusion requires confirmed delivery. |
| Measured usefulness | A benchmark reports the communication axes with plumbing/real-transport provenance separated, and at least one real-provider + real-transport run. | Committed benchmark protocol, machine-readable results, and one real run (`../benchmark-protocol/`). |

## Completion evidence

The final completion note must include the exact commands and results for the
relevant tests and quality gates, the benchmark protocol and result artifact,
the real-provider/real-transport configuration class (without secrets), and a
short list of claims that remain unproven. Every phase file must have a dated
status, changed files or an explicit no-change reason, exit evidence, and a
plumbing-versus-real statement. The repository must have no unreviewed failure,
no new architecture regression, and no generated evidence edited without its
generator.

Phase evidence is committed under the folder convention in `README.md`. The
manifest must bind each result to the code revision, the surface, the graph
version, and the command that produced it. A missing artifact, an unresolvable
reference, or an omitted failed attempt is an evidence failure, not a
documentation gap.

This is the acceptance contract for every phase in this folder. A phase is done
only when its own exit criteria are met **and** every global invariant below
holds.

## Global invariants (never regress, in any phase)

Taken directly from the study's integrity and safety invariants
(`../04-tamoz-target-architecture.md`). Each phase must keep all of them true and
add regression tests for any it touches:

1. Inbound identity includes the actual normalized/raw payload digest. Same
   `(surface, bot, update_id)` with a different digest is a durable conflict,
   not a silent duplicate.
2. Telegram `update_id`, message ID, quoted-message ID, and callback-message ID
   remain separate fields used for their intended purposes.
3. Admission is durable before the external acknowledgement is considered sent.
4. Only the current owner/fence/attempt may cross a delivery effect boundary or
   record its result.
5. Model/tool effects remain behind `SessionEffects` and `EffectDispatcher`; the
   communication layer never calls a model or tool directly.
6. Telegram sends remain behind `DeliveryDrainer`; an ambiguous send is `unknown`
   and never blindly retried.
7. Untrusted content cannot expand the sealed capability set, change a reviewed
   plan, manufacture approval evidence, or replace an effect identity.
8. Approval binds actor, surface revision, conversation, prompt receipt,
   interrupt/effect digest, and expiry; deny remains fail-safe.
9. Cancellation is visible as requested, observed, and terminal; it does not
   imply that an already-issued external call stopped.
10. Declared byte, capacity, request, rate, output, and response limits are
    enforced at admission boundaries and produce typed refusal reasons.
11. Only confirmed successful terminal deliveries enter assistant conversation
    history; progress/control messages never become model context.
12. Telemetry is bounded, redacted, and derived from durable facts; it never
    invents state when a writer or reader is unavailable.

Task state, effect state, and delivery state remain three separate axes across
every phase.

## Hard-zero failures

Any of these in a phase's acceptance run fails the phase outright (from
`../06-scenario-matrix.md` and the invariants above):

- external acknowledgement sent before durable admission;
- a stale owner/fence/attempt crossing a send boundary or recording a result;
- duplicate external send after an ambiguous outcome (blind retry);
- an `unknown` delivery or effect reported as success or as a plain failure;
- a same-ID/different-content Telegram conflict silently deduplicated;
- pending or `unknown` terminal output entering conversation history;
- a declared command that parses as known but is unavailable;
- message content expanding authority, altering a reviewed plan, or forging
  approval evidence.

## Evidence standard

- Fixture/scripted-model, fake-transport composition tests prove plumbing and
  invariants only. They are required, but they are never presented as evidence
  that the chat is useful.
- A real-provider + real-transport run is evidence for that run. Usefulness
  claims require the benchmark's measured cells, not anecdotes.
- Every phase's completion note must state plainly which claims rest on plumbing
  tests and which on a real run.

## Quality gates (per repo convention)

Every phase merge must pass:

- `rake ci` (everyday gate);
- `rubocop` clean for touched files;
- `enola check` — no new structural regression (a dependency cycle or unintended
  coupling introduced by the change is fixed before presenting, not after);
- `ci_full` in both locales for any phase touching durability, comms, delivery,
  or packaging. Phases 0, 1, 2, and 3 qualify by their stated scope; record the
  exact invocations rather than relying on this default list.

Comments: none by default, per `AGENTS.md`. Name things so the code reads.

## Non-goals (whole program)

From the study, unchanged:

- no second chat runtime parallel to `Session`, and no in-memory authoritative
  status cache;
- no model-token streaming as the communication contract;
- no automatic retry after an ambiguous external send;
- no affirmative Telegram approval commands until the approval-evidence contract
  is complete (deny-only stays the posture);
- no permissive group or multi-user routing before actor isolation and an
  explicit authorization model exist;
- no groups, media, or multi-agent routing until Phases 0–3 and their evidence
  gates pass (these are the frontier round, `../benchmark-protocol/scenarios/frontier/`);
- no claim that CLI and Telegram must have byte-identical presentation; parity is
  over semantic identity, lifecycle, task/delivery state, controls, and terminal
  outcome;
- no usefulness claim from plumbing tests.

## Per-phase definition of done

A phase is complete when:

1. every work item in its plan file is done or explicitly dropped with a reason
   recorded in the phase file;
2. its exit criteria pass, including the listed tests;
3. the global invariants and hard-zero list above are verified for the touched
   paths;
4. quality gates pass;
5. the phase file's status line is updated with date, evidence, and which claims
   are plumbing vs real.
