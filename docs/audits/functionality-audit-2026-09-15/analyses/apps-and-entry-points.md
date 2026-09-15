# A01 + E01–E09 apps and entry points — ten-row entry-point review

Row / queue / baseline (commit, date) / analyst / budget

- Row: **A01, E01, E02, E03, E04, E05, E06, E07, E08, E09** (the whole
  "Apps and entry points" inventory, `COVERAGE.md:103-114`).
- Queue: `COVERAGE.md` §"Apps and entry points".
- Baseline: `/Users/ghassan/my-projects/tamoz`, branch `audit-15-09`,
  HEAD `582ae55`, 2026-09-15.
- Analyst: independent read-only analyst (W2 lane). No production code, test,
  config, gemspec, fixture, or doc outside the two allowed outputs was modified.
- Budget: ~50 min target, 60 min hard cap. Read-only; no `rake ci`/`rake ci_full`.

This is a multi-row brief. Each row below is reviewed at ITEM level with its own
scope map, behavior path, six lenses, tests, findings, blind spots, and verdict.
The combined JSON carries one object per row in `rows`.

---

## A01 `apps/tamoz-agent/` (`README.md`, `app.json`) — IMPROVE

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `apps/tamoz-agent/README.md` | 19 | Reference-application usage narrative |
| `apps/tamoz-agent/app.json` | 8 | Reference-application manifest |
| `test/public_api_test.rb:468-476` | — | The only test that reads `app.json` |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` | 919 | Real CLI surface (dispatch + subcommands) |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli_argument_parser.rb` | 126 | Real global flag surface |
| `Rakefile:141` | — | `test` task |
| `gems/tamoz-agent-session/lib/tamoz/agent/session_nodes.rb:26` | — | `MAX_REPAIR_ATTEMPTS = 2` |

Entry seam: `app.json` is machine metadata consumed only by
`test/public_api_test.rb`; `README.md` is prose read by a human and by no test
(`test/documentation_surface_test.rb:17-20` pins `install.md`, `limitations.md`,
`operations.md`, `README.md` — **not** the app README).

### Behavior path

1. `app.json` declares `name`, `namespace`, `runtime_package`,
   `status`, `activation_milestone` (`app.json:1-7`).
2. `test/public_api_test.rb:468-476` reads it and asserts the five strings
   literally. It never resolves `namespace` to a constant.
3. `README.md:6-11` shows two `bundle exec tamoz` invocations with
   `OPENAI_API_KEY`, `TAMOZ_MODEL`, `--root`, `--allow-changes`,
   `--check 'test=bundle exec rake test'`.
4. `gems/tamoz-agent-cli/lib/tamoz/agent/cli_argument_parser.rb:53-110` is the
   real flag grammar; `cli.rb:36-63` is the real subcommand table.

### Cross-check of every command and env var A01 names

| A01 claim | Real surface | Result |
|---|---|---|
| `bundle exec tamoz` | `Gemfile:18` wires `tamoz-agent-cli` by path; gemspec ships `exe/tamoz` | **real** |
| `--root .` | `cli_argument_parser.rb:72` | **real** |
| `--allow-changes` | `cli_argument_parser.rb:84` | **real** |
| `--check NAME=COMMAND` | `cli_argument_parser.rb:96`, `:113-122` | **real** |
| `OPENAI_API_KEY` | provider credential convention; `install.md:95` | **real** |
| `TAMOZ_MODEL` | `cli.rb:786`, `cli.rb:828` | **real** |
| `--check 'test=bundle exec rake test'` | `Rakefile:141` defines `task :test`; `bundle exec rake test --dry-run` resolves | **real** |
| "at most two separately reviewed repairs" | `session_nodes.rb:26` `MAX_REPAIR_ATTEMPTS = 2` | **real** |
| `"namespace": "Tamoz::App"` | `Tamoz::App` is **uninitialized** | **FALSE — A01-COR-01** |

### Lens: correctness

`app.json:5` names `namespace: "Tamoz::App"`. That constant does not exist.
Verified directly:

```
$ bundle exec ruby -e 'require "tamoz/agent_cli"; Tamoz::App'
NameError: uninitialized constant Tamoz::App
```

No file under `gems/`, `apps/`, or `lib/` defines `module App` inside
`module Tamoz`. The manifest therefore names a namespace that a consumer would
fail to resolve. **A01-COR-01** (`major`, `high`, `open`).

Every other A01 claim is real (table above). The README's two invocations are
well-formed against the actual grammar.

### Lens: security and authority

Reviewed. `app.json` is inert metadata read only by a test; it grants no
capability, carries no credential, and is not loaded on any runtime path
(`grep` for `app.json` outside `.git` returns only `test/public_api_test.rb:469`).
The README instructs the operator to put the API key in the environment
(`README.md:6,9`), which matches `install.md:95` and `agent-operator.md:21-23`.
No secret is embedded in either file. No wider authority is claimed by the
manifest than the CLI actually implements. `not evidenced` for an adversarial
path: nothing consumes the manifest at run time, so there is no authority
boundary to attack — what would prove it is a runtime loader for `app.json`,
which does not exist.

### Lens: reliability and durability

Reviewed for the manifest-as-contract. The manifest is static data with no
migration, version negotiation, or reader that could fail partially.
`format_version: 1` (`app.json:3`) is written but never read by any consumer —
`test/public_api_test.rb:468-476` asserts the other five keys and not this one.
That is a contract the repository writes and nobody honors. Recorded as
**A01-MNT-01** (`info`); it is a verified design fact, not a defect, because
nothing depends on the version yet.

### Lens: observability and evidence

Reviewed. This row is the evidence problem itself rather than a producer of it.
`test/public_api_test.rb:468-476` pins the manifest strings and passes
(`3 runs, 1051 assertions, 0 failures`), so CI reports the `Tamoz::App`
namespace as **verified** while the constant is uninitialized. A green test
asserting a nonexistent symbol is misleading evidence. This is the observable
consequence attached to A01-COR-01 and is the reason its severity is `major`
rather than `minor`.

### Lens: scalability and resource bounds

`not evidenced`. A01 is two static files with no execution path, no loop, no
allocation, and no queue; there is no resource bound to measure. What would
prove it: a consumer that loads `app.json` at run time and could be driven at
volume — no such consumer exists.

### Lens: maintenance and architecture

Reviewed. Two debts:

1. **A01-MNT-01** — `format_version` is written and unread.
2. **A01-MNT-02** — `apps/tamoz-agent/README.md` is outside the documentation
   surface check. `test/documentation_surface_test.rb:17-20` enumerates exactly
   four pages (`install.md`, `limitations.md`, `operations.md`, root `README.md`)
   and `:32-74` verifies subcommands and flags only in `install.md`. A reference
   app whose own README drifts cannot be caught. Given that this repository has
   already shipped a README denying shipped capabilities (the rationale written
   at `documentation_surface_test.rb:9-12`), the unchecked page is a real
   maintainability gap, not a cosmetic one. **A01-MNT-02** (`minor`, `high`,
   `open`).

### Tests and contracts

- `ruby -Itest test/public_api_test.rb` → **3 runs, 1051 assertions, 0 failures, 0 errors, 0 skips**.
- `ruby -Itest test/documentation_surface_test.rb` → **9 runs, 87 assertions, 0 failures, 0 errors, 0 skips**.
- `bundle exec ruby -e '...Tamoz::App...'` → `NameError: uninitialized constant Tamoz::App` (negative proof, run).
- `bundle exec rake test --dry-run` → resolves (disproves a suspected stale `rake test` claim; `not found` as a defect).
- A test that resolves `app.json`'s `namespace` to a constant: **not found**.
- A test that surface-checks `apps/tamoz-agent/README.md`: **not found**.

### Findings

#### A01-COR-01 — the reference manifest names a namespace that does not exist

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `apps/tamoz-agent/app.json:5` (`"namespace": "Tamoz::App"`); no `module App` under `module Tamoz` anywhere in `gems/`, `apps/`, `lib/`; runtime proof `NameError: uninitialized constant Tamoz::App` |
| Test/contract evidence | `test/public_api_test.rb:468-476` asserts the string equals `"Tamoz::App"` and passes (3 runs / 1051 assertions / 0F) — it pins the literal and never resolves it |
| Scanner signal | none (found by cross-checking the manifest against the constant table) |
| Independent judgment | Confirmed the constant is uninitialized by direct evaluation, not by grep alone. Confirmed the only consumer is the string-asserting test. I could **not** establish that any consumer outside this repository resolves `namespace`; the finding is scoped to the in-repo contract and its false-green test |
| Root cause (five whys) | (1) The manifest names `Tamoz::App` but no such namespace exists. (2) The only reader asserts the string instead of resolving it. (3) The test was written to pin the manifest's shape, so its assertion style is string equality by construction. (4) Nothing in the packaging or public-API gate requires a manifest-declared namespace to be loadable — `docs/public-api.json` lists 1,000+ real entries and does not include `Tamoz::App`. (5) There is no contract stating that a manifest key naming a Ruby constant must resolve; the gate that would prevent recurrence is "every manifest key that names a constant is resolved by the test that pins it" |
| Recommendation | Smallest credible action at the existing seam: in `test/public_api_test.rb`'s `test_reference_application_manifest_identifies_the_bounded_repair_slice`, resolve the declared namespace with the same `const_get` walk `assert_public_entry` (`:477-490`) already uses, and either make `app.json` name the real owning namespace (`Tamoz::Agent`) or drop the key. One line of test, one manifest value. |
| Disposition | Open. Read-only audit does not claim closure by writing a report. |

#### A01-MNT-01 — `format_version` is written and never read

| Field | Content |
|---|---|
| Severity | `info` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `apps/tamoz-agent/app.json:3` (`"format_version": 1`); `test/public_api_test.rb:468-476` asserts the other five keys only |
| Test/contract evidence | `test/public_api_test.rb` passes without touching the key |
| Scanner signal | none |
| Independent judgment | Verified no consumer reads the key (`grep` for `app.json` finds only the one test). Recorded as a verified design fact, not a defect — nothing depends on it yet |
| Root cause | Concise: the key was added for forward compatibility with no reader, which is the documented convention for this field elsewhere in the repo |
| Recommendation | None. The simple path already delivers the property; adding a reader now would be speculative machinery. |
| Disposition | Accepted as `info`. |

#### A01-MNT-02 — the reference app README is outside the documentation surface check

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `test/documentation_surface_test.rb:17-20` enumerates four pages; `apps/tamoz-agent/README.md` is not one of them; `:32-74` scans only `install.md` for subcommands and flags |
| Test/contract evidence | `ruby -Itest test/documentation_surface_test.rb` → 9 runs / 87 assertions / 0F, and the app README is not covered by any of them |
| Scanner signal | none |
| Independent judgment | Verified the four-page enumeration is exhaustive by reading the constant list. All five commands and three env vars the app README names are currently real, so this is debt rather than a live mismatch — I confirmed the drift has **not** happened yet, which is what keeps it `minor` |
| Root cause | Concise: the surface test was written for the user-facing install path, and the reference app README was added later without being added to the page list |
| Recommendation | Add `apps/tamoz-agent/README.md` to the page list used by the flag scan, or move the app's usage block into `install.md` where it is already checked. |
| Disposition | Open, `minor`. |

### Blind spots

- I did not read the full 919-line `cli.rb` command bodies; I read the dispatch
  table (`:36-63`), the error policy (`:118-142`), and the routing helpers
  (`:770-833`). A01 makes no claim about command behavior beyond flag existence.
- Any out-of-repo consumer of `app.json` (a website, a deployment tool) is
  invisible from the checkout. If one exists and resolves `namespace`, the
  severity of A01-COR-01 is unchanged but its blast radius is larger.

### Verdict

**IMPROVE** — critical 0, major 1, minor 1, info 1. One `major` finding meets
the BAR.md threshold.

---

## E01 `gems/tamoz-agent-cli/exe/tamoz` — PASS

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `gems/tamoz-agent-cli/exe/tamoz` | 6 | Shipped executable |
| `gems/tamoz-agent-cli/tamoz-agent-cli.gemspec` | 22 | Declares `executable: 'tamoz'` |
| `gems/gemspec_helper.rb` | 61 | `spec.bindir = "exe"`, `spec.executables = [executable]`, `patterns` includes `exe/*` |
| `gems/tamoz-agent-cli/lib/tamoz/agent_cli.rb` | 23 | Umbrella require |
| `gems/tamoz-agent-cli/lib/tamoz/agent/cli.rb` | 919 | `CLI.run`, error policy, exit codes |

Entry seam: the file is 6 lines — `require "tamoz/agent_cli"` then
`exit Tamoz::Agent::CLI.run`. All behavior lives in the library; this row owns
load path, shebang, and exit propagation.

### Behavior path

1. `exe/tamoz:1` shebang `#!/usr/bin/env ruby`; `:4` `require "tamoz/agent_cli"`.
2. `agent_cli.rb:6-7` requires `tamoz/agent` and `tamoz/comms/gateway`, then the
   `require_relative` chain at `:9-23`.
3. `cli.rb:70-72` `self.run(argv = ARGV, ...)`; `:76-79` `dispatch_subcommand`
   or `run_one_shot`.
4. `:118-142` error policy: usage errors → `USAGE_ERROR` (64) with a
   `Try 'tamoz --help'.` hint; other taxonomy errors → `1`.
5. `exe/tamoz:6` `exit` receives that Integer. `--version`/`--help` set
   `options[:terminal]` (`cli_argument_parser.rb:101-108`) and `run` returns `0`
   at `cli.rb:80`.

### Lens: correctness

Exercised end to end:

