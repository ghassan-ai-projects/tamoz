# Testing — never pay real time

- Inject the wait; never `sleep`. The gateway drainer paces for real: pass `sleeper: ->(_) {}`.
- In `assert rows.all? do ... end`, Ruby gives the block to `assert` and never checks the
  predicate. Use braces, parentheses, or an expected collection; `test_source_audit_test.rb`
  checks this binding across every test root.
- Fast because it *fails early* is not fast.
- A regression test you have not seen fail proves nothing: temporarily mutate the guarded
  behavior, watch it fail, restore it, and rerun; never use `git stash`.
- Don't weaken the property under test for speed — keep `WAL` + `synchronous=FULL`.
- Irreducible process/kill/socket tests go in `SLOW_TESTS`.
- A deadline the child's own startup must fit inside is a race, not a test — Ruby boot can
  be the whole budget. Size it for the boot, or drop the case; don't widen the sleep.
- `rake test_profile` after adding gates; refresh `TEST_WEIGHTS`.
- **No everyday test file takes more than 5 s on the pipeline** (owner, 2026-10-09). The CI runner is about
  2× slower than a developer Mac, so a file over 2.5 s locally needs work: make it faster first; a file that
  cannot be made faster goes to `SLOW_TESTS`, where `rake ci_full` still runs it. The rule is a median
  over CI runs; one run varies about ±30% per file, so `rake ci` fails on `TEST FILE OVER CAP: <file>` only
  above `TEST_FILE_CAP_SECONDS × TEST_FILE_RUN_NOISE` (owner, 2026-10-10). Each shard charges every file the
  run time of the tests it defines (`test/support/file_clock.rb`). Measure on the runner, not the Mac: a
  throwaway PR with the cap at 0 lists every file's CI time; a loaded Mac misreads files by 2–5×.
- **A child `ruby` under `bundle exec` re-resolves the whole bundle.** `RUBYOPT=-rbundler/setup` is
  inherited, so each spawn pays ~135 ms locally and more on CI; `agenteval_memory_pack_test` went 1.2 s →
  4.3 s under bundler from its workspace checks alone. A subprocess that runs someone else's project (an
  eval workspace) gets `Bundler.unbundled_env`; one that needs the bundle keeps it and spawns less.
- **Cost that grows with the state is in the codec, not the fixture.** Profile with thread CPU time before
  trimming a session test: per-codepoint JCS escaping was 80% of `work_loop_test`
  (`docs/test-quality/STATE_REENCODE_PLAN.md` has what remains).
- **A file this session creates is mode 600; `gem build` then refuses it.** `packaging_test` is the
  only gate that notices, and it reports it as 15 errors in gem *building*, not as a permission
  problem: `Gem::InvalidSpecificationException: specification has warnings`. `chmod 644` every new
  file (dirs `0755`, scripts `0755`) in the same change, or `rake test_slow` goes red for a reason
  no failure message names.
- **A probe that executes scripts inherits their side effects.** `test/script_context_bootstrap_test.rb`
  globbed `script/*` and ran each hit, which ran `script/generate_legacy_session_fixture` and
  rewrote a committed fixture — the *next* test to read it went red. Name the subjects a runner
  probe covers; never discover them by glob.
- **A test that passes locally and fails only on CI is usually reading the WORKING TREE, not the
  checkout.** `documentation_test` resolves every markdown link against the filesystem, so a tracked
  doc linking to an untracked directory (`docs/coding-harness/README.md` →
  `docs/active-investigation/`) resolves on the author's machine and dangles in CI, which checks out
  tracked files only. To reproduce a doc/packaging failure, move the untracked path aside first —
  `git stash` does not cover untracked files and will "reproduce" nothing.
- **Fix the failure the pipeline reports, not the one you inferred.** A `FAILED:` line lists every
  file in the failing SHARD, not every failing file: one assertion fails and shard-mates are named
  with it. Read the numbered failure bodies at the end of the output to find the real subject —
  the CI summary's file list is not a to-do list.
- **A gate that is red before your change is not yours to chase — prove it, then say so.**
  `rake quality:reek` on this branch reports `script/adr_catalog.rb`, `script/adr_traceability.rb`
  and `script/adr_validate.rb` at baseline 0, which reads as your regression because the task names
  bare files. Settle it against the committed revision with a detached worktree
  (`git worktree add --detach /tmp/x HEAD`, same task there) before spending time on symbols the
  diff never touched; it costs a minute. Untracked files do not follow into that worktree, so it is
  also the honest way to reproduce a gate that reads the tracked tree only.
- **A test that restarts the process between cause and effect cannot see in-memory state.** A
  phone-approve test written as two `worker --once` invocations passed with and without the fix,
  because exiting clears the worker's in-memory park that the long-running process keeps. Drive one
  live worker across the event (`once: false` in a thread, wait on its emitted events) or the test
  proves nothing. Prove the test discriminates before trusting it: revert the fix, watch it fail
  with the real symptom, restore, watch it pass.
- **A settle predicate that counts the wrong window silently grades the wrong moment.** The eval's
  tap turn read "Approved." as the whole reply because it counted every `sendMessage` in the
  conversation (the prompt plus the ack already satisfied `> 1`) and treated a reply carrying
  buttons as waiting-on-user. Count within the turn and require the answer that follows the ack.
