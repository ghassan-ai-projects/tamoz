# Talk with Tamoz by voice: bar for the plan

**Task:** a plan good enough to build world-class voice chat from, with no re-deriving · **Owner:** Ghassan ·
**Size:** L · **Set:** 2026-10-09, before the plan was graded · **Plan:** [`PLAN.md`](PLAN.md)

A row passes only when the check ran against the current plan text. "World class" means a strong engineer
new to Tamoz could build each phase from the plan, and a hostile reviewer could not name a crash point,
an attack, or a broken owner rule that the plan does not answer.

## Rows

| # | Property | Check |
|---|---|---|
| P1 | The outcome is one checkable paragraph; owner decisions are recorded with their consequence | Read §1–§2 |
| P2 | Every seam the plan extends is named with a file and line, and each one was opened and confirmed | Spot-check 8 citations with `sed -n`; all match |
| P3 | Extend, don't reinvent: each new class is shown not to duplicate an existing loop, store, effect or model call (AGENTS.md) | A table mapping each new component to the existing seam it reuses or why none exists |
| P4 | Every AGENTS.md owner rule is answered, by name | A table: rule → how the plan complies, or the ADR change it makes |
| P5 | Each invariant maps to at least one result-bar row with a test that can fail | Cross-check §5 against `QUALITY_BAR.md` |
| P6 | Phases: each has a deliverable, its dependencies, an exit gate, and fits one reviewable commit | Read §6 |
| P7 | Threat model: authentication, CSRF, DNS rebinding, XSS, resource exhaustion, secret exposure, retention, spoken and prompt injection, and approval spoofing, each with a control | A threat table |
| P8 | Failure model: every crash or outage point from mic to speaker has a stated outcome (nothing lost, nothing doubled, or one plain reply) | A failure table covering browser, server, gateway, worker, STT, TTS and the chat model |
| P9 | The eval is pre-registered: metrics, thresholds, number of runs, the statistic, BLOCKED and SHORT semantics, and the line between real-model results and plumbing | Read `EVAL.md` |
| P10 | The conversation experience is specified: page states, what is spoken and what is not, dead air, errors, barge-in, latency targets | A UX section |
| P11 | Risks have responses; rollback is stated | §7–§8 |
| P12 | Deferred work is explicit and lands in `FUTURE_PLAN.md` with design, tests and open decisions | Read `FUTURE_PLAN.md` |
| P13 | Every deviation from research revision 3 is listed with its reason | A deviation table |
| P14 | External facts (provider APIs) are dated and cited; no unverified claim is stated as fact | Read §2 and `EVIDENCE.md` after P0 |
| P15 | Interfaces are concrete: HTTP routes with methods, bodies, bounds and status codes; env variable names; the event shapes | A route and event table |
| P16 | Two independent reviewers (different lenses) found no open critical or high finding | Review log below |

## Review log

| Reviewer | Lens | Findings (critical / high / medium / low) | Resolution |
|---|---|---|---|
| R1 (Sonnet 5.5, fresh context) | Security, durability, correctness, against the code | 0 / 8 / 6 / 1 | All resolved in revision 2 (below) |
| R2 (Sonnet 5.5, fresh context) | Architecture and simplicity, the voice experience, the eval | 0 / 8 / 13 / 5 | All resolved in revision 2 (below); two items deferred by name |

Resolutions in revision 2 (finding → where the plan answers it):

- **The HTTP server.**
  - `RawHttp` is unfit: no request line, no bounds, no timeout, always JSON (R1-1, R2-3). Resolved by the
    new `Talk::Http` (§3, §4.4) and the hostile-input tests (§5.1).
- **Host allow-list and binding.**
  - The `Host` guard contradicted `tailscale serve`, and LAN binds were unaddressed (R1-2, R2-10).
    Resolved by `--allow-host`; a non-loopback bind is refused without it and warns when allowed (§4.4,
    §4.9).
- **Two transports per surface, descriptor kind, token, pacing.**
  - Two transports were built per surface, the descriptor kind defaulted to telegram, the token's carrier
    was unclear, and pacing was set by Telegram (R1-3, R2-2, R2-24). Resolved by `Talk::Hub` shared by both
    transports, `build_descriptor` passing the kind, the token reaching the gateway as an env var from the
    file, raised limits, and `--once`/doctor/list never binding (§4.3, §4.4, §4.9).