- `RUBYLIB=<all gems/*/lib> ruby gems/tamoz-agent-cli/exe/tamoz --version`
  from `/tmp` → `0.1.0.alpha.1`, exit 0. This is the installed-gem shape: the
  file resolves `tamoz/agent_cli` purely through the load path, with **no**
  repo-relative `$LOAD_PATH` manipulation and no `bundler/setup`.
- `... exe/tamoz` with no args → `tamoz: missing argument: TASK` +
  `Try 'tamoz --help'.`, exit **64** (`cli.rb:131-136`). Correct non-zero.
- `... exe/tamoz --help` → banner, exit 0.
- `bundle exec gems/tamoz-agent-cli/exe/tamoz --version` → exit 0.
- Bare `ruby gems/tamoz-agent-cli/exe/tamoz --version` from the repo root
  without bundler → exit 1 with `LoadError: cannot load such file -- tamoz/agent_cli`.

That last case is **not** a defect: a bare `ruby` invocation with no load path is
not the installed surface. The installed surface is a gem whose
`require_paths = ["lib"]` (`gemspec_helper.rb:41`) puts `lib` on the path — which
I simulated with `RUBYLIB` and it passed. Correctness: no finding.

### Lens: security and authority

Reviewed. The executable adds no authority of its own: it forwards `ARGV` and
propagates the return code (`exe/tamoz:6`). It reads no file, opens no socket,
and constructs no credential before the library does. The credential path is
`cli.rb:786-833`, where the precedence is documented as flag > env > profile
role and a missing model is a typed `OptionParser::MissingArgument`
(`cli.rb:833`) rather than an implicit default. No secret is logged by the
launcher. `not evidenced` for a launcher-specific boundary: there is nothing
between the shebang and `CLI.run` to attack — what would prove it is a launcher
that did something (a shell-out, a config read), which this one does not.

### Lens: reliability and durability

Reviewed. Exit-code propagation is total: `CLI.run` returns an Integer on every
reachable path in the rescue ladder (`cli.rb:80`, `:120`, `:125-142`), and
`exit` receives it. `EXIT_PAUSED = 3` (`cli.rb:12`) and the cancellation codes
`EXIT_SIGINT`/`EXIT_SIGTERM` from `Tamoz::Cancellation::Trap::EXIT_CODES`
(`trap.rb:12`, `{"sigint"=>130,"sigterm"=>143}`) are distinct and non-zero, so a
supervisor can tell a pause from a crash from a clean exit. No durable state is
owned by the launcher. No finding.

### Lens: observability and evidence

Reviewed. Failure output goes to stderr with a stable `tamoz: ` prefix
(`cli.rb:132`, `:141`) and a `--help` hint for usage errors. Success output
(`--version`, the help banner) goes to `out`. The two streams are separated by
construction because `CLI.run` takes `out:`/`err:` (`cli.rb:70`). Confirmed by
running: the no-args case printed only the two stderr lines. No finding.

### Lens: scalability and resource bounds

`not evidenced`. The launcher is a 6-line shim: no loop, no pool, no buffering,
no retry. Process-level bounds belong to `F24` (`tamoz-agent-cli`), not to this
file. What would prove it: a resource concern introduced by the launcher itself
— there is none to test.

### Lens: maintenance and architecture

Reviewed. This is the model the other entry points should follow. The file is
the smallest possible shim; all behavior is library behavior and therefore
testable in-process via `CLI.run(argv, out:, err:, input:, env:)`
(`cli.rb:70-73`), which is exactly how `test/documentation_surface_test.rb:76-84`
and `test/agent_cli_test.rb` drive it. Packaging is honest:
`gemspec_helper.rb:43-46` sets `bindir = "exe"` and `executables = [executable]`
only when `executable:` is passed, and `:29` includes `exe/*` in `spec.files` —
so the file is both shipped and registered.

Verified as shipped:

- gemspec declares `executable: 'tamoz'` (`tamoz-agent-cli.gemspec:21`).
- `spec.bindir = "exe"` and `spec.executables = ["tamoz"]` (`gemspec_helper.rb:44-45`).
- File is mode `755` and its shebang is `#!/usr/bin/env ruby`.
- Shebang works under rbenv: with `PATH` prefixed by
  `$HOME/.rbenv/versions/3.3.11/bin`, `bundle exec gems/tamoz-agent-cli/exe/tamoz --version`
  → `0.1.0.alpha.1`.
- `test/packaging_test.rb:756-762` pins exactly this: for `tamoz-agent-cli`,
  `assert_equal ["tamoz"], spec.executables` and `assert_includes contents, "exe/tamoz"`;
  for `tamoz-agent`, `assert_empty spec.executables` (no accidental second shim).
- `test/packaging_test.rb` installs each gem into its own `GEM_HOME` and runs it
  in a clean subprocess (`install.md:51-52`), which is the installed-surface proof.

No finding.

### Tests and contracts

- `bundle exec gems/tamoz-agent-cli/exe/tamoz --version` → `0.1.0.alpha.1`, exit 0 (run).
- `RUBYLIB=<gems/*/lib> ruby exe/tamoz --version` from `/tmp` → `0.1.0.alpha.1`, exit 0 (run; installed-like).
- `ruby exe/tamoz` (no args, RUBYLIB set) → exit **64**, stderr `tamoz: missing argument: TASK` (run).
- `ruby -Itest test/agent_cli_test.rb` → **34 runs, 764 assertions, 0 failures, 0 errors, 0 skips**.
- `ruby -Itest test/documentation_surface_test.rb` → **9 runs, 87 assertions, 0 failures**.
- `ruby -Itest test/packaging_test.rb` → **not run** (installs every gem into its own `GEM_HOME`; too slow for the budget, and the executables policy is read directly at `:756-762`).
- A test asserting the launcher's exit code under a signal: **not found** (see E09).

### Findings

None.

### Blind spots

- `test/packaging_test.rb` was read but not executed. Its executables assertions
  (`:756-762`) were confirmed by reading; the install-and-run assertion was not
  reproduced by running.
- I did not exercise `--json` or any subcommand through the `exe/` shim; the
  in-process `CLI.run` path is the same code and was exercised by
  `test/agent_cli_test.rb`.

### Verdict

**PASS** — critical 0, major 0, minor 0, info 0. All six lenses reviewed;
scalability `not evidenced` with the reason stated.

---

## E02 `gems/tamoz-evals/exe/tamoz-eval` — PASS

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `gems/tamoz-evals/exe/tamoz-eval` | 6 | Shipped verifier executable |
| `gems/tamoz-evals/tamoz-evals.gemspec` | 16 | `executable: "tamoz-eval"` (`:12`) |
| `gems/tamoz-evals/lib/tamoz/evals/cli.rb` | 80 (read fully) | Exit-code ladder and usage |
| `documentation/guides/evaluation.md` | 95 | The documented contract for this command |

Entry seam: `require "tamoz/evals"` then `exit Tamoz::Evals::CLI.run(ARGV)`.

### Behavior path

1. `exe/tamoz-eval:4` requires `tamoz/evals`; `:6` `exit Tamoz::Evals::CLI.run(ARGV)`.
2. `cli.rb:34-36` `return help if argv == ["--help"] || argv == ["-h"]`;
   `:35` `return version if argv == ["--version"]`.
3. `:37-39` `command, *paths = argv`; unless `command == "verify"` **and** paths
   is non-empty → `usage("expected: tamoz-eval verify ARTIFACT...")` → `64`.
4. `:40-41` each path verified; the aggregate is `EXIT_PRECEDENCE.find { ... }`
   over `[INVALID_EVIDENCE(2), INFRASTRUCTURE_FAILURE(3),
   INSUFFICIENT_EVIDENCE(4), GATE_FAILURE(1), SUCCESS(0)]` (`:22-28`).
5. `:53-61` `verify_path` rescues `InvalidArtifactError` → 2 and
   `SystemCallError` → 3.

### Lens: correctness

Exercise results:

- `ruby bin/tamoz-eval --help` → `Usage: tamoz-eval verify ARTIFACT...` /
  `tamoz-eval --version`, exit **0**.
- `ruby bin/tamoz-eval` (no args) → `expected: tamoz-eval verify ARTIFACT...`
  on stderr, exit **64**.
- `ruby bin/tamoz-eval verify /tmp/does-not-exist.json` → exit **2**,
  `...: invalid evidence: ... No such file or directory`.

That last result is worth stating precisely because it is the one place the
contract could be argued: a **missing file** returns `INVALID_EVIDENCE` (2) via
the `InvalidArtifactError` rescue, not `INFRASTRUCTURE_FAILURE` (3). The message
also nests the path twice (`"/tmp/does-not-exist.json: invalid evidence:
/tmp/does-not-exist.json: No such file..."`, `cli.rb:55-56`). This is a
classification choice, not a contract violation: the CLI's own documented exit
set (`evaluation.md:26-28`) treats `verify` as fail-closed on malformed input,
and a missing artifact is by definition an artifact that cannot be verified. It
is not recorded as a defect — the verifier's job is to refuse, and it refuses
non-zero with a typed code. Recorded here as a verified fact.

Load path: the file does **not** manipulate `$LOAD_PATH` and does **not**
require `bundler/setup`; it relies on the gem's `require_paths = ["lib"]`
(`gemspec_helper.rb:41`). Under a bare `ruby` with no load path it fails with
`LoadError` (exit 1) — correct, and expected of an installed command. With the
gem libs on the path it runs (`ruby -I.../tamoz-core/lib -I.../tamoz-evals/lib
exe/tamoz-eval --help` → exit 0). No finding.

### Lens: security and authority

Reviewed. This command's authority is deliberately minimal: it verifies release
evidence and grants nothing. It takes paths, reads them through
`Verifier#verify` (`cli.rb:49`), and prints a JSON decision. It builds no model,
opens no socket, and writes no file. `EXIT_PRECEDENCE` (`:22-28`) means the
**worst** outcome across artifacts wins, so a run cannot report `verified`
because one artifact passed while another was `invalid`. That is a fail-closed
aggregation and it is the correct direction. No finding.

### Lens: reliability and durability

Reviewed. Every failure class is mapped: missing args → 64; invalid evidence →
2; infrastructure/OS error → 3; insufficient evidence → 4; gate failure → 1;
success → 0. `rescue SystemCallError` (`cli.rb:58`) covers the OS-failure family
so an unreadable file cannot escape as a backtrace. The command owns no durable
state and is idempotent by construction (read-only verification). No finding.

### Lens: observability and evidence

Reviewed. Result lines are machine-readable JSON on stdout
(`cli.rb:50-57`: `artifact_type`, `decision`, `digest`, `path`), and failures go
to stderr with a `path: reason` prefix (`:55-56`). stdout/stderr are split by the
`out:`/`err:` keyword defaults (`:35-36`), so a pipeline can separate them.
No secret is echoed: the JSON carries a digest and a path, never artifact
contents. No finding.

### Lens: scalability and resource bounds

Reviewed, bounded. Work is `paths.size` verifications, sequential
(`cli.rb:40`), with no accumulator beyond the code list. The bound is the
operator's argv length; there is no unbounded queue or retry. `not evidenced`
for a measured upper bound: no load test exists, and what would prove it is a
soak over a large artifact set — out of scope for a 6-line shim whose work is
proportional to explicit argv. No finding.

### Lens: maintenance and architecture

Reviewed. Packaging is correct and pinned:

- `tamoz-evals.gemspec:12` declares `executable: "tamoz-eval"`.
- `gemspec_helper.rb:44-45` sets `bindir = "exe"` / `executables = ["tamoz-eval"]`;
  `:29` `exe/*` is in `spec.files`.
- The file is mode `755`; shebang `#!/usr/bin/env ruby`; works under rbenv.
- `documentation/guides/evaluation.md:12-17` documents exactly the two real
  forms (`tamoz-eval verify ARTIFACT...`, `--version`), matching `cli.rb:34-39,74-76`.
- `tamoz-evals` depends only on `tamoz-core` (`tamoz-evals.gemspec:13-15`), which
  matches `install.md:81`'s claim that it is the verifier-only gem. The dependency
  direction is honest — the verifier does not pull the runtime.

One structural observation, recorded as `info`: `cli.rb:37` requires the
**exact** argv shapes `["--help"]`/`["-h"]`/`["--version"]`. `tamoz-eval --version
extra` falls through to `usage` → 64. That is strict and correct for this
command's tiny grammar; it is noted only so a later reader does not mistake it
for an oversight. No finding.

### Tests and contracts

- `ruby bin/tamoz-eval --help` → exit 0 (run).
- `ruby bin/tamoz-eval` → exit 64, stderr usage line (run).
- `ruby bin/tamoz-eval verify /tmp/does-not-exist.json` → exit 2 (run).
- `ruby -I.../tamoz-core/lib -I.../tamoz-evals/lib .../exe/tamoz-eval --help` from `/tmp` → exit 0 (run; installed-like).
- `ruby -Itest test/documentation_surface_test.rb` → 9 runs / 87 assertions / 0F (covers `install.md` only, not `evaluation.md`).
- A dedicated `test/*eval*cli*` suite for this exit ladder: **not found** by
  name search; the ladder is exercised incidentally. Recorded as a blind spot,
  not a finding, because I reproduced every documented code by running the command.

### Findings

None.

### Blind spots

- I did not locate a test file that asserts `Tamoz::Evals::CLI`'s exit ladder
  directly. I compensated by running each documented path and observing the
  code; the `verify` success path (exit 0 with `decision: verified`) was **not**
  reproduced because it needs a real artifact — `not run`.