- **A wrapper that moves a call onto another thread must forward every exception, not only
  `StandardError`.** The work-loop tests simulate worker loss with an `Exception` subclass; the first
  `Tamoz::Cancellation.race` rescued `StandardError`, the thread died silently, and the caller waited
  on its queue forever — `work_loop_test.rb` hung instead of failing. Re-raise whatever the block
  raised on the caller's thread.
- **`rubocop -a` rewrites the whole file, not your hunk.** Autocorrecting a pre-existing file changed an
  unrelated assertion's alignment in `agent_cli_test.rb`. Autocorrect only new files; on touched files, fix
  your own offenses by hand and compare counts against a clean `git worktree add --detach` of HEAD.
- **A full-suite run that overlaps your edits proves nothing.** A `rake test test_slow` started while a
  mutation test temporarily removed a policy entry reported 78 errors that were only the mutation. Run the
  full gate on a tree nobody is editing — or on the scratch worktree with only the package's files copied in.
- **A method added below `private` is not a test and not public API.** Minitest runs only public
  `test_*` methods, so tests appended after a helper's `private` never ran; a `WorkContext#reports?` placed
  after `private` failed every work turn with a `NoMethodError` swallowed into a failed session.
- **Stop a gRPC server from a thread, never from inside the trap.** `server.stop` takes a mutex, which Ruby
  forbids in trap context: the stream worker raised `ThreadError`, aborted with SIGABRT, and never ran its
  `ensure`. `trap("TERM") { Thread.new { server.stop } }`.
- **Only the crashed owner gets a short lease.** Crash tests shorten the lease so the dead owner's claim
  expires after a short sleep, but several gave the *recovering* runtime the same 0.1–0.2 s lease (and the
  work-loop fixture gave every effect 0.2 s to go from prepared to started). On a loaded CI runner the
  recovery outlived its own lease and failed with `LeaseLostError`, on `main` as well as on branches. Give the
  recovering owner, and any test that does not wait for expiry, a normal lease (5 s). The crashing owner needs
  room too: a 0.2 s lease let it lose its claim before it reached the crash under a reshuffled CI shard. Give it
  about 1 s and have the recovery retry until the claim expires, with a deadline.
- **A digest over file text must read it with an explicit encoding.** `PromptPack.digests` used a bare `File.read`, so
  the first non-ASCII prompt (`research_replies.json`) hashed differently under `LANG=C` and a UTF-8 locale: pins made
  in one shell failed in `rake`'s UTF-8 run and passed alone. Read with `encoding: Encoding::UTF_8`, and generate pins
  under the same locale the gate runs in.

- **Snapshotting every SQLite table cannot assume `rowid`.** FTS shadow tables can be
  `WITHOUT ROWID`; `logical_database_rows` failed on an empty, healthy database inside
  its observer. Order by all projected columns and preserve duplicate rows. Inspect
  the observer before attributing a wrapped SQL error to durability or corruption.

- **The locked Minitest version reads `SEED`, not `MT_SEED`.** Coverage commands share
  `TestSuite.coverage_environment`; its subprocess regression verifies the actual run
  options. A private helper must not use the reserved `test_` prefix: the runner
  rejects non-public test methods after loading every selected file.

- Shared scripted models must retain their consumer class names: runtime and worker
  use `model.class.name` as fallback effect identity. Use a named subclass of the
  shared implementation; a constant alias changes the recorded identity.

- CLI refusal tests create their own manifests in temporary directories. A local
  real-run artifact can hide a CI dependency: scoreboard_cli_test now builds a
  failed-controls manifest and keeps the report absent to prove refusal order.

- **An in-process test inherits everything `test_helper` requires.** `tamoz mcp` (then `self-observe`) passed every in-process
  test, then failed its first real `tools/call` with `uninitialized constant Tamoz::SQLite`: the CLI loads
  `tamoz-sqlite` lazily and the helper had preloaded it. A command that a fresh process runs (an MCP server, a
  probe backend, an `exe/` path) needs one test that drives it as a subprocess through the call that matters.

- **An observation must be coherent and complete about its limits.** Self-diagnosis initially read each
  table in a separate SQLite snapshot and silently limited explanations. Pin one reader transaction and
  declare each kind that reaches the limit. Schedule `reason` can contain completion evidence, so column
  names alone do not establish that a projection contains metadata.
- **A new SQLite migration has a second home: `script/tamoz_sqlite_oracle`.** The oracle is an
  independent verifier that pins `SCHEMA_VERSION` and every migration checksum; until it learns the new
  ordinal, every scenario database reads `schema_invalid`. Only `rake ci_full`'s slow lane
  (`sqlite_convergence_probe_test`, `sqlite_raw_oracle_test`) notices — `rake ci` stays green. Telegram
  attachments' migration 24 shipped two commits before `ci_full` caught it. Add the ordinal and checksum
  (`Tamoz::SQLite::Migrator::MIGRATION_<n>_CHECKSUM`, read through `bundle exec ruby`) in the same change.