- **Migration.**
  - The migration was incomplete: the outbox `notice` CHECK and the decision columns (R1-4). Resolved:
    there is no new delivery kind (Heard is an unjournaled `control`), and migration 25 copies every
    decision row and column (§4.3, §4.7).
- **Restarts and the event log.**
  - Restarts hid answers and approval cards, `unknown` rows, and typing flooding the log (R1-5, R2-12).
    Resolved by an epoch and `reset`, `working` kept outside the log, seeding from
    `CommsStore#delivered_messages` including live approval cards, and the accepted rare case named
    (§4.4, §5.2).
- **Audio held across a failed pass.**
  - Audio handed out once could be lost after a failed pass (R1-6, R2-9). Resolved: `fetch_attachment` is
    idempotent and audio is freed on confirmation (§4.4, I3, I9).
- **Inbox confirmation.**
  - Silent loss on clock regression or truncated batches, and resend copies (R1-7). Resolved: only entries
    actually returned are confirmed, `next_offset` is the last returned + 1, and resends are deduped
    (§4.4, I9).
- **Self-echo.**
  - The speaker-to-mic injection loop (R1-8, R2-7). Resolved by half-duplex by default, full duplex opt-in
    with echo cancellation, the echo guard, and the eval `self_echo` (§4.5, §4.8, I10).
- **The ADR-042 amendment.**
  - It was not argued honestly, the Speaker's kernel dependency was undeclared, and nothing stopped the
    VOICE key from being the chat key (R1-9, R2-1). Resolved: the exemption and the amendment are stated as
    owner decisions, with the threat row and fallbacks F10 and F11; the synthesizer is injected; the chat
    key is refused as the VOICE key (§4.1, §4.4, §4.6).
- **Token and header hygiene.**
  - (R1-10, R2-26.) Resolved by `replaceState`, digest compare, `base-uri` and `form-action`, `no-store`,
    `OPTIONS` 404, `503` on stop, and a printed warning that the link carries approval authority (§4.4,
    §4.9).
- **The Speaker.**
  - Timeout, buffering and duplicate paid calls (R1-11). Resolved by a 10 s timeout, a bounded reader and
    single flight (§4.2, §4.4).
- **`Comms::Parties`.**
  - Bindable and admissible lists, where the mix check lives, and the thread prefix (R1-12). Resolved by
    separate lists, the check in `Admission.screening_decision`, and a wider I8 pin (§4.3).
- **The Heard notice.**
  - `identity_key`, the port's path, the Telegram change, and the "spoken verbatim" error (R1-13, R2-11).
    Resolved: `identity_key` is the request id, the port goes through `SessionOptions`, the notice is
    talk-only, and §4.11 is corrected (§4.7).
- **Small items.**
  - The 2^53 bound, spool name collision, `callback_query_id`, §5.2 row 3 (R1-14). Each is answered in §4.4
    and §5.2.
- **Tests that could pass while broken.**
  - (R1-15.) I1, I3, I4, I5 and I9 were rewritten (§5).
- **The statistic.**
  - It was unattainable (R2-4). Resolved: point rate ≥ threshold over N runs, Wilson reported, safety at 20
    runs with the rule of three (§6).
- **The client was unmeasured.**
  - (R2-5.) Resolved by C9, the offline endpointing eval, and the headless Chrome canary with fake audio
    capture (§6).
- **VAD.**
  - It split speech, fired on noise, and let silence turn into hallucinated requests (R2-6). Resolved by a
    1.2 s hang-over (settable), voiced-ratio and peak gates, Send now and Discard, and a PTT tail (§4.5).
- **Mobile Safari.**
  - Autoplay, background, secure context (R2-7). Resolved by the Start unlock, Wake Lock,
    `visibilitychange`, and the HTTPS message (§4.5).
- **"Talk while it works" overpromised.**
  - (R2-8.) Resolved by stating that queued Heard waits, plus visible Stop and Status, MediaSession, and the
    queued label (§4.5, §4.11).