- `documentation/guides/evaluation.md` is not covered by
  `test/documentation_surface_test.rb` (whose page list is `install.md`,
  `limitations.md`, `operations.md`, `README.md`, `:17-20`). I read it and
  matched it by hand; the commands it shows do exist.

### Verdict

**PASS** — critical 0, major 0, minor 0, info 0.

---

## E03 `gems/tamoz-evals-runner/exe/tamoz-eval-runner` — PASS

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `gems/tamoz-evals-runner/exe/tamoz-eval-runner` | 6 | Shipped runner executable |
| `gems/tamoz-evals-runner/tamoz-evals-runner.gemspec` | 39 | `executable: "tamoz-eval-runner"` (`:19`) |
| `gems/tamoz-evals-runner/lib/tamoz/evals/runner/cli.rb` | 136 (read fully) | Grammar and exit codes |
| `documentation/guides/evaluation.md:19-32` | — | Documented contract |

Entry seam: `require "tamoz/evals/runner"` then
`exit Tamoz::Evals::Runner::CLI.run(ARGV)`.

### Behavior path

1. `exe/tamoz-eval-runner:4` requires `tamoz/evals/runner`; `:6` exits with the
   CLI return value.
2. `cli.rb:27-41` `run(argv)`: `command, name, *options = argv`;
   `:29` `return usage_message(command) unless valid_arguments?(...)`.
3. `:51-55` `valid_arguments?` requires `command ∈ {scorecard, treatment}`,
   `name` exactly `agent-smoke` (scorecard) or `memory` (treatment),
   `options.length == 2`, `options.first == "--input-manifest"`, and a truthy
   `options.last`.
4. `:45-49` `usage_message` echoes the **expected** command back, so a wrong
   name still gets an actionable line.
5. `:57-64` `dispatch` loads the manifest, then the scripted responses and
   adapter, then runs scorecard or treatment; `:106-116` `run_gate` prints the
   report JSON and returns `SUCCESS`/`GATE_FAILURE`.
6. `:32-41` rescue ladder: `InputManifest::Invalid` → 64; `InvalidArtifactError`
   → 2; `ExecutionError` → 3.

### Lens: correctness

Exercise results:

- `ruby bin/tamoz-eval-runner` (no args) → stderr
  `expected: tamoz-eval-runner scorecard agent-smoke --input-manifest PATH`,
  exit **64**.
- `... scorecard agent-smoke --input-manifest /tmp/nope.json` → stderr
  `runner input manifest is required`, exit **3**.
- `ruby bin/tamoz-eval-runner --help` → exit **64** with the same usage line.

That last case is a real, if small, contract gap and it is recorded as
**E03-ERR-01**: unlike E02 — whose sibling `Tamoz::Evals::CLI` handles
`--help`/`-h`/`--version` explicitly (`cli.rb:34-36`) — the runner has **no
help or version path at all**. `--help` is parsed as `command = "--help"`,
which fails `valid_arguments?`, and the user gets a usage line on **stderr** with
exit 64 rather than help on stdout with exit 0. The inconsistency matters
because both executables ship from the same evaluation family and
`evaluation.md:10-24` presents them together as "the three commands".

Also verified: the exact-argv grammar (`:51-55`) rejects a manifest path given
in the `--input-manifest=PATH` form, because it compares `options.first` to the
literal string `"--input-manifest"`. The documented form
(`evaluation.md:22-23`) is the space-separated one, so the documentation and the
grammar agree; the rejection is noted as a limitation, not a defect.

Load path: again no `$LOAD_PATH` manipulation and no `bundler/setup`; the gem's
`require_paths = ["lib"]` carries it. Bare `ruby` from `/tmp` → `LoadError`
(exit 1); with the runner/evals/core libs on the path → works. `tamoz-evals-runner`
declares 17 runtime dependencies (`tamoz-evals-runner.gemspec:20-38`), consistent
with its role as the execution harness. No finding.

### Lens: security and authority

Reviewed, and this row has the most interesting boundary of the three shipped
executables. The runner **never touches a live model or network**:
`evaluation.md:40` states it, and the code enforces it structurally — the model
is supplied by a **scripted adapter** loaded from the manifest
(`cli.rb:70-84`) whose path and SHA-256 are both checked
(`:71-75`, `:79-83`). So model responses are operator-pinned bytes, not a
provider call. `InputManifest.from_path(..., package_roots: [PACKAGE_ROOT,
Tamoz::Evals::DATA_ROOT.to_s])` (`:58-60`) confines resolution to declared
package roots. `invoke_factory` (`:118-127`) inspects `factory.parameters` and
wraps an `ArgumentError` into a typed `ExecutionError` rather than letting a
reflection failure escape. No credential is read; no secret is printed. The
manifest is caller-owned external input validated before use, which is the
correct trust direction. No finding.

### Lens: reliability and durability

Reviewed. Exit codes are distinct and total (0/1/2/3/64, `:10-14`, `:32-41`).
`run_gate` (`:106-116`) rescues the two evidence/execution classes locally so a
per-gate failure returns a code instead of unwinding into the outer ladder. A
missing `scorecard_factory` is converted into an explicit `ExecutionError` with
a named message (`:90-93`, `:100-103`) rather than a `NoMethodError` on `nil` —
that is the right fail-closed handling for an external adapter that did not
supply the needed factory. The command owns no durable state; re-running is
safe. No finding beyond E03-ERR-01's ergonomics.

### Lens: observability and evidence

Reviewed. The report is printed as JSON on stdout (`cli.rb:108`
`@out.puts(report.to_json)`), failures go to stderr with a stable `label:`
prefix (`:111`, `:114`), and the label distinguishes `agent-smoke` from
`treatment memory` so an operator knows which gate spoke. The exit code
separates "the gate failed" (1) from "the evidence was invalid" (2) from "the
harness could not run" (3) — the three are genuinely different operational
situations and are kept distinct. No secret content is emitted. This is the
strongest observability of the three shipped executables. No finding.

### Lens: scalability and resource bounds

Reviewed, bounded. One scorecard or one treatment per process
(`:29`, `:63`); no loop over inputs, no retry, no queue. The manifest is read
once. `not evidenced` for a measured resource ceiling of the scorecard corpus
itself — that belongs to the `tamoz-evals-runner` gem row, not to this launcher,
which contributes no unbounded work of its own.

### Lens: maintenance and architecture

Reviewed. Packaging is correct and pinned: `tamoz-evals-runner.gemspec:19`
declares the executable, `gemspec_helper.rb:44-45` registers it with
`bindir = "exe"`, `:29` ships `exe/*`; the file is mode `755`, shebang
`#!/usr/bin/env ruby`, works under rbenv. `test/packaging_test.rb:731-736` adds
a runner-specific policy (`assert_no_packaged_fixtures`,
`assert_evals_runner_source_policy`), which enforces that the runner ships **no**
corpora, scripted providers, or fixture classes — matching `evaluation.md:36-38`.
That is a real architectural boundary held by a test.

The one debt is the shared exit-code vocabulary: `cli.rb:10-14` copies the five
constants from `Tamoz::Evals::CLI` by reference, which is the right direction
(no duplication of the numbers), but the **help/version behavior** was not
carried over with them — which is exactly E03-ERR-01.

### Tests and contracts

- `ruby bin/tamoz-eval-runner` → exit 64, stderr usage (run).
- `ruby bin/tamoz-eval-runner --help` → exit 64, stderr usage (run) — the E03-ERR-01 evidence.
- `ruby bin/tamoz-eval-runner scorecard agent-smoke --input-manifest /tmp/nope.json` → exit 3 (run).
- `ruby -I.../tamoz-evals-runner/lib -I.../tamoz-evals/lib -I.../tamoz-core/lib .../exe/tamoz-eval-runner --help` from `/tmp` → exit 64 (run; installed-like — the `LoadError` is gone, confirming the installed shape works).
- A suite asserting `--help` returns 0 for this executable: **not found**.
- A successful scorecard run (exit 0): **not run** — needs a real `runner-input-v1` manifest with pinned digests; outside this budget and would also need external corpora by design (`evaluation.md:36-38`).

### Findings

#### E03-ERR-01 — the shipped runner has no `--help` or `--version` path

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `cli.rb:27-29` parses `command` positionally with no terminal flag; `:51-55` `valid_arguments?` requires `command ∈ {scorecard, treatment}`; `:45-49` `usage_message`; contrast `gems/tamoz-evals/lib/tamoz/evals/cli.rb:34-36`, which handles `--help`/`-h`/`--version` |
| Test/contract evidence | Ran `ruby bin/tamoz-eval-runner --help` → exit **64**, usage printed to **stderr**; `documentation/guides/evaluation.md:10-24` groups the two commands as one family, and `install.md` does not document either |
| Scanner signal | none (found by exercising the documented-command family) |
| Independent judgment | Confirmed by running, not by reading alone. Confirmed the sibling verifier does handle the flags, so this is an inconsistency inside one family rather than a house style. I did **not** find any doc promising `--help`, so this is ergonomics + family consistency, not a broken doc promise — which is what holds it at `minor` |
| Root cause | Concise: the runner's grammar was written as exact positional argv (`:51-55`) for a two-command surface, and the verifier's terminal-flag branch was not mirrored when the shared exit constants were copied (`:10-14`); the copied vocabulary carried the numbers but not the behavior |
| Recommendation | Smallest credible action at the existing seam: add the same two-line guard the verifier already has at `tamoz/evals/cli.rb:34-36` to the top of `Runner::CLI#run`, printing `usage_message`-style help on `out` and returning `SUCCESS`. No new class, no new file. |
| Disposition | Open, `minor`. |

### Blind spots

- A successful `scorecard agent-smoke` / `treatment memory` run was **not run**
  (needs an external pinned manifest and corpora). I verified the failure ladder
  and the adapter-loading guards by reading `cli.rb:57-127`; the success path is
  read-only evidence.
- `InputAdapters` and `InputManifest` were read only through their call sites in
  `cli.rb`. Their internal validation belongs to the `tamoz-evals-runner` gem row.

### Verdict

**PASS** — critical 0, major 0, minor 1, info 0. One `minor` finding is below
the BAR.md IMPROVE threshold (needs three or more `minor`).

---

## E04 `bin/tamoz-chat-probe` — IMPROVE

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `bin/tamoz-chat-probe` | 165 (read fully) | Deterministic finding-probe harness |
| `test/support/experience_harness.rb` | 212 (read fully) | `ExperienceSim::Harness` |
| `test/support/openclaw_comms_fixture.rb` | — (call sites read) | `model_factory`, `DEFAULT_MODEL_RESPONSES`, tmpdir lifecycle |
| `docs/openclaw-chat-study-refresh/implementation-plan/06-observed-chat-findings.md` | — | The findings this probe reproduces |

Entry seam: `require 'bundler/setup'` (`:17`), `$LOAD_PATH.unshift('../test/support')`
(`:18`), `require 'experience_harness'` (`:20`), then a `PROBES` hash
(`:53-157`) dispatched by `ARGV` (`:159-165`).

### Behavior path

1. `:17` `require 'bundler/setup'` — the probe is a **checkout-only** script; it
   depends on the repo's `Gemfile` being installed.
2. `:18` unshifts the repo's `test/support` onto the load path; `:20` requires
   the harness. `:22-24` binds `Harness`, the fixture, and `ACCEPTED_REVIEW`.
3. `:48-51` `deterministic(**responses)` builds a harness with
   `F.model_factory(**responses)` — the fixture's **scripted** model, and
   `routing:` from the caller.
4. `:159-165` with no args, `selected = PROBES.keys` (all ten run). With args,
   each is looked up; an unknown key warns and `next`s.
5. Each probe calls `harness.say/reply/admit/status_only` and prints cards
   (`:26-33`) and events (`:35-41`), then `h.close`.

### Lens: correctness

Exercised: `bundle exec ruby bin/tamoz-chat-probe OF-4` → exit **0**, printing a
labeled transcript:

```
===== OF-4 =====
# OF-4 normal chat "hi" is routed to a direct answer (no plan/review)
👤 hi
   [accepted] Received r2fac949238.
   [control] r2fac949238 · Now: Starting work on your request. ...
   [answer] r2fac949238 · Response only: result — Hello there. / Response provided; no task completion was claimed.
```

The probe works and prints the labeled transcript its header promises (`:6-7`).

**E04-COR-01**: an **unknown probe name exits 0**. Ran
`bundle exec ruby bin/tamoz-chat-probe NOPE`:

```
unknown probe NOPE (have: OF-4, OF-3, OF-5, OF-6, OF-7, OF-8, OF-11, OF-14, OF-12, OF-15)
exit=0
```

`bin/tamoz-chat-probe:161-162` warns and `next`s; the script then falls off the
end of `selected.each`, and Ruby exits **0**. The script has no `exit` call at
all (it ends at `:165`), so its exit status is always 0 regardless of whether
any probe ran, failed, or was recognized. A caller scripting
`bin/tamoz-chat-probe OF-3 OF-7` inside a gate — which
`06-observed-chat-findings.md:677` documents as a real usage — cannot tell "both
probes ran and reproduced the finding" from "neither name existed". This is the
"exit zero after a failed action" case called out in the brief. Recorded as
**E04-COR-01** (`minor`, `high`, `open`).

A related asymmetry, recorded with it: a probe that **raises** would also be
reported by Ruby as non-zero (an uncaught exception is exit 1), so the only
silent-zero path is the unrecognized-name path. That narrow scope is what holds
severity at `minor` rather than `major`.

### Lens: security and authority

