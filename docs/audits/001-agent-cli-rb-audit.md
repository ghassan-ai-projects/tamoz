# Audit 001 — `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb`

- **Date:** 2026-08-24
- **Target:** `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` (884 lines), hub of the `tamoz` binary
- **Method:** five independent research-only reviewer lenses (responsibility boundaries,
  concurrency/control flow, security & safety, coupling/testability, duplication/API
  consistency). No code changed, no tests run. Line numbers are approximate snapshots of
  this date's tree.
- **Verification:** the orchestrator independently re-verified the two load-bearing claims
  behind the critical finding (see CONC-1 note). All other findings are reviewer-reported
  with cited evidence.

---

## Executive summary

**The owner's suspicion is confirmed, with numbers.** Roughly **320 of 884 lines (~36%)**
are misplaced runtime concern living in a CLI file: provider/model/credential resolution
(`build_model`), durable-session assembly (`run_durable`'s ~15-kwarg hand-roll), and the
drain/stream orchestration engine. The *genuine* CLI half (dispatch, error taxonomy,
prompting, rendering, signals) is disciplined and well-factored — this is not casual
bloat; it is three specific responsibilities parked in the wrong layer.

**Incidentally, the audit surfaced one verified critical defect** unrelated to placement:

> **CONC-1 (critical): SIGINT/SIGTERM during any interactive command live-locks the
> process.** The signal cancels the token; the graph executor absorbs the resulting
> `CancelledError` into an opaque `RunResult(status: :cancelled)` that no durable layer
> translates into a terminal transition, so the thread stays `:running`; the CLI drain
> loop never checks the token and keeps issuing `continue`s that insta-cancel forever.
> The process never exits.

**Security: no criticals.** Secret gating, DB-file hardening, credential naming, and the
fail-closed interrupt policy all verified clean. Four minor hardening gaps recorded.

**Totals: 47 findings — 1 critical, 14 major, 18 minor, 14 info.**

| Severity | Count | Headline items |
|---|---|---|
| critical | 1 | CONC-1 signal live-lock |
| major | 14 | session assembly duplicated (ARCH-1/COUP-5), model resolution in CLI (ARCH-2), drain orchestration in CLI (ARCH-3), trap-context mutex crash (CONC-3), mixin coupling (COUP-1), runner reach-through (COUP-3), gemspec isolation (COUP-4), drifted duplicates (DUP-1/2/3) |
| minor | 18 | symlink stat (SEC-1), invisible dot-sessions (SEC-2), unlogged approvals via `--answer` (SEC-3), error masking (SEC-4/CONC-4), quadratic history scans (CONC-6), ivar temporal coupling (COUP-2), dummy-model hacks (DUP-5/COUP-6/ARCH-6) |
| info | 14 | exit-code map, lease TTL floor, ambient globals, registry bookkeeping |

### Cross-lens convergence (strongest signals)

Three findings were reached independently by multiple lenses — treat these as settled
conclusions, not opinions:

1. **`run_durable`'s assembly block is THE load-bearing problem** (ARCH-1 + COUP-5, same
   seam named twice). It duplicates `WorkerRuntime#build_session` with different kwargs,
   smuggles the approval engine out via the nil-guarded `@approval_engine` ivar (COUP-2),
   and is why SQLite/MCP/engine construction leaks into the CLI (COUP-4/5).
   **Fix named by both lenses:** a factory owned by tamoz-agent — e.g.
   `Tamoz::Agent.open_interactive_session(...) { |assembly| ... }` yielding
   `{ session:, approval_engine:, request_id:, owner_id: }` — with
   `resolve_profile_roles` moving alongside (preserves DR-5 D1's "one shared resolution
   function"; the invariant pins the function, not the file).
2. **Model/provider resolution must leave the CLI** (ARCH-2): key resolved twice by two
   layers (CLI precedence logic vs `RubyLLMModel#initialize`'s own ENV fallback);
   tamoz-evals already subclasses the CLI to override `build_model` — external demand for
   the seam exists today.
3. **Duplicates have already drifted** (DUP lens, three confirmed instances):
   paused→collect→resume differs between `drive_resume` and `drain_to_terminal`
   (empty-interrupt resume vs terminal render on exit-3); one-shot vs durable terminal
   rendering use different verdict wording and drop artifact/next-action facts;
   `map_answer`'s `resolve_effect` grammar contradicts `parse_resolution`'s deliberate
   refusal of `unknown` — and appears to be dead code (no producer emits that descriptor
   kind).

### Recommended order of action

1. **Signal-handling cluster** (smallest fix, biggest correctness win): cancellation check
   at the top of each drain pass exiting via `exit_for_cancellation`; wrap trap bodies'
   `cancel!` in `Thread.new { ... }` copying the pattern `cmd_worker` already documents
   (CONC-1 + CONC-3 + CONC-2 + CONC-5 together form one coherent repair).
2. **Extract model/credential resolver into tamoz-agent** (ARCH-2) — highest leverage ÷ effort.
3. **Extract the interactive-session factory** shared with `WorkerRuntime#build_session`
   (ARCH-1/COUP-5); kills COUP-2 as a side effect.
4. **Duplication-drift repairs** (DUP-1 fall-through reshape, DUP-3 delete dead branch,
   DUP-4 route JSON through `emit_cli_event`) — small, independent.
5. **Move drain skeleton onto Session/DurableRunner** (ARCH-3) — highest value, highest
   effort; land last.
6. **Security minors** (SEC-1 `lstat`, SEC-2 reject leading-dot ids, SEC-4 per-close
   rescue) and hygiene (COUP-4 gemspec/typed LoadError).

---

## Lens 1 — Responsibility boundaries

Inventory: genuine CLI concerns (dispatch, exit-code policy Q3, signals, prompting,
thread-id/session-dir config) stay; misplaced runtime concerns below.

| # | Sev | Finding |
|---|---|---|
| ARCH-1 | major | `run_durable` (~544–606) is the **third** session-assembly path: hand-rolls Adapter + artifact store (`tenant: "session:<thread>"`), McpSourceBuilder, approval engine + `bind_session('interactive')`, ~15-kwarg `Session.new`. `WorkerRuntime#build_session` (worker_runtime.rb ~1052–1083) assembles the same object differently (tenant `"profile:<id>"`, always passes `memory:`/`child_task_runtime:`, never `profile_roles:`). Two owners of one invariant, already disagreeing. Fix: durable-session factory beside `Tamoz::Agent.build`, parameterized by checkpointer + tenant scheme. |
| ARCH-2 | major | `build_model` (~782–838) implements full provider policy in the CLI: §5.3 precedence, credential_ref ENV lookup with typed `ProfileRoleUnavailableError`, P8-v1 `assume_model_exists` rejection, `{PROVIDER}_API_BASE` derivation. Duplicates key-resolution inside `RubyLLMModel#initialize` (ENV fallback there too) — key resolved twice by two layers. tamoz-evals subclasses to replace `build_model` (agent_smoke_corpus.rb ~553): demand exists. Fix: resolver beside `RubyLLMModel` or params on `Tamoz::Agent.build`. |
| ARCH-3 | major | `drain_to_terminal` + stale machinery (~249–368) is a multi-step orchestration engine in the presentation layer: advances queued requests via `session.app.durable_runner.run_next` (layering violation in itself), interprets DR-4 wire payloads, cycles resume/continue. Second place (beside `Worker#run`) encoding runner advance semantics. Fix: non-rendering "advance until terminal, surfacing typed stale failures" moves onto Session/DurableRunner with event callbacks. |
| ARCH-4 | minor | `resolve_profile_roles` / `reject_secret_shaped_override!` (~729–780): secret-detection and role-precedence policy in the CLI using Profile's constants; invariant owned by `SessionRecords` (session_records.rb ~54–56, which has yet another predicate copy at ~480). Labeled challenge to DR-5 D1's "HERE, in cli.rb" placement — the single-function property survives relocation verbatim. |
| ARCH-5 | minor | `@approval_engine` ivar set as a side effect of `run_durable`, mutated later by `resolve_interrupt_decision`; silently no-ops when unset. Becomes explicit parameter if assembly moves behind a factory. |
| ARCH-6 | minor | Dummy-model read-only sessions (`build_list_session` ~537, `peek_session_record` in cli_authority.rb, direct `Adapter.new` in cli_rendering.rb ~209) — symptom of missing read-only projection seam; `SessionStatusProjection` shows the pattern exists. Low priority. |
| ARCH-7 | info | `lease_ttl` + permission enforcement are storage configuration/invariants living in the CLI; defensible as operator config, belongs wherever adapters open. |
| ARCH-8 | info | One-shot default authority profile is `"implement"` (inside `Tamoz::Agent.build`); durable default is `'review'`. Two defaults chosen by one binary — document, don't necessarily change. |
| ARCH-9 | info | The build-vs-Session split itself mirrors the documented ephemeral/durable boundary (PERSISTENCE_DESIGN §9) — NOT the defect. The defect is the duplicated *durable* assembly (ARCH-1). |

**Verdict:** true with precision — ~36% misplaced; top extractions ranked: (1)
model/credential resolver, (2) durable-session factory, (3) drain skeleton (last, hardest).

## Lens 2 — Concurrency & control flow

> Orchestrator verification of CONC-1's chain: `gems/tamoz-graph/lib/tamoz/graph/executor.rb:183–184`
> rescues `CancelledError` → `cancelled(current)` → `status: :cancelled` (:501); grep over
> `writer_run_executor.rb`/`durable_request_executor.rb` finds **no** cancelled handling
> (no terminal transition persisted); grep across gems finds `exit_for_cancellation`
> called only from `cmd_cancel` (cli_session_commands.rb:235); `cli.rb`'s drain loop
> contains no reference to `@cancellation.cancelled?`. Chain confirmed end-to-end.
> CONC-3: `cancellation_token.rb:53–58` — `cancel!` takes `@mutex.synchronize`.

| # | Sev | Finding |
|---|---|---|
| CONC-1 | **critical** | Signal during ask/resume/continue/follow-up/redirect/cancel → infinite live-lock, process never exits. Mechanism: trap → `cancel!` → next `context.check!` raises `CancelledError` → executor rescues it internally into `RunResult(:cancelled)` → **no checkpoint write, no terminal request transition** → view stays `:running` → drain loop issues fresh `continue` → insta-cancel against the still-cancelled token → loop. Each pass also inserts another request row (unbounded inbox growth). Nothing consults `@cancellation.cancelled?`. Fix: check token at top of each drain pass, exit via existing `exit_for_cancellation`; alternatively persist terminal transitions for cancelled results. |
| CONC-2 | major | `EXIT_SIGINT=130`/`EXIT_SIGTERM=143` reachable only via `tamoz cancel`. Even absent the live-lock, SIGINT between turns produces normal view codes (0/2/3) — automation reads a killed run as success. Route cancellation through exit mapping on all drive paths once CONC-1 lands. |
| CONC-3 | major | Trap runs mutex-taking code in trap context: `cancel!` takes the token mutex and synchronously fires subscriber callbacks taking StreamSink's `@state_mutex` (held by the worker on every emission). Contended → `ThreadError: can't be called from trap context` escapes uncaught → hard crash instead of graceful shutdown. The repo's own fix exists one module away: `cmd_worker` wraps `stop!` in `Thread.new` for exactly this reason. Copy it. |
| CONC-4 | major | Render-side exception masked as synthetic `StreamClosedError`: main-thread `sink.each` raises E₁ (e.g. EPIPE from `tamoz ask … | head`); `ensure sink.finish` closes the queue under the still-emitting worker; worker's next emit raises StreamClosedError (not swallowed — cancellation didn't fire); `worker.join` re-raises it, replacing E₁. Diagnostics name the wrong cause. Fix: capture E₁, re-raise after join. |
| CONC-5 | minor | stdin reads are cancellation-blind: after ^C the trap swallows INT, `@input.gets` blocks until operator acts, then every subsequent run insta-cancels (feeding CONC-1's loop / endless re-prompting). ^C looks dead at prompts. Restore default INT while blocked on stdin, or IO.select against a cancellation wake-up. |
| CONC-6 | minor | Quadratic scanning: `history(thread:)` has no LIMIT and `Session#request_id_for` re-scans full history on every `session.view`; drain calls view 2–4× per pass plus the stale-failure scan at pass start. Long threads make every pass slower; compounds CONC-1 into CPU/disk spin. Bound the query, cache execution_id→request_id. |
| CONC-7 | minor | `@stream_error` retention exceeds its documented rationale (one confirm-poll) — can misattribute run N's failure reason to run M's terminal report. Reset per logical turn. |
| CONC-8 | info | Stale-failure dedup is per-process; concurrent interactive + worker drainers each print the line once. Cosmetic. |
| CONC-9 | info | Exit-code map documented: ParseError/ArgumentError→64; typed errors→1; completed+satisfied→0, unsatisfied→2, paused/blocked→3, failed→1; worker always 0 even when signalled (supervisors can't distinguish drained vs stopped); runtime `ArgumentError`s (bad `--answer`, bad TTL, perms) exit 64 with a `--help` hint — conflates usage with configuration faults. |

Challenges: (a) the "deliberately not reset" comment justifies exactly one subsequent
poll, not unlimited retention (basis of CONC-7); (b) DR-4 D3 decision stands, but
once-per-process dedup + full-history rescan assumes a short-lived single drainer —
mechanism should be sequence-cursor based.

Sound: prompts deferred until after `worker.join` (no stdin inside stream loop);
idempotent double-`finish`; worker exceptions surface via join; executor's typed
`RunResult`s; explicit rescue ladder refusing to widen to `Tamoz::Error`.

## Lens 3 — Security & safety

| # | Sev | Finding |
|---|---|---|
| SEC-1 | minor | `File.stat` follows symlinks: a symlink planted at `session_dir` redirects per-thread DBs if target is user-owned 0700. Mitigated downstream (`DatabaseFile` refuses symlinked DB paths, EXCL\|NOFOLLOW 0600 creation). Use `File.lstat` + explicit `symlink?` rejection. mkdir→stat window is same-trust-domain, not exploitable by repo content. |
| SEC-2 | minor | `.` and `..` pass THREAD_ID_PATTERN (no traversal — `/` forbidden, join happens after expand_path). Concrete hole: leading-dot ids create `#{id}.sqlite3` files that `Dir.glob("*.sqlite3")` in `tamoz list` never matches — durable sessions invisible to listing yet resumable by name. Forbid ids starting with `.` (or require `th_` shape for operator-supplied ids). |
| SEC-3 | minor | Interactive CLI uses deliberately ephemeral (memory) decision log; cross-process resume finds no decision row, skips resolution, and the §2.6 decision-log surface records nothing — sole audit trail is the checkpoint transcript. Sharper: `tamoz resume T --answer y` approves `approve_tool` interrupts unprompted and unlogged (explicit-operator channel, but undocumented as such). Engine idempotency verified sound (mutex-guarded, replay-safe, conflicting answers raise). Document `--answer` as a scripted channel; consider recording operator answers durably. |
| SEC-4 | minor | `ensure mcp&.close; adapter.close unless read_only`: if the block raised and `mcp.close` then raises, Ruby replaces the propagating exception (operator sees MCP teardown, not the real graph failure) and `adapter.close` is skipped. Same shape in `install_signal_handlers`. Per-close rescue; suppress close errors when an original exception is in flight. |
| SEC-5 | info | Secret gate verified clean (corrects a common assumption): both model AND provider overrides pass through `reject_secret_shaped_override!`; neither field is in ENTROPY_EXEMPT_KEYS; the gate protects exactly the durable record it exists for. Un-profiled flag/env values are never recorded durably. |
| SEC-6 | info | TAMOZ_LEASE_TTL bounded correctly (rejects Infinity/NaN/junk); residual: near-zero TTLs disable writer mutual exclusion — operator-inflicted; a ≥1s floor is cheap. |
| SEC-7 | info | Signal restore windows (INT default while TERM still cancels between restores; fully default during teardown closes) — covered by sqlite WAL + effect journal recovery. No lost-cancellation hazard in the guarded region. |
| SEC-8 | info | Provider-library error text transits to stderr unredacted (`error_summary` path); constructor messages verified clean of key material; MCP remote text IS redacted via `sanitize_remote_text` — model-call text is not. Cost-of-fix ≈ zero: route through SECRET_VALUE_PATTERNS reducer. |
| SEC-9 | info | MCP workspace equality check is fail-closed under aliasing (expand_path doesn't resolve symlinks/case) — refuses same-dir spellings rather than accepting different dirs. Safe direction; `File.realpath` fixes availability annoyance. |

Challenges: none against DR-5 RC6/invariant 24/§5.2/§5.3 — verified holding. Latent
footgun adjacent to ADR §2.3: hardcoded `approval_session_id: 'interactive'` is harmless
with mandated memory stores, but a future swap to the SQLite-backed engine would make
every CLI process share grants keyed to one constant id — add a guard tying the ephemeral
store choice to that constant.

Sound: `DatabaseFile` exemplary (EXCL\|NOFOLLOW, 0600, identity checks); ephemeral engine
matches operator reading of session scope; EOF/non-interactive fail closed (never a
defaulted approve); artifact store rehashes on admission AND resolve; credentials handled
by env-var NAME only with typed failures, values never printed (grepped).

## Lens 4 — Coupling, dependencies & testability

Collaborator map (abridged): injected — streams/env/factories at composition root ✓.
Hardcoded-new — PromptAdapter/ArgumentParser/OptionPolicy (init), SQLite::Adapter ×5
sites across modules, Session ×3, RuntimeDirectory class calls ×5 sites/3 modules,
StreamEmitter/Sink/Context/CancellationToken per call. Ambient — SecureRandom, real ENV
fallback inside RubyLLMModel when api_key nil (test injecting `env: {}` can leak the
developer's real shell secret into a test — narrow but real).

Mutable-state contract: only 4 of 13 ivars mutate post-init; all 10 modules read them;
write surface genuinely contained to cli.rb. Key implicit contracts: mixins assume
`accept_json`/`runtime_dir_path`/`with_worker_runtime`/`os_user_id` (defined in
CLIWorkerCommands!), session commands assume `drain_to_terminal`/`exit_for_view`
(cli.rb / CLIRendering).

| # | Sev | Finding |
|---|---|---|
| COUP-1 | major | One class ← 10 modules: split bought file size, not decoupling — shared plumbing (`accept_json`, `runtime_dir_path`, `with_worker_runtime`, `os_user_id`) lives in the *worker* module and is reached by schedule/comms×3/config. Contract is folklore; rubocop can't see it. Fix: move the four helpers into a `CLICommandShared` module (extends existing CLICommsShared pattern); no class split needed. |
| COUP-2 | major | `@approval_engine`: written deep in run_durable's begin-block, read nil-guarded by `resolve_interrupt_decision` during draining. Today every live path writes it first (verified) — latent, not broken. Degradation mode is silent: interrupts answered, decision log/grants skipped, approvals re-prompt forever, zero signal. Fix: yield the engine through run_durable's block (already yields 3 values) or pass into `collect_answers_from_view`. Mechanical. |
| COUP-3 | major | `session.app.durable_runner.*` reach-through ×8 sites across two files: inbox protocol knowledge (submit/run_next/fetch/history) duplicated outside tamoz-graph's facade. Runner API change breaks 8 places. Fix: extend Session's facade with passthroughs (or expose `session.requests`). |
| COUP-4 | major | tamoz/sqlite required at runtime at 4 convention-guarded sites with **no LoadError handling**, declared only transitively (fine for gem installs; raw untyped LoadError for curated-load-path children mid-command). Inconsistent with telegram seam's typed `MissingAdapterError` two files away. Plus ordering-coupled `require 'tamoz/telegram'` in build_transport (works only because the factory call above happened to load it). Fix: declare dep honestly OR wrap requires in typed errors; fix the ordering. |
| COUP-5 | major | Assembly has no test seam: approval engine (policy YAML + clock), adapter, MCP, Session all hardcoded — only models/transports fakeable. Don't add five factories: ONE `approval_engine_factory:` kwarg mirroring `model_factory:` covers what tests most need. Converges with ARCH-1's factory extraction. |
| COUP-6 | minor | Dummy-session duplication (cli.rb + cli_authority.rb) drags SQLite/Session construction into rendering/authority code. Fix: `Session.read_only_view(...)` owned by tamoz-agent. |
| COUP-7 | minor | Two error policies coexist (global raise→report vs local rescue-and-print-and-return-1 in with_worker_runtime/cmd_list/observe_doctor/config migrate); message format and caught-class sets diverge per site. Fold into COUP-1's extraction if touched. |
| COUP-8 | minor | RubyLLMModel ctor mutates `Encoding.default_external` process-globally (documented) and reads real ENV fallback — make the fallback an explicit arg if touched. |
| COUP-9 | info | `worker.join` without deadline: hung `session.start` hangs the CLI indefinitely (cancellation stops graph work, not a wedged call). Known behavior, noted. |
| COUP-10 | info | status/approve projections open up-to-500 live Sessions per occurrence — O(occurrences × session boot); fine until counts grow. |

Verdict: smallest seam fixing the biggest problem = the interactive-session factory
(converges with ARCH-1); second = lift four plumbing helpers out of CLIWorkerCommands.
Resist anything larger — mixin-per-command-group works; only its shared base is misplaced.

## Lens 5 — Duplication & API consistency

| # | Sev | Finding |
|---|---|---|
| DUP-1 | major | Paused→collect→resume implemented twice: `drive_resume :paused` vs `drain_to_terminal :paused`. **Already drifted two ways:** (a) drive_resume lacks the `interrupts.empty?` guard — delivers `session.resume({})` where the drain path treats empty-interrupt pause as terminal; (b) declined answer exits 3 printing NOTHING on drive_resume vs full final-view render on drain. `:running` branch is a verbatim duplicate too. Fix: drive_resume reduces to blocked→message+3, terminal→render_show, everything else falls straight into `drain_to_terminal` (which already receives `resume_options:`). Deletes ~25 lines and one dialect — removes an abstraction, doesn't add one. |
| DUP-2 | major | Two terminal-answer renderings: one-shot ("Response: not verified task completion") vs `render_verification` ("Response provided; no task completion was claimed." + artifact_line + Next-action). Already drifted in wording and in facts surfaced; exit codes from different sources. Minimal move: shared VerificationSummary formatter beside existing TerminalProgress. Main refactor-payoff item. |
| DUP-3 | major | `map_answer`'s resolve_effect dialect (accepts `unknown/?`→`:unknown`) vs `parse_resolution`'s `%w[succeeded failed abandoned]` which **deliberately refuses unknown** (rationale cited in effect_journal.rb ~630). Grep finds NO producer emitting a `resolve_effect` descriptor kind (only approve_tool, clarify) — branch likely dead code. Three acceptance rules, three styles (Answer.parse / hand case / inline). Fix per owner's no-rare-cases rule: delete the branch after confirming unreachability with a test; do NOT unify clarify (its empty-means-decline semantic is genuinely different). |
| DUP-4 | minor | Three hand-rolled `{"type"=>…,"data"=>…}` envelopes (render_stream_part json, render_runtime_event json, emit_cli_event). Not yet drifted (audited all 29 JSON.generate sites in the gem). Route the two through `emit_cli_event` — extends existing helper, zero new machinery, protects the machine-facing contract. |
| DUP-5 | minor | dummy_model hack ×3 (cli.rb build_list_session, cli_authority peek_session_record, tamoz-evals smoke corpus) — copies disagree on toolbox args already. Inert today (Session#view never calls the model on read-only paths, verified) but contract implicit. Fix: `Tamoz::Agent::NullModel` beside existing DeferredModel; three production copies across two gems clears the abstraction bar. |
| DUP-6 | minor | Registry triple-bookkeeping (SUBCOMMAND_HANDLERS / SINGLE_ARG_SUBCOMMANDS / NEEDS_HELP_CATCH) manually synchronized. Consistent today (audited); both failure modes concrete (help falling through into runtime-opening body; arity break laundered into generic usage error). At 22 commands, fold into one metadata table — replaces structures, adds nothing speculative. |
| DUP-7 | minor | `[y/N]` confirmation ritual ×3 (authority adoption_confirmation, profile digest activation, profile import) — identical protocol, two share the exact prompt string; surrounding hints already differ. One boolean `confirm!` helper; three IO-protocol copies is past the premature-abstraction threshold. |
| DUP-8 | minor | drive_turn ≡ drive_continue byte-identical except start/continue. Not drifted. Acceptable per owner's three-lines rule; folds naturally into DUP-1's reshaped fall-through if landed. |
| DUP-9 | info | Redundant view fetch around collect_answers (drain fetches view, cases :paused, collect_answers immediately re-fetches same thread — a concurrent advance could prompt against a different interrupt set than checked). Delete wrapper, pass the in-scope view. Trivially safe. |
| DUP-10 | info | Routing ternary duplicated verbatim in run_durable + with_worker_runtime; one-shot variant adds shadow/omits adaptive (looks deliberate). Leave or extract `routing_for(options)`; either defensible. |

Challenges: CLIRendering's header ("two forms can never drift") is true only within the
module — DUP-2 drifted across the boundary; comment overclaims, mechanism good.
`assume_model_exists` raising `Profile::ValidationError` on a pure CLI-flag misuse
conflates policy layers (info).

Sound: `exit_for_view` beside the text it accompanies; `emit_cli_event` as the single
envelope; parse_resolution's reasoned refusal of unknown; per-file ownership headers;
DeferredModel precedent; triple follow-up alias documented and harmless.

---

## Scope notes

- Reviewers read the full CLI gem, tamoz-agent core seams (runtime/session/worker_runtime/
  ruby_llm_model/mcp_source_builder/runtime_directory), tamoz-core stream/cancellation
  plumbing, tamoz-graph executors, tamoz-sqlite adapter/database_file/artifact_store,
  tamoz-approval engine/answer, tamoz-profile constants, and targeted tamoz-evals sites.
- Findings cite approximate line numbers from 2026-08-24's tree; re-locate before editing.
- This audit changes no code. Refactor decisions belong to the owner; the recommended
  order above ranks by (verified impact ÷ effort), cheapest-first.