- **Fixture realism.**
  - (R2-13.) Resolved by four voices, noise, band limit, speed and reverb variants, disfluencies, a
    development/held-out split, owner recordings (BLOCKED until supplied), and the limit stated in the
    report (§6).
- **WER normalizer and slots.**
  - The normalizer was missing, slot alternatives were missing, and the 99% slot deviation was not recorded
    (R2-14). Resolved by the normalizer rules, slot alternatives, and the deviation row with its structural
    guarantee (§5.5, §6).
- **Controls and multi-turn.**
  - The controls could not show that the graders can fail, and multi-turn was missing (R2-15). Resolved by
    the C8 controls and C10 (§6).
- **Latency.**
  - Stages were undefined, and "report vs gate" was ambiguous (R2-16). Resolved by the t0–t7 stages,
    `talkTrace`, the voice overhead against the typed twin, and `interval_s` 0.1; latency is report-only in
    this phase (§4.4, §4.5, §6).
- **Time to first audio.**
  - (R2-17.) Resolved by prefetch on deliver. Sentence streaming is deferred as F12.
- **Dead air and pairing.**
  - (R2-18.) Resolved by local tones, a tick on send, Heard paired by request order, and a replay button.
    Lead-ins are deferred as F13 (§4.5).
- **Projection hazards and pacing.**
  - (R2-19.) Resolved by rules for inline code, paths, digests and timestamps, first part only, and raised
    pacing (§4.4, §4.9).
- **Rows marked PASS without their evidence files.**
  - (R2-20.) Resolved: P5, P9 and P14 were reset (iteration 3) and are re-graded below against the files
    that now exist.
- **Phase order.**
  - (R2-21.) Resolved: P3 no longer needs P1 (injected synthesizer), Heard moved before the server, and the
    offline eval E0 comes early (§7).
- **The credential mechanism versus swapping the key.**
  - (R2-22.) Recorded as the rejected alternative (§4.1).
- **Accessibility.**
  - (R2-23.) Resolved by `aria-live`, `alertdialog`, 44 px targets, reduced motion, and Space only when the
    text box is not focused (§4.5).
- **Cost.**
  - (R2-25.) Resolved by C11.


## Loop log

| Iteration | Date | What changed | Rows moved | Still open |
|---|---|---|---|---|
| 1 | 2026-10-09 | First grading of the draft | P1, P6, P11 PASS; P2 FAIL (4 of 20 citations off by a few lines: `gateway.rb`, `gateway_callbacks.rb`, `admission.rb`, `cli_comms_shared.rb`); P3, P4, P7, P8, P10, P13, P15 FAIL (no table); P5, P9 FAIL (no invariant → test map, no eval section); P12 OPEN (no future plan) | P2–P5, P7–P10, P12–P16 |
| 2 | 2026-10-09 | Citations fixed and re-checked (20/20); added §4.9 routes and events, §4.10 experience, §5 invariant → test, §5.1 threats, §5.2 failures, §5.3 owner rules, §5.4 reuse, §5.5 deviations, §6 eval; `FUTURE_PLAN.md` F1–F10. Self-review then found and fixed: notice mislabelled in the diagram, blocking `poll` unstated, message-id reuse after restart, `edit_message` deliveries, tab id collisions, speech cache key on edit, two workers on one runtime, the 1 s confirm latency, profile writer reuse | P2–P15 → PASS | P16 |
| 3 | 2026-10-09 | Both reviews applied: PLAN revision 2; FUTURE_PLAN F8 rewritten, F11–F13 added; `EVIDENCE.md` (P0 real calls). P5, P9 and P14 reset to OPEN (R2-20); P5 and P9 now depend on `QUALITY_BAR.md` and `EVAL.md`, written next, and P14 passes on `EVIDENCE.md` plus the cited URLs | P14, P16 → PASS; P5, P9 → OPEN (pending the result bar and EVAL) | P5, P9 |
| 4 | 2026-10-09 | `QUALITY_BAR.md` (A1–A14, B1–B14, C0–C12, D1–D7, E1–E7, F1–F5) and `EVAL.md` written; every invariant I1–I10 maps to an A row with a mutation; §6's measures, runs, statistic, controls and corpus limit are pre-registered in `EVAL.md` | P5, P9 → PASS | none |