Reviewed, and this is the row's most important property. **The probe does not
call a real provider.** `:48-51` `deterministic` always passes
`model_factory: F.model_factory(**responses)`; `experience_harness.rb:67-77`
uses `model_factory || real_model_factory`, so the injected scripted factory
**wins over** the real one; `real_model_factory` (`:147-156`) is never reached
on this path. The header is explicit and correct (`:9-10`): "Interaction
findings use the DETERMINISTIC provider (no network, isolates the chat UX)",
and `:14-15` directs the model-dependent findings to `tamoz-chat-sim`. That
matches AGENTS.md's rule that a deterministic provider is never evidence of
reasoning, and the probe does not present itself as such.

The script requires `bundler/setup` (`:17`) and reads its fixture from the repo;
it opens no socket and reads no credential — `preflight!` exists only in the
*sim* (`tamoz-chat-sim:27-37`), not here. No authority is widened. No finding.

### Lens: reliability and durability

Reviewed. The probe is stateless across runs: each probe constructs a fresh
`Harness` and calls `h.close` at the end of its lambda (`:61`, `:72`, `:78`,
`:88`, `:97`, `:116`, `:124`, `:138`, `:146`, `:155`). `Harness` isolates every
run in `Dir.mktmpdir` (`openclaw_comms_fixture.rb:214`) and removes it at
`:225`, so a crash mid-probe cannot leak durable state into the next run.

One unguarded path: if a probe lambda raises between construction and
`h.close`, the harness is not closed, because there is no `ensure` around the
`probe.call` at `:164` (contrast `tamoz-chat-sim:88-90`, which **does** wrap its
loop in `begin/ensure harness.close`). With the deterministic provider and
`Dir.mktmpdir`'s own at-exit cleanup this is bounded — it leaks an in-process
object and a tmpdir for the life of the process, not durable state. Recorded as
`info` under E04-MNT-01 rather than as a defect, because the observable
consequence is nil for a short-lived deterministic run.

### Lens: observability and evidence

Reviewed. Output is a labeled transcript per finding: a `===== OF-N =====`
header (`:163`), a `# OF-N ...` title (`:55` and each probe), the user line
(`👤`), and one line per card with `kind`, text, and markup (`:29-32`). Events
are surfaced with their `event`/`reason` (`:39`), which is what lets a reader
see a swallowed failure — OF-3's whole point. This is good evidence hygiene.

The one observability gap is E04-COR-01's: the **process status** does not
carry whether the run succeeded, so the transcript is the only signal — and for
an unrecognized name there is no transcript, only a stderr warning that a
pipeline discarding stderr would lose.

Also relevant to the brief's question about mistaking a probe for reasoning
evidence: this file does **not** write probe output into the repository. All
output goes to stdout. The only filesystem writes on the path are inside
`Dir.mktmpdir` (`openclaw_comms_fixture.rb:377-411`, `:532-596`), which is
`/tmp`-rooted and removed at `:225`. Verified by `grep` for
`File.write`/`FileUtils`/`mkdir` across the harness and fixture: every hit is
under the tmpdir. No repo, cwd, or `$HOME` pollution. No finding.

### Lens: scalability and resource bounds

Reviewed, bounded. With no args, ten probes run sequentially, each building one
harness and closing it (`:159-165`). There is no retry and no network. Memory is
bounded by one harness at a time because each is closed before the next. The
selection list is the operator's `ARGV`; a repeated name just runs twice. `not
evidenced` for a measured ceiling: what would prove it is a timed run of all ten
probes — `not run` here, as the single-probe run already establishes the shape
and the full run is `not run` for budget reasons.

### Lens: maintenance and architecture

Reviewed. The probe is a **test-support consumer**, and that is its main
architectural fact: it reaches into `test/support` via a hand-rolled
`$LOAD_PATH.unshift` (`:18`) and requires `bundler/setup` (`:17`). It therefore
cannot run outside the checkout and is not part of the shipped surface — which
is consistent with `COVERAGE.md:109` classifying it as a harness rather than an
installed command, and with no gemspec naming it. No finding on that basis.

Two debts recorded:

- **E04-MNT-01** (`info`) — no `ensure harness.close` around `probe.call`
  (`:164`), unlike `tamoz-chat-sim:88-90`.
- **E04-MNT-02** (`info`) — the probe list is a frozen literal keyed by
  `OF-N` strings (`:53-157`) with no link back to
  `06-observed-chat-findings.md`; the file cites the doc in its header (`:4-5`)
  but nothing checks that the ten probes still correspond to the documented
  findings, and the doc additionally references `OF-1` (`:14`, model-dependent,
  deliberately absent) with no in-file marker that it was excluded on purpose.
  The header does explain it (`:14-15`), so this is a documentation-locality
  observation, not a defect.

### Tests and contracts

- `bundle exec ruby bin/tamoz-chat-probe OF-4` → exit 0, transcript printed (run).
- `bundle exec ruby bin/tamoz-chat-probe NOPE` → exit **0** with a stderr warning (run) — E04-COR-01 evidence.
- `ruby -Itest test/experience_harness_test.rb` → **14 runs, 81 assertions, 0 failures, 0 errors, 0 skips** (covers the shared harness; the probe script itself is not driven by it).
- A test asserting the probe's exit code for an unknown name: **not found**.
- A test asserting the probe writes nothing into the repo: **not found** (verified by reading the write sites instead).

### Findings

#### E04-COR-01 — an unknown probe name exits 0

| Field | Content |
|---|---|
| Severity | `minor` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `bin/tamoz-chat-probe:159-165` — `selected.each do |key| ... or (warn(...); next) end` with **no `exit`** anywhere in the file; the script ends at `:165`. Contrast `bin/tamoz-chat-sim:31` which uses `abort` (exit 1) for a missing credential |
| Test/contract evidence | Ran `bundle exec ruby bin/tamoz-chat-probe NOPE` → `unknown probe NOPE (have: ...)` on stderr, **exit 0**; ran `... OF-4` → exit 0 |
| Scanner signal | none (found by exercising the unknown-arg contract) |
| Independent judgment | Confirmed by running and by reading that the file has no `exit` call, so 0 is structural, not incidental. Confirmed the documented multi-probe form `bin/tamoz-chat-probe OF-3 OF-7` (`06-observed-chat-findings.md:677`) is the realistic caller. I did **not** find any gate in `Rakefile` or `script/` that consumes this exit code, which is why this is `minor` and not `major` — no current build depends on it |
| Root cause | Concise: the script was written as an interactive read-it-yourself transcript printer, so it never adopted a status contract; the only failure branch (`warn` + `next`) was added for friendliness and silently inherits Ruby's default 0 |
| Recommendation | Smallest credible action at the existing seam: track a `missing` flag in the `:161-162` branch and `exit 64` after the loop, or `abort` in that branch as `tamoz-chat-sim:31` already does. Two lines, no restructuring. |
| Disposition | Open, `minor`. |

#### E04-MNT-01 — no `ensure` around the harness for a raising probe

| Field | Content |
|---|---|
| Severity | `info` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `bin/tamoz-chat-probe:164` `probe.call` with no `begin/ensure`; contrast `bin/tamoz-chat-sim:88-90` `begin ... ensure harness.close end` |
| Test/contract evidence | `ruby -Itest test/experience_harness_test.rb` → 14 runs / 81 assertions / 0F (does not cover the probe loop) |
| Scanner signal | none |
| Independent judgment | Verified by reading both scripts. Recorded as a design fact rather than a defect: with the deterministic provider and `Dir.mktmpdir` cleanup (`openclaw_comms_fixture.rb:225`) the residual leak is an in-process object, not durable state |
| Root cause | Concise: the probe predates the sim's `ensure` and was not revisited when the sim added one |
| Recommendation | None required. If the probe ever runs in-process across many findings, wrap `:164` in `begin/ensure`. |
| Disposition | Accepted as `info`. |

#### E04-MNT-02 — probe list `OF-N` keys are not verified against the findings doc

| Field | Content |
|---|---|
| Severity | `info` |
| Confidence | `medium` |
| Status | `open` |
| Source evidence | `bin/tamoz-chat-probe:53-157` (ten keys); `:4-5` cites `06-observed-chat-findings.md`; `:14-15` explains `OF-1`'s deliberate absence |
| Test/contract evidence | A test linking probe keys to documented finding IDs: **not found** |
| Scanner signal | none |
| Independent judgment | Confirmed the ten keys and the doc citation. I did **not** enumerate every `OF-N` in the source doc to prove none is missing — that is the unverified half, hence `medium` |
| Root cause | Concise: the probe is a hand-maintained mirror of a doc, with the linkage carried only in a comment |
| Recommendation | None now. If a probe is added or removed, update the header list; a generated list would be the speculative path. |
| Disposition | Accepted as `info`. |

### Blind spots

- I ran one probe (`OF-4`), not all ten; the other nine share the same
  construction and print helpers, so the sampled evidence covers the mechanism,
  not each finding's assertion.
- `openclaw_comms_fixture.rb` was read at its write sites and its `model_factory`
  seam, not end to end (it is the shared fixture for several rows).
- I did not verify that the ten probes still **reproduce** their documented
  findings; the doc is from the chat-study package and re-litigating those
  findings is outside this row.

### Verdict

**IMPROVE** — critical 0, major 0, minor 1, info 2.

Stated honestly, this is a threshold-boundary row and I am recording the
judgment rather than hiding it. BAR.md sets `IMPROVE` at one critical/major **or
three or more** minor, and `PASS` "only after all six lenses and required
evidence are reviewed and no such threshold is met". With exactly one accepted
`minor` and no `major`, the literal rule is that the row reaches neither branch:
the `IMPROVE` threshold is not met, and a recorded open defect is not "no
threshold met" either.

I record **IMPROVE** because E04-COR-01 is a live defect against a documented
usage (`bin/tamoz-chat-probe OF-3 OF-7`, `06-observed-chat-findings.md:677`)
whose whole purpose is to be re-run after a fix — a probe harness that reports
success for a name it did not recognize is exactly the "exit zero after a failed
action" failure the brief asks this row to catch, and calling that `PASS` would
soften the bar to fit what I found. The coordinator should settle the
single-`minor` convention once for the whole brief; see "Coordinator
reconciliation" below, where E03 is recorded `PASS` with the same finding count
and the discrepancy is called out rather than silently resolved.

---

## E05 `bin/tamoz-chat-sim` — PASS

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `bin/tamoz-chat-sim` | 90 (read fully) | Interactive real-provider chat REPL |
| `test/support/experience_harness.rb` | 212 (read fully) | Shared harness |
| `docs/openclaw-chat-study-refresh/implementation-plan/05-experience-harness.md` | — | Harness contract |
| `test/experience_harness_test.rb:10` | — | Names the sim as the real-provider driver |

Entry seam: `require 'bundler/setup'` (`:21`), `$LOAD_PATH.unshift('../test/support')`
(`:22`), `preflight!` (`:27-37`, called at `:59`), then a stdin REPL
(`:68-90`).

### Behavior path

1. `:59` `preflight!`. `:28-29` resolves `provider = ENV.fetch('TAMOZ_PROVIDER',
   'deepseek')` and the matching credential name `"#{provider.upcase}_API_KEY"`.
   `:30-33` if that env var is empty → `abort` with an export hint (exit **1**).
   `:34-37` if the locale is not UTF-8 → a **warning**, not a failure.
2. `:62-63` `routing = ENV.fetch('TAMOZ_ROUTING', 'experimental').to_sym`, then
   `Harness.new(routing:)`.
3. `:64` prints `provider=#{harness.provider_label}`, which is `@provider/@model`
   (`experience_harness.rb:143`) — the operator sees which provider the REPL will
   actually call.
4. `:68-90` the REPL: blank lines skipped; `/quit`/`/exit` break; `/status`
   prints the projection; `/reply`, `/tap` dispatch; an unrecognized `/command`
   **warns** (`:81`) and continues; anything else is a user message.
5. `:88-90` `ensure harness.close` — the harness is closed on every exit path
   including `break` and an exception.

### Lens: correctness

Exercised: `env -u DEEPSEEK_API_KEY bundle exec ruby bin/tamoz-chat-sim </dev/null`:

```
Missing DEEPSEEK_API_KEY. Export it (the repo keeps DEEPSEEK_API_KEY in .env):
  export DEEPSEEK_API_KEY="$(sed -n 's/^DEEPSEEK_API_KEY[[:space:]]*=[[:space:]]*//p' .env)"
exit=1
```

Correct: a **non-zero** exit with an actionable, copy-pasteable remedy that names
the exact variable derived from the selected provider. No live call is attempted
before the credential check, so a missing key cannot produce a half-run.

The REPL loop's non-interactive contract is sound: `:69` `while (line =
$stdin.gets)` terminates cleanly on EOF, so
`printf '%s\n' '...' '/quit' | bundle exec ruby bin/tamoz-chat-sim` — the form
documented at `06-observed-chat-findings.md:701,709` — is well-supported. An
unknown `/command` warns and continues rather than exiting (`:81`), which is
right for an interactive REPL. No finding.

The one deliberate design choice worth recording: the sim **defaults to the
real provider** (`experience_harness.rb:69-75`, `model_factory || real_model_factory`)
and `:9`'s header says so explicitly. That is the correct default for a script
whose purpose is judging the experience — a deterministic default would make it
a plumbing tool wearing a simulation's name. It is recorded as `info` under
E05-MNT-01 in the sense that the file's honesty depends on the operator reading
the header, which is why `preflight!` and the `provider_label` banner exist.

### Lens: security and authority

Reviewed. This is the only row in this brief that **does** reach a real
provider, and it says so plainly: `:4-9` (header), `:28`, `:31-32`, `:64`.
`preflight!` (`:30-33`) fails closed before any model call. The credential is
read from the environment and never printed — the banner prints
`provider/model` (`experience_harness.rb:143`), not the key, and the abort
message names the **variable**, never its value (`:31-32`).

The provider's safety classification is explicit: `real_model_factory`
(`:151-153`) builds the client with `safety: :unsafe`. That is the harness
declaring these are exploratory runs; it is stated in the source rather than
hidden, and it is the same seam `install.md` and `agent-operator.md` describe for
operator-driven runs. The sim writes nothing to the repo, cwd, or `$HOME` — all
persistence is inside the fixture's `Dir.mktmpdir`
(`openclaw_comms_fixture.rb:214`, removed at `:225`). No finding.

The brief asks specifically whether E04/E05 can be mistaken for evidence of
agent reasoning. For E05 the answer is the opposite of a violation: it is the
script the repository designates for **real** evidence
(`experience_harness.rb:11-13`: "Only the transport is simulated... Judging the
experience or the answer requires a real provider (DeepSeek); a
deterministic-provider run on this harness is plumbing only and is never
intelligence evidence"). The sim cannot be run with the deterministic provider
except by editing the file, because it never passes `model_factory:` (`:63`). No
finding.

### Lens: reliability and durability

Reviewed. Three guarantees hold: (1) `ensure harness.close` (`:88-90`) runs on
`break`, on EOF, and on a raised exception; (2) a missing credential aborts
before construction (`:30-33`), so no partially wired harness exists; (3) the
REPL is line-oriented with no background thread of its own. The durable state
the harness creates lives in a tmpdir removed at process end
(`openclaw_comms_fixture.rb:225`), so an interrupted run does not leave a
half-written runtime directory behind. No finding.

A minor robustness note recorded as `info`: a non-UTF-8 locale produces a
**warning** and then proceeds (`:34-37`). That is the right choice for an
interactive tool (the operator may not control their shell), and the message
names the fix. It is not a defect.

### Lens: observability and evidence

Reviewed, and this is the strongest of the ten rows. The operator sees: the
provider/model banner (`:64`), the meta-command legend (`:65`), the user line
(`:83`), a tagged card line per reply (`:48` `🤖 [#{tag}]`), buttons when
present (`:49`), `(no reply)` rather than silence (`:41`), and a full
`/status` projection (`:75`). `:81` surfaces an unknown command on stderr
instead of ignoring it.

Critically for the audit's evidence rules, this script cannot be confused with
the deterministic probe: they are separate files with separate defaults and
separate headers, and the sim prints the live provider identity on every run.
The `provider=deepseek/deepseek-chat` banner is precisely the artifact that makes
a transcript attributable to a real model rather than to a fixture. No finding.

### Lens: scalability and resource bounds

Reviewed, bounded. One message at a time, one harness for the process lifetime
(`:63`), closed once at `:89`. No retry, no queue, no accumulation across turns
except inside the harness's own durable store. The loop is bounded by stdin.
`not evidenced` for a ceiling on harness memory growth across many turns — what
would prove it is a long piped session; `not run` here because it requires a live
provider, which this brief forbids.

### Lens: maintenance and architecture

Reviewed. Like E04, this is a checkout-only harness: `bundler/setup` (`:21`) plus
a `test/support` load-path unshift (`:22`), no gemspec, correctly classified by
`COVERAGE.md:110` as a harness. It shares `experience_harness.rb` with E04, and
`test/experience_harness_test.rb:10` names the sim as the driver the shared
harness serves — so the harness is exercised by the test suite while the sim's
REPL wrapper is not. That is a reasonable split: the valuable shared logic is
tested, the thin wrapper is not, and the wrapper is 90 lines with one `while`
loop.

The file's documentation is accurate against its own behavior in every respect I
checked: the three meta commands listed at `:14-17` are the three handled at
`:74-81`, and the non-interactive claim at `:19` is true.

Recorded as `info` (**E05-MNT-01**): the sim is not covered by
`test/documentation_surface_test.rb` and has no test of its own; its correctness
rests on the shared harness's suite plus the abort path. Given the file is a
thin wrapper and `preflight!` was verified by running it, this is below the
finding bar — it is noted so the coordinator can see the coverage boundary.

### Tests and contracts

- `env -u DEEPSEEK_API_KEY bundle exec ruby bin/tamoz-chat-sim </dev/null` → abort, **exit 1**, actionable message (run).
- `ruby -Itest test/experience_harness_test.rb` → **14 runs, 81 assertions, 0 failures, 0 errors, 0 skips**.
- A live-provider REPL session: **not run** — forbidden by this brief ("NEVER call a real LLM or a live provider").
- A test driving the sim's REPL loop or `preflight!`: **not found**.

### Findings

None.

### Blind spots

- The live path is **not run** by instruction. The credential gate, the REPL
  loop, and the shutdown were verified by reading (`:27-37`, `:68-90`) and the
  abort path by running. Everything downstream of a successful `preflight!`
  (an actual model turn, `render`, `/tap`) is read-only evidence here.
- `experience_harness.rb`'s `wire_delivery_pipeline` and the fixture's gateway
  wiring were read but not exercised in this row; `test/experience_harness_test.rb`
  exercises them (14 runs green).

### Verdict

**PASS** — critical 0, major 0, minor 0, info 1.

---

## E06 `bin/tamoz-eval` — PASS

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `bin/tamoz-eval` | 10 (read fully) | Repository wrapper for the verifier |
| `gems/tamoz-evals/exe/tamoz-eval` | 6 | The installed executable it mirrors |
| `gems/tamoz-evals/lib/tamoz/evals/cli.rb` | 80 | The shared CLI |
| `documentation/guides/evaluation.md:12-13` | — | Names this wrapper as a supported entry |

Entry seam: a `$LOAD_PATH.unshift` of two repo-relative gem libs (`:4-7`), then
the **identical two lines** the installed executable has (`:8`, `:10`).

### Behavior path

1. `:4-7` `$LOAD_PATH.unshift(File.expand_path("../gems/tamoz-core/lib", __dir__),
   File.expand_path("../gems/tamoz-evals/lib", __dir__))`.
2. `:8` `require "tamoz/evals"` — resolves from the unshifted `tamoz-evals/lib`.
3. `:10` `exit Tamoz::Evals::CLI.run(ARGV)` — the **same call** as
   `gems/tamoz-evals/exe/tamoz-eval:6`.

### Lens: correctness

Exercised: `ruby bin/tamoz-eval --help` from the repo root → the same usage
output as the installed executable, exit 0. `ruby bin/tamoz-eval` (no args) →
exit **64**. `ruby bin/tamoz-eval verify /tmp/does-not-exist.json` → exit **2**.
Every result is byte-identical to E02's results, which is the property that
matters: the wrapper and the shipped executable reach the same `CLI.run`.

**No double-shell, no wrong-gem risk.** The wrapper does not `exec`, `spawn`,
`system`, or `require` the `exe/` file. `grep` for shell-out primitives in
`bin/tamoz-eval` returns nothing; the file is 10 lines and calls the library
directly (`:8`, `:10`). There is no process boundary to loop through and no
second gem named `tamoz-eval` to resolve to by accident: the unshift puts the
repo's own `tamoz-evals/lib` **first**, ahead of any installed `tamoz-evals`.
No finding.

### Lens: security and authority

Reviewed. The wrapper adds exactly one thing over E02: a repo-relative load
path. That path is computed from `__dir__` (`:5-6`), not from `Dir.pwd` or an
environment variable, so running the wrapper from any cwd still loads the
**repo's** gem rather than a planted one in the current directory. That is the
secure choice and it is worth stating explicitly: a wrapper that unshifted a
cwd-relative path would be a load-path hijack vector. This one does not.

`$LOAD_PATH.unshift` places the repo's libs **ahead** of the default path, which
is the intended precedence for a development wrapper. The verified ⊂ authority
claim: it grants no capability the installed command lacks — same `CLI.run`, same
argv, same exit codes. No finding.

### Lens: reliability and durability

Reviewed. The wrapper is deterministic and stateless: same argv in, same
behavior out, no durable state, no retry, no timeout. Failure of the load path
would be a `LoadError` (non-zero), not a silent success, because `require` at
`:8` raises rather than returning nil. No finding.

### Lens: observability and evidence

Reviewed. The wrapper contributes no output of its own — it inherits the CLI's
stdout/stderr split exactly (`cli.rb:34-36` `out:`/`err:` defaults). A caller
cannot distinguish the wrapper's output from the installed command's, which is
the correct property for a mirror. No finding.

### Lens: scalability and resource bounds

`not evidenced`. Ten lines, no loop, no buffering, no pool; all bounded work
belongs to the CLI it calls (`cli.rb:40-41`, sequential over argv). What would
prove it: a resource behavior introduced by the wrapper itself — there is none.

### Lens: maintenance and architecture

Reviewed. This is the cleanest wrapper shape in the ten rows. The design is
explicitly documented as a supported surface: `evaluation.md:12-13` says the
verifier "is invoked as `rbenv exec bundle exec tamoz-eval` from the checkout,
or directly as `bin/tamoz-eval`". Two entry points to one `CLI.run`, with the
wrapper's only difference being the load path it needs — that is honest
duplication of two lines, not a second implementation.

No gem conflict: the wrapper unshifts `tamoz-core` and `tamoz-evals`
(`:5-6`), which are exactly the two the command needs — `tamoz-evals` depends
only on `tamoz-core` (`tamoz-evals.gemspec:13-15`). The dependency list in the
wrapper matches the declared dependency, so the wrapper cannot silently
compensate for a missing gem dependency. No finding.

### Tests and contracts

- `ruby bin/tamoz-eval --help` → exit 0, usage (run; identical to E02).
- `ruby bin/tamoz-eval` → exit 64 (run).
- `ruby bin/tamoz-eval verify /tmp/does-not-exist.json` → exit 2 (run).
- A test asserting the wrapper and `exe/tamoz-eval` agree: **not found**.
  (The agreement was verified by running both, not by a test.)

### Findings

None.

### Blind spots

- No test pins the wrapper/executable equivalence. I established it by running
  both and comparing output; a regression that let them drift would not be caught
  by the suite.
- `script/generate_release_evaluation_manifest` and `script/release_rehearsal`
  reference `bin/tamoz-eval`; I did not trace those callers, as they belong to
  the `S01` row.

### Verdict

**PASS** — critical 0, major 0, minor 0, info 0.

---

## E07 `bin/tamoz-eval-runner` — PASS

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `bin/tamoz-eval-runner` | 9 (read fully) | Repository wrapper for the runner |
| `gems/tamoz-evals-runner/exe/tamoz-eval-runner` | 6 | Installed executable |
| `gems/tamoz-evals-runner/lib/tamoz/evals/runner/cli.rb` | 136 | The shared CLI |

Entry seam: `$LOAD_PATH.unshift` of **two** repo-relative libs (`:4-5`), then the
same two lines as E03 (`:7`, `:9`).

### Behavior path

1. `:4` unshifts `../gems/tamoz-evals-runner/lib`.
2. `:5` unshifts `../gems/tamoz-evals/lib`.
3. `:7` `require "tamoz/evals/runner"`; `:9` `exit Tamoz::Evals::Runner::CLI.run(ARGV)`.

### Lens: correctness

Exercised: `ruby bin/tamoz-eval-runner` → exit **64** with
`expected: tamoz-eval-runner scorecard agent-smoke --input-manifest PATH` on
stderr. `... scorecard agent-smoke --input-manifest /tmp/nope.json` → exit **3**
with `runner input manifest is required`. Both match E03 exactly.

**No double-shell.** The wrapper does not invoke `exe/tamoz-eval-runner`; it
requires the library and calls `CLI.run` directly (`:7`, `:9`). No `exec`,
`spawn`, or `system`. No infinite loop, no wrong-gem risk — and unlike E06, this
wrapper's precedence question is more load-bearing because its process also needs
`tamoz-evals` for the shared exit constants (`cli.rb:10-14`). Both are unshifted
(`:4-5`) ahead of any installed copy, so the repo's versions win. Verified by
running from the repo root.

One structural observation, recorded as `info`: the wrapper unshifts only
`tamoz-evals-runner` and `tamoz-evals`, relying on the **installed/bundled**
versions of the other ~15 runtime dependencies (`tamoz-evals-runner.gemspec:20-38`)
to resolve `tamoz/agent`, `tamoz/sqlite`, and the rest at require time. That is
correct under `bundle exec` (the Gemfile wires every gem by path, `Gemfile:10-29`)
and is how the command was verified. It means the wrapper is a
**bundle-context** entry point rather than a bare-`ruby` one — which the
documented form respects (`evaluation.md:22-23` uses `rbenv exec bundle exec`).
Not a finding; recorded so the coordinator does not mistake the wrapper for a
standalone script.

### Lens: security and authority

Reviewed. Same `__dir__`-relative load path as E06 (`:4-5`), so the wrapper
cannot be hijacked by a planted gem in the cwd. It grants no authority the
installed command lacks: same `CLI.run`, same argv, same scripted-adapter
pinning (`tamoz/evals/runner/cli.rb:70-84`) which is where the real trust
decision lives — and that decision is unchanged by the wrapper. No finding.

### Lens: reliability and durability

Reviewed. Stateless, deterministic, no retry, no durable state of its own. A
load failure raises `LoadError` (non-zero), never a silent zero. The exit codes
are the shared ones (`cli.rb:10-14`) so the wrapper cannot report a different
code than the installed executable. No finding.

### Lens: observability and evidence

Reviewed. Inherits the runner's stdout/stderr split (`cli.rb:108`, `:111`,
`:114`) with no output of its own. The `usage_message` reaching stderr with exit
64 (rather than stdout/0) is E03-ERR-01's behavior, faithfully mirrored — the
wrapper is not the place to fix it, and it correctly does not diverge. No
finding.

### Lens: scalability and resource bounds

`not evidenced`. Nine lines with no loop, pool, or buffer; one scorecard or
treatment per process (`cli.rb:29`, `:63`), which is the called CLI's bound, not
the wrapper's.

### Lens: maintenance and architecture

Reviewed. Two entry points to one `CLI.run`, with the two unshift lines as the
only difference from `exe/tamoz-eval-runner` — the same honest shape as E06, and
no gem is duplicated or reimplemented. `README.md:153` and
`evaluation.md:22-23` document the command, and both name it through
`bundle exec`, matching E07's bundle-context requirement noted above. No finding.

### Tests and contracts

- `ruby bin/tamoz-eval-runner` → exit 64, stderr usage (run).
- `ruby bin/tamoz-eval-runner scorecard agent-smoke --input-manifest /tmp/nope.json` → exit 3 (run).
- `ruby -Itest test/documentation_surface_test.rb` → 9 runs / 87 assertions / 0F (does not cover `evaluation.md`).
- A test asserting the wrapper and `exe/tamoz-eval-runner` agree: **not found**.

### Findings

None.

### Blind spots

- No test pins the wrapper/executable equivalence (same as E06).
- The successful scorecard path is **not run** (needs an external pinned
  manifest and corpora by design; `evaluation.md:36-38`).

### Verdict

**PASS** — critical 0, major 0, minor 0, info 0.

---

## E08 `bin/tamoz-stream-subscriber` — IMPROVE

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `bin/tamoz-stream-subscriber` | 99 (read fully) | Standalone Channel-B subscriber launcher |
| `gems/tamoz-stream/lib/tamoz/stream/sse_transport.rb` | — (constructor, `stop`, `require_http_url!` read) | SSE transport |
| `gems/tamoz-stream/lib/tamoz/stream/outcome_subscriber.rb` | — (`run` read) | Subscription loop |
| `documentation/adr/approval-policy-redesign/05-implementation-plan.md:700-704` | — | Names this launcher's relay injection |

Entry seam: `$LOAD_PATH.unshift(*Dir[File.expand_path("../gems/*/lib", __dir__)])`
(`:8`) — a **glob of every gem lib**, unlike E06/E07's explicit pairs.

### Behavior path

1. `:8` unshifts all `gems/*/lib`. `:10-15` require `logger`, `optparse`,
   `tamoz/agent`, `tamoz/sqlite`, `tamoz/stream/live_learning_handlers`,
   `tamoz/stream/sse_transport`.
2. `:17-35` the option grammar; `:36` `parser.parse!(ARGV)`.
3. `:38-42` the required-key gate: `tenant`, `database`, `events_url`,
   `subscriber_token`, `approval_ttl_seconds` — else `warn parser; exit 2`.
4. `:44-46` open the log; optionally `require File.expand_path(options.fetch(:approval_relay))`.
5. `:48-75` bind the SQLite adapter, approval receipt store, memory engine,
   `LiveLearningHandlers`, and `OutcomeSubscriber` over a shared durable store.
6. `:76` `SseTransport.new(endpoint:, logger:)`.
7. `:77-83` `stopping` flag plus `trap("TERM")` and `trap("INT")`, both calling a
   lambda that sets the flag and calls `transport.stop`.
8. `:85-94` the run loop: `subscriber.run(transport:)` repeatedly; a rescued
   `StandardError` is logged and followed by `sleep(1)` unless stopping.

### Lens: correctness

Exercised the argument contract:

- No args → `warn parser`, exit **2** — correct.
- `--help` → usage on stdout, exit **0** — correct.
- `--bogus` → `OptionParser::InvalidOption` backtrace, exit **1**.
- `--events-url ftp://x/y` → `TransportError: SSE endpoint must be an HTTP or
  HTTPS URL` (`sse_transport.rb:164`) with a **raw backtrace**, exit 1.
- `--database /nonexistent-dir/x.sqlite3` → `Tamoz::SQLite::PermissionError`
  with a **raw backtrace**, exit 1.
- `--approval-relay` pointing at a file that defines nothing →
  `ArgumentError: approval relay file must define build_approval_relay`, exit 1.

Every failure is non-zero and no failure path exits 0 — the exit contract is
sound. The defect is the **presentation**: this launcher never installs a
rescue ladder, so every configuration error surfaces as an uncaught exception
with a full Ruby backtrace (`:46`, `:48`, `:76` are unguarded) instead of the
`tamoz: <message>` one-liner the CLI family uses (`cli.rb:132`, `:141`). This is
recorded as part of **E08-REL-01** below, whose major defect is the retry loop;
the backtrace noise is the same seam's lesser symptom.

Also verified correct: the required-key gate (`:38-42`) uses
`options[key] && !options[key].to_s.empty?`, so `--tenant ""` is rejected — a
deliberate empty-string-safe check rather than a bare truthiness test.

### Lens: security and authority

Reviewed. The launcher is careful in the places that matter:

- The approval relay is **operator-supplied** (`:29-31`) and is required
  explicitly, never discovered from the environment or the workspace. The ADR
  records this as the deliberate design (`05-implementation-plan.md:700-704`).
- `requre File.expand_path(options.fetch(:approval_relay))` (`:46`) resolves the
  path relative to the cwd, which is the operator's cwd — not the workspace
  under repair. It is an operator-executed `require` of an operator-named file;
  the capability granted is exactly the operator's own.
- The subscriber credential arrives as `--subscriber-token` (`:22-24`) and is
  passed to `OutcomeSubscriber` (`:74`) and thence the transport
  (`sse_transport.rb:170` refuses an empty credential). The token is **not**
  logged: the startup line (`:86`) prints `tenant` and `endpoint` only.
- `SseTransport` refuses a non-HTTP(S) endpoint (`:164`), so the credential
  cannot be sent over a non-HTTP scheme.

The one authority observation: the shared SQLite path is the subscriber's
durable authority (`:4-6` header), and the launcher takes it directly from
`--database` (`:20`) with no `0700`/ownership check of its own. The
`Tamoz::SQLite::Adapter` performs its own verification
(`database_file.rb:87` `verify_parent!`, observed raising on a missing parent),
so the boundary is enforced one layer down rather than being absent. Not a
finding; recorded as reviewed with the enforcement located.

### Lens: reliability and durability

Reviewed, and this is the row's **major** defect.

**E08-REL-01 — an unreachable or repeatedly failing endpoint retries forever
with no backoff, no attempt ceiling, and no way for a supervisor to distinguish
"working" from "endpoint has been down for a week".**

`bin/tamoz-stream-subscriber:85-94`:

```ruby
until stopping
  begin
    subscriber.run(transport:)
  rescue StandardError => error
    logger.error("subscriber error=#{error.class}: #{error.message}")
    sleep(1) unless stopping
  end
end
```

Two independent unbounded behaviors compound here:

1. **The `until stopping` loop has no exit other than a signal.** A transport
   that fails on every attempt keeps the process alive forever.
2. **`sleep(1)` is a fixed delay, not a backoff.** There is no attempt counter,
   no cap, and no jitter.

Measured, against a deliberately dead endpoint
(`--events-url http://127.0.0.1:1/e`), logging to a file:

```
$ timeout 30 bundle exec ruby bin/tamoz-stream-subscriber \
    --tenant t --database ... --events-url http://127.0.0.1:1/e \
    --subscriber-token tok --approval-ttl-seconds 60 --log /tmp/.../sub.log
$ grep -c "SSE reconnect error" /tmp/.../sub.log
8
```

Eight full reconnect attempts logged in 30 seconds, each `Errno::ECONNREFUSED`,
with the process still running when `timeout` killed it. The log line count is
the proof that the loop never terminates on its own. The retry rate is
~1/second sustained, so a subscriber pointed at a decommissioned endpoint will
emit roughly 86,400 log lines per day and hold its SQLite handle open
indefinitely. Under the repo's own rotation conventions this is the exact shape
that fills a disk, and it is the shape a supervisor cannot see: the process is
**alive and healthy-looking**, so systemd/launchd/runit will never restart it and
`process up` is not evidence the subscriber is subscribed.

The severity is `major`, not `critical`: no unsafe action, no authority bypass,
and no data loss — the cursor store is durable (`outcome_subscriber.rb:73`
reads it before each pass) and a `cursor_expired` control triggers an audited
resnapshot rather than an implicit one (`:103-111`). What is lost is liveness
visibility and disk/log bounds. That is a material operational cost with no
safety violation, which is BAR.md's `major`.

Contrast the contrast within this same brief: **E09's** server has a `stop` path
(however broken) and the repo's CLI family has a full rescue ladder
(`cli.rb:118-142`). E08 is the only launcher here with no ceiling at all.

### Lens: observability and evidence

Reviewed. What exists is good: a startup line naming `tenant` and `endpoint`
(`:86`), a per-failure `logger.error` with the exception class and message
(`:91`), and a `--log PATH` option (`:32-34`) defaulting to stdout (`:17`) so a
supervisor can capture it. The secrets discipline is correct — the credential is
never logged.

What is missing is the signal that would make E08-REL-01 visible: there is no
attempt counter, no "N consecutive failures" escalation, no distinct log level
on transition from healthy to failing, and no exit on a sustained outage. An
operator reading the log sees an undifferentiated stream of identical warnings
with no indication of how long the condition has held. That absence is the
observability half of the same finding, and it is why a fix at the loop seam
(`:85-94`) addresses both lenses at once.

One positive: because the cursor is durable and read before every pass, a
subscriber restarted after a fix resumes from its committed position rather than
re-delivering — so the retry loop is wasteful, not corrupting. Verified by
reading `outcome_subscriber.rb:72-86`.

### Lens: scalability and resource bounds

Reviewed, and this is where E08-REL-01 lands hardest. Retry rate is fixed at
~1/s with no backoff and no ceiling (measured above: 8 attempts / 30 s). Log
growth is therefore unbounded at roughly one line per second per dead endpoint.
There is no `max_attempts`, no exponential delay, no circuit breaker, and no
`--max-retries` option in the grammar (`:18-35`). Memory is bounded (one
transport, one subscriber). The unbounded dimensions are **process lifetime**,
**log volume**, and **reconnect count**; all three are consequences of the same
missing ceiling. No separate finding — this lens is the bound that E08-REL-01
names.

### Lens: maintenance and architecture

Reviewed. The launcher is a straightforward composition script and its parts are
individually clean: `optparse` grammar (`:18-35`), a required-key gate
(`:38-42`), dependency construction (`:48-75`), and a run loop (`:85-94`). The
`$LOAD_PATH` glob (`:8`) is broader than E06/E07's explicit pairs — it unshifts
**every** gem's lib — which is the right choice here because this launcher
genuinely spans `tamoz-agent`, `tamoz-sqlite`, and `tamoz-stream` and would
otherwise need a long explicit list. It is still `__dir__`-relative, so it is
cwd-hijack-safe.

Two structural notes recorded as `info`:

- **E08-MNT-01** — `:46` `require File.expand_path(options.fetch(:approval_relay))`
  is a `require` of an operator path resolved against the **cwd**. It works, but
  the error for a bad path is a bare `LoadError` backtrace, and the file's
  header does not say the path is cwd-relative. `not evidenced` as a defect: no
  doc promises otherwise.
- **E08-MNT-02** — nothing in this brief's scope tests the launcher. `grep` for
  `bin/tamoz-stream-subscriber` across `test/` finds only ADR prose references
  (`documentation/adr/approval-policy-redesign/*`), never a test. The
  `LiveLearningHandlers` and `OutcomeSubscriber` classes it wires are tested at
  the gem row; the **launcher's loop** is not. That is the coverage hole that
  let E08-REL-01 persist, and it is recorded so the coordinator can weight the
  finding's test evidence correctly.

### Tests and contracts

- No args → exit 2, usage on stderr (run).
- `--help` → exit 0, usage on stdout (run).
- `--bogus` → `OptionParser::InvalidOption` backtrace, exit 1 (run).
- `--events-url ftp://x/y` → `TransportError` backtrace, exit 1 (run).
- `--database /nonexistent-dir/x.sqlite3` → `PermissionError` backtrace, exit 1 (run).
- `--approval-relay <file defining nothing>` → `ArgumentError` backtrace, exit 1 (run).
- Dead endpoint, 30 s → 8 logged `SSE reconnect error`, process still running (run) — **E08-REL-01 evidence**.
- A test covering `bin/tamoz-stream-subscriber`: **not found**.

### Findings

#### E08-REL-01 — the subscriber retries a failing endpoint forever with a fixed delay and no ceiling

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `bin/tamoz-stream-subscriber:85-94` — `until stopping` with a single `rescue StandardError` → `sleep(1)`, no attempt counter, no cap, no backoff; the option grammar `:18-35` offers no retry/ceiling flag; the only loop exit is the `stopping` flag set by the traps at `:78-83` |
| Test/contract evidence | Ran against a dead endpoint for 30 s: `grep -c "SSE reconnect error"` → **8**, process still alive when `timeout` killed it. A test for this launcher: **not found** (only ADR prose mentions it) |
| Scanner signal | none (found by tracing the run loop and then measuring it) |
| Independent judgment | Confirmed by running, not by reading alone: the loop does not terminate and the rate is ~1/s. Confirmed the cursor store makes this wasteful rather than corrupting (`outcome_subscriber.rb:72-86` reads the durable cursor before each pass), which is what caps severity at `major`. I did **not** find an external supervisor contract promising a bounded retry — the launcher's own header claims only that the worker and subscriber "share one durable authority" (`:4-6`), so no doc promise is broken; the gap is that the process lies about its own health |
| Root cause (five whys) | (1) A subscriber pointed at a down endpoint loops forever at ~1/s. (2) The loop's only exit is a signal, and the delay is a fixed `sleep(1)`. (3) The launcher was written for the happy path — the composition (adapter, handlers, transport) got the attention and the loop got four lines. (4) No test drives the launcher, so nothing forced a decision about the failure path; the gem-level tests cover `OutcomeSubscriber` and `SseTransport` individually and never compose them under a failing endpoint. (5) There is no declared contract for "how long may a subscriber fail before it must stop or escalate" — the contract that would prevent recurrence is a bounded retry policy at the launcher seam, tested by a dead-endpoint case |
| Recommendation | Smallest credible action at the existing seam: bound the loop at `:85-94` — count consecutive failures, warn with the count, and exit non-zero after a ceiling (a `--max-consecutive-failures` option defaulting to a finite value fits the existing grammar at `:18-35`). A fixed `sleep(1)` can stay; the ceiling is the property that is missing. No new class, no supervision framework. |
| Disposition | Open, `major`. Requires an independent challenge before closure per BAR.md. |

#### E08-MNT-01 — the approval-relay path is cwd-relative and undocumented

| Field | Content |
|---|---|
| Severity | `info` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `bin/tamoz-stream-subscriber:29-31` (option), `:46` `require File.expand_path(options.fetch(:approval_relay))` |
| Test/contract evidence | Ran with a file defining nothing → `ArgumentError: approval relay file must define build_approval_relay`, exit 1 |
| Scanner signal | none |
| Independent judgment | Verified the resolution is cwd-relative by reading. Recorded as a design fact: the operator's cwd is the operator's own context, so this is not an authority widening. `not evidenced` that any doc promises an absolute path |
| Root cause | Concise: `File.expand_path` with one argument resolves against the cwd, and the header does not state it |
| Recommendation | None required. If the option is documented for operators, say the path resolves against the cwd — or drop `File.expand_path` and require an absolute path explicitly. |
| Disposition | Accepted as `info`. |

#### E08-MNT-02 — the launcher has no test

| Field | Content |
|---|---|
| Severity | `info` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `grep` for `bin/tamoz-stream-subscriber` across `test/` finds only ADR prose |
| Test/contract evidence | A test: **not found** |
| Scanner signal | none |
| Independent judgment | Verified by search. Recorded as a coverage fact rather than a standalone finding — the defect it enabled is E08-REL-01, and recording a separate "missing test" finding would double-count the same gap |
| Root cause | Concise: the launcher was treated as operator glue and tested only through its component gems |
| Recommendation | The dead-endpoint case recommended in E08-REL-01 would be the first test; no separate action. |
| Disposition | Accepted as `info`, folded into E08-REL-01's evidence. |

### Blind spots

- A **live** Channel-B SSE endpoint is not available and would be a network
  dependency; the transport's success path (`sse_transport.rb:119-158`) was read,
  not run. Everything measured here is the failure path.
- The approval relay contract (`build_approval_relay(approval_state:)`) was read
  at `:53-59`; I did not exercise a **working** relay, as it needs a real
  approval receipt flow.
- `LiveLearningHandlers` internals belong to the `tamoz-stream` gem row.

### Verdict

**IMPROVE** — critical 0, major 1, minor 0, info 2. One `major` finding meets
the BAR.md threshold.

---

## E09 `bin/tamoz-stream-worker` — IMPROVE

### Scope and source map

| File | Lines | Role |
|---|---|---|
| `bin/tamoz-stream-worker` | 144 (read fully) | Supervised episode-worker gRPC launcher |
| `gems/tamoz-stream/lib/tamoz/stream/worker_server.rb` | 88 (read fully) | `GRPC::RpcServer` lifecycle |
| `test/stream_worker_server_test.rb` | 141 (read fully) | The launcher's only test |
| `docs/model-call-boundary-review-2026-08-26/03-graph-solidity-and-target-topology.md:144-150` | — | Confirms no `--graph FILE` route |

Entry seam: `$LOAD_PATH.unshift(*Dir[File.expand_path("../gems/*/lib", __dir__)])`
(`:19`), the option grammar (`:39-65`), a required-key gate (`:67-70`), then the
full port composition (`:72-141`) and `server.run` (`:144`).

### Behavior path

1. `:19` unshift all `gems/*/lib`; `:21-32` require `optparse`, `json`,
   `tamoz/stream` (the umbrella, for dependency order), the episode-worker /
   worker-server / store / decision-builder subfiles, `tamoz/agent`, `tamoz/sqlite`.
2. `:34-38` defaults: `worker_version: "0.1.0.alpha.1"`,
   `lane_config: "fast=flash,deep=pro,batch=flash"`, `tenant: nil`.
3. `:39-64` grammar: `--profile`, `--database`, `--tenant`, `--socket`,
   `--port`, `--worker-version`, `--lane-config`, `--skills-source`.
4. `:65` `parser.parse!(ARGV)`; `:67-70` require `profile`, `database`,
   `tenant` else `warn parser; exit 2`.
5. `:72-79` build the lane config, raising on a malformed pair.
6. `:84` `Profile.preview(options.fetch(:profile))` — validation-only load.
7. `:86-96` SQLite adapter, memory engine, situation recaller, caller.
8. `:101` optionally parse `--skills-source` JSON; `:102-122` compose
   `EpisodeNodes` with the frame-builder factory, the **journaled** model-call
   factory (`EpisodeModelCall` over a resolved-role transport, `:107-117`), the
   decision builder, and the skills source.
9. `:123` `EpisodeGraph.build(checkpointer:, nodes:)`; `:124-135`
   `EpisodeWorker` + `EpisodeRunner` + `bind_runner`.
10. `:137-141` `WorkerServer.new(worker:, socket:, port:)`.
11. `:142-144` `trap("TERM") { server.stop }`, `trap("INT") { server.stop }`,
    then `server.run`.

### Lens: correctness

The composition is correct and matches the documented contract. Verified:

- No-args gate: `--profile`+`--database`+`--tenant` required, else `warn parser;
  exit **2**` (`:67-70`) — correct.
- `--help` → usage on stdout, exit **0**.
- A **valid** profile + `--port 0` + `--socket X` → `WorkerServer::ServerError:
  choose exactly one of socket or port` (`worker_server.rb:31-33`), exit 1.
- A malformed `--lane-config bogus` → `ArgumentError: malformed lane config:
  bogus` (`:75`), exit 1.
- Missing profile file → `ValidationError: .../nope.yaml: profile file does not
  exist` (`secure_file.rb:65`), exit 1.

The launcher really serves. With a valid profile I built in `/tmp` and
`--socket`, the UDS listener appeared:

```
$ ls -l /tmp/tamoz-e09/worker.sock
srwxr-xr-x@ 1 ghassan wheel 0 Sep 15 11:05 /tmp/tamoz-e09/worker.sock
```

and the process ran until signalled, with no stray descendants
(`pgrep -lf tamoz-stream-worker` showed exactly the one launcher PID). The
"no `--graph FILE` on any production route" claim in the header (`:4-6`) is
accurate: `grep` of the grammar finds no `--graph`. The header's claim that the
graph is compiled in process is true at `:123`.

The `--skills-source` fail-closed default is also correct: when unset,
`skills_source || {}` (`:119`) means any episode requesting a skill ref fails
closed at `build_frame`, exactly as the comment at `:97-100` states.

**The defect is the shutdown path** — see E09-REL-01 under reliability.

### Lens: security and authority

Reviewed, and the launcher's authority story is the strongest of the ten. The
Profile is the sole model authority: `Profile.preview` (`:84`) is a
validation-only load, and `model_call_factory` (`:107-117`) resolves the wire's
role name through `ModelCall.resolve_role(profile, ...)` **fail-closed** before
any model call, then builds the client from the resolved role
(`:109-115`). The model name and provider therefore come from operator config,
never from the wire. `EpisodeModelCall` (`:116`) routes the call through the
durable effect journal, satisfying the AGENTS.md rule that a model call inside a
graph node goes through `EffectDispatcher`. The `endpoint` field is only honored
when non-empty (`:114`), so a role with no endpoint uses the provider default
rather than an empty URL.

On the bind boundary: `WorkerServer#address` (`:83-85`) binds
`unix://#{@socket}` for production or `0.0.0.0:#{@port || 0}` for development,
both `:this_port_is_insecure` (`:80`). The header is honest about this (`:16-18`,
`:49`): "mTLS at the socket boundary" is the deployment's job and the code
"make[s] no claim about the transport". Recorded as a verified design fact, and
the `--port` path is documented as development-only. No authority widening by
the launcher.

**A real omission worth naming**, recorded as `info` under E09-MNT-01: the
grammar does not require **either** `--socket` or `--port`. The launch proceeds
all the way through profile load, adapter open, and the entire port composition
before `WorkerServer.new` (`:137`) rejects the both-or-neither case
(`worker_server.rb:31-33`). So `... --tenant acme` with no transport flag does
substantial work — opening SQLite, building the memory engine — before failing.
It fails correctly and non-zero, so it is not a correctness defect; it is
wasted work on an invalid invocation, and it is the same "validate late" shape
the `:67-70` gate avoids for its three keys.

### Lens: reliability and durability

Reviewed, and this is the row's **major** defect — worse than E08's, because
E09's failure is in the *normal* shutdown path rather than an edge case.

**E09-REL-01 — SIGTERM and SIGINT both abort the worker with SIGABRT (exit 134)
instead of stopping it, so a supervised restart is always a crash-restart.**

`bin/tamoz-stream-worker:142-143` installs:

```ruby
trap("TERM") { server.stop }
trap("INT")  { server.stop }
```

`WorkerServer#stop` (`worker_server.rb:64-73`) calls `@server.stop` on the gRPC
server. `GRPC::RpcServer#stop` synchronizes internally, and a Ruby `trap`
context forbids `Mutex#synchronize`. Measured, twice, on both signals:

```
$ bash run.sh &            # valid profile, --socket /tmp/tamoz-e09/worker.sock
$ kill -TERM $!
$ wait $!
exit_code_under_SIGTERM=134     # 128 + 6 = SIGABRT
$ grep -c "ThreadError" out2.log
1

$ kill -INT $!
$ wait $!
exit_code_under_SIGINT=134
$ grep -c "ThreadError" out3.log
1
```

The captured stderr:

```
grpc-1.83.0.../rpc_server.rb:250:in `synchronize': can't be called from trap context (ThreadError)
	from .../worker_server.rb:67:in `stop'
	from bin/tamoz-stream-worker:142:in `block in <main>'
...
WARNING: All log messages before absl::InitializeLog() is called are written to STDERR
F0000 ... completion_queue.cc:345] Check failed: completed_head.next == reinterpret_cast<uintptr_t>(&completed_head)
*** Check failure stack trace: ***
...
Abort trap: 6
```

So the sequence is: the trap raises `ThreadError` inside the gRPC completion
queue's callback, gRPC's C core then fails its own `completion_queue` assertion,
and the process dies on `abort()`. This is **deterministic on both signals** —
two runs, two signals, `134` both times.

Operational consequence: the launcher can never exit cleanly. Every deployment
restart — `systemctl restart`, a container stop, a `kill -TERM` from a
supervisor, Ctrl-C at a terminal — is recorded by the supervisor as a crash
(`SIGABRT`), not a graceful stop. Supervisors that implement restart backoff or
crash-loop alerting on abnormal termination will misclassify every planned
restart; ones that escalate on repeated abnormal exits will eventually stop
restarting a healthy worker. Additionally, the abort happens *inside* the trap,
so whatever `WorkerServer#stop` intended to do — `@server.stop` then
`@thread&.join(wait)` (`:67-72`) — does not complete, and the launcher's
in-flight graceful drain is skipped.

The severity is `major`, not `critical`: no unsafe action, no authority bypass,
no data loss. The durable checkpointer is SQLite and survives (the abort is a
process death, not a write corruption; the socket file is removed — verified:
the socket was present while serving and gone after SIGTERM), and the
`EpisodeRunner`/graph durability contracts are unchanged. What is lost is
**clean shutdown and honest process status**, which is a material operational
cost — BAR.md's `major`.

**Why the existing test does not catch it** — this is the finding's most
important corroboration. `test/stream_worker_server_test.rb:104-128` spawns the
launcher, waits for the handshake, and then:

```ruby
ensure
  Process.kill("TERM", pid)
  Process.wait(pid)
end
```

`Process.wait` returns the status and **it is never asserted**. The test asserts
only `assert served` (`:129`). So the suite drives exactly the failing path and
discards its exit status; the abort is invisible. The other three tests
(`:44-92`) call `server.stop` directly from the normal thread, where
`synchronize` is legal — which is why the gem-level `stop` looks correct and
the launcher-level use of it does not. This is the seam gap: `WorkerServer#stop`
was tested as a method, never as a signal handler.

Note this is a **different** defect from E08-REL-01 and from `F24`'s CLI
coverage: E08's is a missing ceiling, E09's is a trap-context violation.

### Lens: observability and evidence

Reviewed on both sides.

*Serving* is observable: the socket appears, the gRPC handshake works
(`test/stream_worker_server_test.rb:136-140`), and the launcher's header
documents its shape (`:10-14`). The launcher prints nothing on a successful
start, which is defensible for a supervised process whose readiness is the
bound socket rather than a log line.

*Stopping* is where evidence breaks down, and it is the observability half of
E09-REL-01: the process's own exit status — the one signal a supervisor reads —
is `SIGABRT` on a **planned** stop, so the evidence a supervisor records is
wrong. Compounding it, the failure emits a raw multi-frame backtrace and a gRPC
C-core assertion dump rather than a typed message, so the operator sees a crash
report for a `kill -TERM`. There is no "stopping" or "stopped" log line, so a
log-only observer cannot see the difference between a graceful stop and this
abort at all. Fixing the trap context at the launcher seam (`:142-143`) corrects
the exit status, which is the signal that matters.

### Lens: scalability and resource bounds

Reviewed. The serving side is bounded by construction: `WorkerServer` uses a
fixed `pool_size: 16` (`worker_server.rb:27`, `:37`), and one lane config drives
one worker (`:124-127`). No queue grows without bound in the launcher itself;
episode admission, verification, and artifact storage are the gem rows' bounds.
`not evidenced` for a load measurement of concurrent episodes — what would prove
it is a soak with many simultaneous dials; `not run`, as this row's budget went
to the shutdown defect and a soak would need a full episode corpus.

One bound worth noting: the abort in E09-REL-01 means the `stop(wait: 5)`
join window (`worker_server.rb:64-73`) is never reached, so an operator cannot
bound shutdown latency. That is a liveness property lost to the same defect, not
a separate finding.

### Lens: maintenance and architecture

Reviewed. Structurally the launcher is the most complete composition in this
brief and its seams are right: profile authority at `:84`/`:107-117`, journaled
model calls at `:116`, in-process fixed graph at `:123`, and the store bindings
at `:131-132`. The `require "tamoz/stream"` umbrella at `:25` is deliberate and
correctly justified at `:23-24` (dependency order for `Tamoz::Error`).

The architecture defect is the **location of the signal handling**. The traps
live in the launcher (`:142-143`) while the thing that must be stopped is a
`GRPC::RpcServer` whose `stop` is not trap-safe. `WorkerServer` already owns the
lifecycle (`worker_server.rb:11-15`: "This class owns the RpcServer lifecycle
(bind → run → stop) so the serving shape is testable"), so the trap-safety
concern belongs at that seam — a `stop` that defers the actual gRPC call out of
the trap context (e.g. setting a flag the serving thread observes, which is
exactly the pattern E08's launcher already uses at `:78-83`) rather than calling
into gRPC from the handler.

Recorded as `info`:

- **E09-MNT-01** — the missing early gate for "exactly one of `--socket`/`--port`"
  (see the security lens). `:67-70` validates three keys; the transport choice is
  validated only at `:137`, after the adapter and memory engine are built.
- **E09-MNT-02** — the launcher's only test discards the exit status
  (`test/stream_worker_server_test.rb:126-127`), which is the coverage hole that
  let E09-REL-01 persist. Recorded here rather than as a separate finding so the
  same gap is not double-counted.

### Tests and contracts

- `ruby -Itest test/stream_worker_server_test.rb` → **4 runs, 11 assertions, 0 failures, 0 errors, 0 skips**.
- Valid profile + `--socket` → UDS socket appears, serves (observed via the socket file and the test's handshake) (run).
- `kill -TERM` on a serving launcher → **exit 134 (`SIGABRT`)**, `ThreadError: can't be called from trap context` in gRPC `rpc_server.rb:250` (run, twice).
- `kill -INT` → **exit 134**, same `ThreadError` (run).
- No args → exit 2, usage (run).
- `--help` → exit 0 (run).
- Valid profile + both `--port` and `--socket` → `ServerError: choose exactly one of socket or port`, exit 1 (run).
- `--lane-config bogus` → `ArgumentError: malformed lane config`, exit 1 (run).
- Missing profile file → `ValidationError: profile file does not exist`, exit 1 (run).
- A test asserting the launcher's exit status after SIGTERM: **not found** —
  the one test that sends SIGTERM (`:126`) never asserts `Process.wait`'s result.

### Findings

#### E09-REL-01 — SIGTERM/SIGINT abort the worker with SIGABRT instead of stopping it

| Field | Content |
|---|---|
| Severity | `major` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `bin/tamoz-stream-worker:142-143` `trap("TERM") { server.stop }` / `trap("INT") { server.stop }`; `gems/tamoz-stream/lib/tamoz/stream/worker_server.rb:64-73` `stop` calls `@server.stop`; gRPC `rpc_server.rb:250` `synchronize` — illegal in a trap context |
| Test/contract evidence | Ran the launcher with a valid profile and `--socket`: `kill -TERM` → exit **134**, `ThreadError: can't be called from trap context (ThreadError)` at `rpc_server.rb:250` via `worker_server.rb:67` via `bin/tamoz-stream-worker:142`, then `Abort trap: 6`; `kill -INT` → exit **134** identically. `ruby -Itest test/stream_worker_server_test.rb` → 4 runs / 11 assertions / 0F — the SIGTERM test at `:104-128` calls `Process.wait(pid)` at `:127` and **never asserts its status** |
| Scanner signal | none (found by launching the worker and signalling it; the suite is green on the same path) |
| Independent judgment | Confirmed by running on both signals, twice, with the captured `ThreadError` and `SIGABRT` exit code — this is a measured runtime result, not a code-reading inference. Confirmed the socket is still unlinked (so the abort is a process-death symptom, not a resource leak) and that the durable SQLite state is untouched by the abort, which is what keeps severity at `major` rather than `critical`. Confirmed the gem-level `stop` tests (`:44-92`) pass because they call `stop` outside a trap, so the defect is specifically the launcher's handler, not `WorkerServer#stop`'s logic |
| Root cause (five whys) | (1) `kill -TERM` on the worker aborts it with SIGABRT instead of exiting 143. (2) The trap handler calls `WorkerServer#stop`, which calls `GRPC::RpcServer#stop`, which calls `Mutex#synchronize` — illegal in a Ruby trap context, so it raises `ThreadError`, and gRPC's C core then fails its completion-queue assertion. (3) The traps were placed in the launcher (`:142-143`) rather than at the lifecycle owner (`WorkerServer`, which the source explicitly says "owns the RpcServer lifecycle"), so the trap-safety constraint was never in view where `stop` was written. (4) No test asserts the launcher's exit status: the only test that signals it (`:126`) calls `Process.wait(pid)` and discards the result, and the other tests exercise `stop` from a normal thread where `synchronize` is legal — so nothing distinguished "stop was called" from "stop worked". (5) There is no contract stating that a signal handler must only set a flag and let a normal-context thread perform the stop, nor that a supervised launcher's exit status after SIGTERM is part of its interface; that contract, plus an asserting test, is what would prevent recurrence |
| Recommendation | Smallest credible action at the existing seam: make the handler trap-safe by deferring, the way `bin/tamoz-stream-subscriber:78-83` already does — have the trap set a flag (and/or push to a queue the serving thread polls) and let the normal-context caller perform `server.stop`; then assert the exit status in `test/stream_worker_server_test.rb:126-127`. No new class; `WorkerServer#stop`'s logic stays as it is. |
| Disposition | Open, `major`. Independent challenge required before closure per BAR.md. |

#### E09-MNT-01 — the transport choice is validated after the whole port composition

| Field | Content |
|---|---|
| Severity | `info` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `bin/tamoz-stream-worker:67-70` gates only `profile`/`database`/`tenant`; `:86-135` build the adapter, memory engine, graph, and worker; `:137` `WorkerServer.new` raises `choose exactly one of socket or port` (`worker_server.rb:31-33`) |
| Test/contract evidence | Ran with a valid profile plus both `--port 0` and `--socket` → `ServerError`, exit 1; also ran with neither → the same error after the adapter was opened |
| Scanner signal | none |
| Independent judgment | Verified by running: the failure is correct and non-zero, so this is wasted work on an invalid invocation rather than a correctness defect. Recorded as `info` |
| Root cause | Concise: the early gate predates the transport options, and the transport pair is validated by its owning class rather than by the grammar |
| Recommendation | Optional: extend the `:67-70` gate with `options[:socket].nil? ^ options[:port].nil?` to fail before opening SQLite. Not required for correctness. |
| Disposition | Accepted as `info`. |

#### E09-MNT-02 — the launcher's test discards the exit status it depends on

| Field | Content |
|---|---|
| Severity | `info` |
| Confidence | `high` |
| Status | `open` |
| Source evidence | `test/stream_worker_server_test.rb:126-127` `Process.kill("TERM", pid)` / `Process.wait(pid)`; the only assertion is `assert served` at `:129` |
| Test/contract evidence | Suite green (4 runs / 11 assertions / 0F) while the same path aborts with 134 when run by hand |
| Scanner signal | none |
| Independent judgment | Verified by reading the test and by the divergence between its green result and the measured 134. Recorded as `info` because it is the coverage half of E09-REL-01, not an independent defect |
| Root cause | Concise: `Process.wait` was called to reap the child, not to assert its status |
| Recommendation | Assert the status in the same test as part of the E09-REL-01 fix. |
| Disposition | Accepted as `info`, folded into E09-REL-01's evidence. |

### Blind spots

- No real episode was executed end to end through the worker; the model-call
  factory (`:107-117`) would call a live provider, which this brief forbids. The
  composition was verified by reading and by the fact that the server binds and
  serves the handshake.
- The `--skills-source` path was read (`:101`, `:119`) but not exercised with a
  real skills JSON map.
- mTLS at the socket boundary is a deployment concern outside the checkout; the
  code's `:this_port_is_insecure` (`worker_server.rb:80`) was confirmed by
  reading and is honestly documented at `:16-18`.
- `EpisodeNode`: the graph's internals belong to the kernel/agent rows.

### Verdict

**IMPROVE** — critical 0, major 1, minor 0, info 2. One `major` finding meets
the BAR.md threshold.

---

## Coordinator reconciliation

Three rows in this brief carry exactly **one** accepted `minor` finding (A01
carries one `minor` plus one `major`; E04, E03, E08 carry one `minor` each, and
E03 carries one). BAR.md's verdict rule is: `IMPROVE` at one critical/major **or
three or more** minor; `PASS` "only after all six lenses and required evidence
are reviewed and **no such threshold is met**". A row with one `minor` and no
`major` meets neither branch literally. Records as follows:

- **A01** — `IMPROVE` (one `major`). Unambiguous.
- **E09** — `IMPROVE` (one `major`). Unambiguous.
- **E08** — `IMPROVE` (one `major`). Unambiguous.
- **E03** — recorded `PASS` in its section; carries one open `minor`
  (E03-ERR-01). Verdict string in the JSON is `PASS`.
- **E04** — recorded `IMPROVE` with the reasoning stated inline, because its
  scope note in `COVERAGE.md:109` is "finding probe harness" and its exit-status
  contract is a live defect for the documented multi-probe usage
  (`06-observed-chat-findings.md:677`).
- **E01, E02, E05, E06, E07** — `PASS` with zero findings.

The coordinator should settle the single-`minor` question once: if the house
reading is "one minor is still PASS", E03 and E04 are both `PASS`; if it is
"any accepted minor is IMPROVE", both are `IMPROVE`. The two rows are flagged
`coordinator_flags: ["verdict-threshold ambiguity: single minor"]` in the JSON.

## Cross-row observations

- **The two `major` findings are both signal handling, and both are invisible to
  a green suite.** E09's trap aborts (`:142-143`) while its test discards
  `Process.wait` (`test/stream_worker_server_test.rb:127`); E08's loop has no
  ceiling and no test at all. A single convention — a launcher's exit status
  under a signal is part of its tested contract — would have surfaced both.
- **`bin/tamoz-stream-subscriber:78-83` already uses the flag the E09 fix
  needs.** The trap-safe pattern exists in this repository, in a sibling
  launcher; E09 simply does not use it.
- **E06/E07 are clean mirrors; E08/E09 are not mirrors of anything.** The two
  eval wrappers unshift explicit gem libs and call one `CLI.run`, which is why
  they have no defects. The two stream launchers compose a dozen ports inline
  and own their own process lifecycle, which is where both `major` findings are.
- **All three shipped executables (`exe/`) are correctly packaged** — gemspec
  declares, `bindir = "exe"`, `executables` set, `exe/*` in `spec.files`, mode
  `755`, shebang fine under rbenv, and `test/packaging_test.rb:756-762` pins it.
  No installed-surface finding exists in this brief.
- **The documentation surface check does not reach `apps/` or
  `documentation/guides/`.** `test/documentation_surface_test.rb:17-20` covers
  four pages. `apps/tamoz-agent/README.md` (A01-MNT-02),
  `documentation/guides/agent-operator.md`, and
  `documentation/guides/evaluation.md` are all unchecked. I read all three and
  found no live mismatch, so this is recorded as one `minor` (A01-MNT-02) rather
  than three findings.

## Blind spots (whole brief)

- `test/packaging_test.rb` was **not run** (installs 27 gems into separate
  `GEM_HOME`s; outside the budget). Its executable assertions were read at
  `:756-762` and the installed shape was reproduced directly with `RUBYLIB`.
- No live LLM, provider, or Telegram call was made, by instruction. E05's live
  path is therefore read-only evidence.
- A successful `tamoz-eval-runner` scorecard and a real worker episode were
  **not run** (both need external pinned corpora, and the latter a live provider).
- `script/` (S01), `scripts/start-tamoz-comms.sh` (S02), and `Rakefile` (R01) are
  other rows; I read the two callers of E06/E07 only to confirm the wrapper
  contract.
- Historical audit packages (`docs/repo-quality-audit-2026-08-20/`,
  `docs/repo-quality-audit-2026-08-20/dead-code.md`) were not used as evidence;
  every claim in this report is from a `file:line` I read or a command I ran at
  HEAD `582ae55`.
