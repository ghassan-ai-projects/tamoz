# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"
require "fileutils"

RUBY_SOURCES = FileList[
  "Rakefile",
  "bin/*",
  "script/*",
  "gems/**/*.rb",
  "gems/**/exe/*",
  "test/**/*.rb"
].select { |path| File.file?(path) }.freeze

# The autonomy scorecard is a MILESTONE gate, not a regression gate: its cases
# describe the product Tamoz is being built into and fail until that product
# exists. Keeping it out of `rake test` lets `rake ci` keep its meaning — no
# regression in what already works — while `rake autonomy` reports honestly on
# what does not work yet. Both must pass to close the milestone.
AUTONOMY_TESTS = ["test/autonomy_scorecard_test.rb"].freeze

# The slow set: every file measured at >= 5 seconds, plus everything in
# SERIAL_TESTS. They are slow for real reasons — spawning MCP server
# subprocesses, SIGKILLing children at each durable seam, building all nine
# gems, verifying SQLite against a raw oracle — so there is nothing to trim, only
# a decision about WHEN to pay for them.
#
# They are excluded from `rake test` and `rake ci` and run explicitly:
#
#   rake test_slow    just this set
#   rake ci_full      the whole gate, nothing skipped
#
# Run `ci_full` before committing anything that touches durability, MCP,
# packaging or the committed evidence artifacts. `ci` alone does not cover them,
# and it says so when it finishes.
#
# agent_scorecard / memory_treatment_profile are scorecard/data-profile GATES,
# not behaviour probes (49.8s / 15.7s measured); parked here so they cannot set
# the floor of the everyday lane (docs/audits/test-suite-audit-2026-08-24 §6).
# The benchmark and thermal-evidence gates are the same shape: they score a
# corpus end to end (the C8/B0 pair re-runs the whole catalog twice to prove
# byte-identical output) rather than probing behaviour, so the everyday lane
# skips them and `ci_full` still runs every one.
SLOW_TESTS = %w[
  test/benchmark_comms_b0_test.rb
  test/benchmark_comms_controls_test.rb
  test/benchmark_holdout_test.rb
  test/thermal_manifest_test.rb
  test/thermal_tournament_test.rb
  test/thermal_tournament_controls_test.rb
  test/sqlite_raw_oracle_test.rb
  test/mcp_invocation_test.rb
  test/agent_session_kill_matrix_test.rb
  test/sqlite_convergence_probe_test.rb
  test/mcp_supervisor_test.rb
  test/sqlite_scenario_driver_test.rb
  test/m2_evidence_test.rb
  test/agent_scorecard_test.rb
  test/memory_treatment_profile_test.rb
].freeze

# Tests that must NOT share a process pool with anything else. They build gems
# into shared paths, regenerate committed artifacts, or spawn their own test
# subprocesses, so running two of them at once makes them fail on each other
# rather than on the code. Everything else shards freely.
# `agent_mcp_adversarial_test` asserts a GLOBAL property of the process table —
# that no mcp_test_server survives teardown. Any other MCP test running
# concurrently owns legitimately live servers it cannot distinguish from
# orphans, so it can only be trusted when nothing else is running.
#
# NOTE: %w[] does not honour `#` as a comment — every word inside becomes an
# element. Keep prose out of the literal.
SERIAL_TESTS = %w[
  test/agent_mcp_adversarial_test.rb
  test/packaging_test.rb
  test/dependency_isolation_test.rb
  test/graph_surface_audit_test.rb
  test/requirements_manifest_test.rb
  test/release_rehearsal_evidence_test.rb
  test/stream_episode_worker_test.rb
  test/stream_episode_end_to_end_test.rb
  test/stream_evidence_client_test.rb
  test/stream_worker_server_test.rb
].freeze

EXCLUDED_FROM_DEFAULT = (AUTONOMY_TESTS + SLOW_TESTS + SERIAL_TESTS).freeze

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.test_files = FileList["test/**/*_test.rb"].reject do |path|
    EXCLUDED_FROM_DEFAULT.include?(path)
  end
  task.warning = true
end

desc "The slow set: subprocess, crash-matrix, packaging and evidence tests"
Rake::TestTask.new(:test_slow) do |task|
  task.libs << "test"
  task.test_files = (SLOW_TESTS + SERIAL_TESTS).select { |path| File.file?(path) }
  task.warning = true
end


LIB_FLAGS = Dir[File.join(__dir__, "gems", "*", "lib")]
            .map { |path| "-I#{path}" }.sort.join(" ").freeze

# Measured wall-clock seconds per file (`rake test_profile` regenerates these).
# Used to BIN-PACK the shards: round-robin left one worker trailing a 23-second
# file while others idled, which set the floor for the whole run.
#
# Anything absent uses DEFAULT_WEIGHT — being wrong about a fast file costs
# almost nothing, whereas being wrong about a slow one costs the whole run, so
# only the slow tail needs to be accurate.
#
# Numbers re-measured 2026-09-16 (`rake test_profile`). The previous table
# predated the B0/thermal evidence gates, so bin-packing treated a 20-second
# file as a default-weight one and left a whole shard trailing it.
DEFAULT_WEIGHT = 0.7
TEST_WEIGHTS = {
  "test/packaging_test.rb" => 62.3,
  "test/graph_surface_audit_test.rb" => 58.4,
  "test/agent_scorecard_test.rb" => 51.5,
  "test/agent_session_kill_matrix_test.rb" => 37.8,
  "test/sqlite_raw_oracle_test.rb" => 34.1,
  "test/sqlite_convergence_probe_test.rb" => 26.5,
  "test/autonomy_scorecard_test.rb" => 25.7,
  "test/mcp_invocation_test.rb" => 23.0,
  "test/benchmark_comms_b0_test.rb" => 20.0,
  "test/memory_treatment_profile_test.rb" => 15.1,
  "test/sqlite_scenario_driver_test.rb" => 12.4,
  "test/mcp_supervisor_test.rb" => 12.4,
  "test/thermal_manifest_test.rb" => 6.4,
  "test/websearch_invocation_test.rb" => 5.4,
  "test/tamoz_telegram_transport_test.rb" => 4.7,
  "test/agent_session_operations_test.rb" => 4.6,
  "test/thermal_tournament_test.rb" => 4.3,
  "test/agent_mcp_adversarial_test.rb" => 4.0,
  "test/agent_unattended_policy_test.rb" => 3.9,
  "test/agent_cli_test.rb" => 3.8,
  "test/benchmark_holdout_test.rb" => 3.7,
  "test/dependency_isolation_test.rb" => 3.6,
  "test/agent_mcp_capability_source_test.rb" => 3.4,
  "test/agent_profile_machinery_test.rb" => 3.3,
  "test/agent_worker_test.rb" => 3.2
}.freeze

# `test_fast` skips the serial tail — gem builds, artifact regeneration, the
# coverage audit, the process-table probe. Those verify PACKAGING and EVIDENCE,
# not behaviour, so they rarely tell you anything while you are moving code
# around. Use `test_fast` in a refactor loop and `rake ci` before committing.
desc "Behaviour tests only, across processes (tightest refactor loop)"
task :test_fast do
  Rake::Task[:test_parallel].invoke(:skip_slow)
end

desc "Run the test suite across processes (fast; use for a refactor loop)"
task :test_parallel, [:mode] do |_task, args|
  require "etc"
  require "open3"

  include_slow = args[:mode] != :skip_slow
  all = FileList["test/**/*_test.rb"].reject do |path|
    AUTONOMY_TESTS.include?(path) || (!include_slow && SLOW_TESTS.include?(path))
  end
  serial = include_slow ? (SERIAL_TESTS & all) : []
  parallel = all - (SERIAL_TESTS & all)

  workers = [Etc.nprocessors - 1, 1].max
  CiBudget.parallel_workers = workers
  # Longest-processing-time-first bin packing: heaviest file into the lightest
  # shard, repeatedly. Simple, and close enough to optimal that the run is
  # bounded by the single slowest FILE rather than by an unlucky shard.
  shards = Array.new(workers) { [] }
  load = Array.new(workers, 0.0)
  parallel.sort_by { |path| -TEST_WEIGHTS.fetch(path, DEFAULT_WEIGHT) }.each do |path|
    lightest = load.each_with_index.min_by { |value, _| value }.last
    shards[lightest] << path
    load[lightest] += TEST_WEIGHTS.fetch(path, DEFAULT_WEIGHT)
  end

  failures = Queue.new
  shards.reject(&:empty?).map do |files|
    Thread.new do
      # One process per shard, requiring every file in it — `ruby a.rb b.rb`
      # would run only the first and treat the rest as ARGV.
      command = "#{RbConfig.ruby} -Itest #{LIB_FLAGS} " \
                "-e 'ARGV.each { |f| require File.expand_path(f) }' #{files.join(" ")}"
      output, status = Open3.capture2e(command)
      failures << [files, output] unless status.success?
    end
  end.each(&:join)

  # The serial tail: gem builds and artifact regeneration, one at a time.
  serial.each do |path|
    output, status = Open3.capture2e(
      "#{RbConfig.ruby} -Itest #{LIB_FLAGS} #{path}"
    )
    failures << [[path], output] unless status.success?
  end

  unless failures.empty?
    until failures.empty?
      files, output = failures.pop
      warn "FAILED: #{files.join(", ")}"
      lines = output.lines
      lines.each_with_index do |line, index|
        next unless line =~ /^\s*\d+\) (Failure|Error):/

        warn lines[index, 4].join
      end
      warn lines.grep(/runs,/).last.to_s
    end
    abort("test_parallel failed")
  end
  puts "test_parallel: #{parallel.length} files across #{workers} workers + #{serial.length} serial — all passed"
end

desc "Measure per-file test wall clock (regenerates the TEST_WEIGHTS table)"
task :test_profile do
  require "open3"
  timings = FileList["test/**/*_test.rb"].map do |path|
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Open3.capture2e("#{RbConfig.ruby} -Itest #{LIB_FLAGS} #{path}")
    [path, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)]
  end
  timings.sort_by { |_, seconds| -seconds }.first(25).each do |path, seconds|
    puts format("  %-52s => %.1f,", "\"#{path}\"", seconds)
  end
end

desc "Run the autonomy scorecard and regenerate docs/autonomy-scorecard.json"
task :autonomy do
  ruby "script/autonomy_scorecard"
end

desc "The autonomy milestone gate: every scorecard case must pass"
task :autonomy_strict do
  ruby "script/autonomy_scorecard --strict"
end

desc "Check every Ruby source file for syntax errors"
task :syntax do
  failures = RUBY_SOURCES.reject do |path|
    system(RbConfig.ruby, "-wc", path, out: File::NULL, err: File::NULL)
  end
  abort("Ruby syntax failed: #{failures.join(", ")}") unless failures.empty?
end

namespace :design do
  desc "Validate the authoritative design package"
  task :validate do
    ruby "docs/design-v0.1/validate_design.rb"
  end
end

namespace :adr do
  desc "Regenerate documentation/adr/catalog.json from the ADR files"
  task :catalog do
    ruby "script/adr_catalog.rb"
  end

  desc "Validate the ADR catalog (numbering, structure, links, supersession, catalog sync)"
  task :validate do
    ruby "script/adr_validate.rb"
  end

  desc "Check every ADR's Verification evidence still exists in the tree (drift alarm)"
  task :verify do
    ruby "script/adr_verify.rb"
  end

  desc "Regenerate the ADR <-> gem <-> invariant <-> test traceability matrix"
  task :trace do
    ruby "script/adr_traceability.rb"
  end

  desc "Regenerate the ADR relationship graph (relationships.md, Mermaid)"
  task :graph do
    ruby "script/adr_graph.rb"
  end
end

namespace :fixtures do
  desc "Regenerate canonical evaluation fixtures"
  task :refresh do
    ruby "script/generate_m0_fixtures"
    ruby "script/generate_m1_fixtures"
    ruby "script/generate_m2_fixtures"
    ruby "script/generate_agent_smoke_fixtures"
    ruby "script/generate_agent_memory_fixtures"
  end
end

# --- Quality gates (Q1 of the quality program; charter docs/QUALITY_PROGRAM.md) ---
# Ratchet, not big-bang: these tasks fail when the committed baseline would have
# to grow. The committed baseline is docs/code-quality-baseline.json, regenerated
# by script/regenerate_quality_baseline after every slice that moves the numbers.

QUALITY_ROOT = File.expand_path(__dir__)
ENOLA_BIN = ENV.fetch('ENOLA_BIN', File.join(Dir.home, '.local', 'bin', 'enola'))
QUALITY_BASELINE = File.join(QUALITY_ROOT, 'docs', 'code-quality-baseline.json')
QUALITY_RESULTSET = File.join(QUALITY_ROOT, 'coverage', '.resultset.json')
QUALITY_REPORT_DIRS = %w[gems script bin apps].freeze
QUALITY_TODO = File.join(QUALITY_ROOT, '.rubocop_todo.yml')

def quality_exclude_entries(content)
  content.scan(/^\s+-\s+'([^']+)'$/).flatten
end

namespace :quality do
  desc 'RuboCop: zero offenses + the committed TODO must not grow'
  task :rubocop do
    sh 'rubocop', '--format', 'simple'
    before = File.read(QUALITY_TODO)
    begin
      sh 'rubocop', '--auto-gen-config', '--no-auto-gen-timestamp',
         '--auto-gen-only-exclude', '--exclude-limit', '500'
      ruby 'script/clean_rubocop_todo'
      added = quality_exclude_entries(File.read(QUALITY_TODO)) - quality_exclude_entries(before)
    ensure
      # The regeneration is a probe: restore the committed TODO even if the
      # probe fails, so a broken regen cannot leave the working tree mutated.
      File.write(QUALITY_TODO, before)
    end
    unless added.empty?
      added.first(10).each { |entry| warn "  + #{entry}" }
      raise "quality:rubocop failed: the TODO grew by #{added.size} exclusion(s) — fix the offenses"
    end
    puts 'rubocop: 0 offenses; TODO stable'
  end

  desc 'RuboCop: zero-offense gate only (the fast everyday check)'
  task :rubocop_gate do
    sh 'rubocop', '--format', 'simple'
  end

  desc 'Reek: no new smell in any production file vs the committed baseline'
  task :reek do
    require 'json'
    require 'open3'
    baseline = JSON.parse(File.read(QUALITY_BASELINE)).fetch('reek').fetch('by_file')
    bin = Gem.bin_path('reek', 'reek')
    out, = Open3.capture3(RbConfig.ruby, bin, '--format', 'json', *QUALITY_REPORT_DIRS, chdir: QUALITY_ROOT)
    by_file = Hash.new(0)
    JSON.parse(out).each { |smell| by_file[smell.fetch('source')] += 1 }
    regressed = by_file.select { |file, count| count > baseline.fetch(file, 0) }
    unless regressed.empty?
      regressed.each { |file, count| warn "  #{file}: baseline #{baseline.fetch(file, 0)} -> #{count}" }
      raise 'quality:reek failed: new smell(s) in production code'
    end
    puts "reek: #{by_file.values.sum} smells; none new vs the committed baseline"
  end

  desc 'Coverage: RUN_COVERAGE=1 run must not fall below the committed baseline'
  task :coverage do
    require 'json'
    require 'open3'
    require_relative 'script/quality/coverage_totals'
    baseline = JSON.parse(File.read(QUALITY_BASELINE)).fetch('coverage')
    # MT_SEED pinned (same as the baseline generator) so the comparison is
    # exact — a random seed would move a line or two and false-fail the ratchet.
    _out, err, status = Open3.capture3(
      { 'RUN_COVERAGE' => '1', 'MT_SEED' => '1' }, RbConfig.ruby, '-S', 'bundle', 'exec', 'rake', 'test',
      chdir: QUALITY_ROOT
    )
    raise "quality:coverage failed: coverage run failed: #{err}" unless status.success?

    totals = QualityCoverage.totals(QUALITY_RESULTSET)
    %w[line_percent branch_percent].each do |key|
      next unless totals.fetch(key) < baseline.fetch(key)

      raise "quality:coverage failed: #{key} fell below baseline (#{totals.fetch(key)} < #{baseline.fetch(key)})"
    end
    puts "coverage: line #{totals.fetch('line_percent')}% / branch #{totals.fetch('branch_percent')}% — no decrease"
  end

  desc 'Enola: no cycles, layer violations, or unexplained spillover'
  task :architecture do
    if File.executable?(ENOLA_BIN)
      sh ENOLA_BIN, 'check', '--fail-on=cycles,layers', '--min-confidence=0.8', '.'
    else
      warn "architecture: skipped — no enola at #{ENOLA_BIN} (set ENOLA_BIN to run it)"
    end
  end

  desc 'Baseline drift: the committed code-quality-baseline.json must match the raw ledgers'
  task :baseline_drift do
    ruby 'script/check_baseline_drift'
  end
end

# T1.1 — the vendored gRPC stubs are regenerated from the pinned proto and the
# committed copies must never drift. `proto` rewrites, `proto:check` proves
# (the check runs in the everyday gate).
namespace :stream do
  PROTO = "gems/tamoz-stream/contracts/runtime-v1.proto"
  GEN_DIR = "gems/tamoz-stream/lib/tamoz/stream/gen"
  GEN_FILES = [
    "#{GEN_DIR}/runtime-v1_pb.rb",
    "#{GEN_DIR}/runtime-v1_services_pb.rb"
  ].freeze

  def stream_protoc
    Gem.bin_path("grpc-tools", "grpc_tools_ruby_protoc")
  end

  desc 'Regenerate the vendored gRPC stubs from the pinned runtime-v1 proto'
  task :proto do
    sh stream_protoc,
       "-I", "gems/tamoz-stream/contracts",
       "--ruby_out=#{GEN_DIR}",
       "--grpc_out=#{GEN_DIR}",
       PROTO
  end

  desc 'Drift check: the committed stubs must match a fresh codegen'
  task "proto:check" do
    require "tmpdir"
    Dir.mktmpdir("tamoz-proto") do |directory|
      sh stream_protoc,
         "-I", "gems/tamoz-stream/contracts",
         "--ruby_out=#{directory}",
         "--grpc_out=#{directory}",
         PROTO
      GEN_FILES.each do |path|
        fresh = File.join(directory, File.basename(path))
        unless File.read(fresh) == File.read(path)
          raise "proto drift: #{path} diverges from the vendored proto; run `rake stream:proto`"
        end
      end
    end
  end
end

desc 'The full quality gate: architecture'
task quality: ['quality:architecture']

# The everyday gate has a hard wall-clock budget (docs/audits/
# test-suite-audit-2026-08-24): if it creeps past this, the run FAILS rather
# than quietly getting slower again. Weights rot silently; this does not.
#
# The ceiling is calibrated on a developer machine at REFERENCE_WORKERS. A
# runner with fewer workers spreads the SAME suite over a longer wall clock
# without the suite having grown, so the ceiling scales with the parallelism:
# otherwise the gate grades the runner's CPU count, and a 3-worker CI box fails
# a suite the 9-worker machine it was calibrated on passes in half the budget.
module CiBudget
  BUDGET_SECONDS = 60.0
  REFERENCE_WORKERS = 9

  class << self
    attr_accessor :started_at, :parallel_workers

    def allowed_seconds
      workers = [parallel_workers || 1, 1].max
      BUDGET_SECONDS * REFERENCE_WORKERS / workers.to_f
    end
  end
end

desc "Record the ci start time (first prerequisite of :ci)"
task :ci_budget_start do
  CiBudget.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end

desc 'The everyday gate — fast, and honest about what it skips'
task ci: [:ci_budget_start, 'design:validate', 'adr:validate', :syntax, :test_fast, 'stream:proto:check',
          'quality:architecture'] do
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - CiBudget.started_at
  skipped = (SLOW_TESTS + SERIAL_TESTS).length
  allowed = CiBudget.allowed_seconds
  warn ""
  warn "ci: #{skipped} slow files were NOT run (subprocess, crash-matrix, packaging,"
  warn "    evidence, scorecard gates). Run `rake ci_full` before committing anything"
  warn "    touching durability, MCP, packaging or the committed evidence artifacts."
  puts format("ci wall clock: %.1fs (budget %.0fs at %d workers)",
              elapsed, allowed, CiBudget.parallel_workers || 1)
  if elapsed <= allowed
    next
  elsif (CiBudget.parallel_workers || 1) < 2
    # The budget tunes a developer machine's parallel gate. A single-worker
    # runner executes the same suite serially — the wall clock measures that
    # hardware, not suite creep, so failing here would be noise.
    warn "ci: budget not enforced — the run had a single worker."
  else
    abort(format("ci BUDGET EXCEEDED: %.1fs > %.0fs — the everyday gate got slow again. " \
                 "Run `rake test_profile`, refresh TEST_WEIGHTS and re-lane the tail.",
                 elapsed, allowed))
  end
end

# The complete gate. Stays SERIAL for the test phase: a parallel run is one
# contended process table away from a false failure, and the gate that decides
# whether something ships should not have that property.
desc "The complete gate — nothing skipped (use before committing)"
task ci_full: ["design:validate", "adr:validate", "adr:verify", :syntax, :test, :test_slow,
               "stream:proto:check", "quality:architecture"]

desc "The complete gate with the test phase sharded across processes"
task ci_fast: ["design:validate", :syntax, :test_parallel]

desc "Documentation tree check: relative links resolve, index covers every file"
task "docs:check" do
  ruby "-Itest", "test/documentation_tree_test.rb"
end

namespace :agenteval do
  BIN = "agenteval/bin/agenteval"
  REPORTS = "agenteval/reports"
  BASELINES = "docs/eval-improvement"

  # A real-model run needs a UTF-8 locale or ruby_llm dies parsing models.json.
  def utf8_env!
    ENV["LANG"] = "en_US.UTF-8" if ENV["LANG"].to_s.empty? || ENV["LANG"] == "C"
    ENV["LC_ALL"] = "en_US.UTF-8" if ENV["LC_ALL"].to_s.empty? || ENV["LC_ALL"] == "C"
  end

  # The Rakefile owns the interpreter. `RbConfig.ruby` is whatever ran rake, and shelling
  # out to bare `ruby` picks up PATH — on a stock macOS that is 2.6, where this harness does
  # not parse, so the eval died with syntax errors before it started. The repo pins its
  # interpreter in `.ruby-version`, so resolve that rather than inheriting either.
  def agenteval_ruby
    pinned = File.read(File.join(__dir__, ".ruby-version")).strip
    candidate = File.join(Dir.home, ".rbenv", "versions", pinned, "bin", "ruby")
    return candidate if File.executable?(candidate)

    RbConfig.ruby
  end

  desc "Prove the graders discriminate — offline, four control agents (no model calls)"
  task :controls do
    sh agenteval_ruby, BIN, "controls", "--modifiers", "all"
  end

  desc "Validate the corpus — reachable and non-trivial (deterministic, no model calls)"
  task :validate do
    sh agenteval_ruby, BIN, "validate", "--modifiers", "all"
  end

  desc "Run the grader tests — the properties the reviews required be permanent"
  task :test do
    sh agenteval_ruby, "-Itest", "agenteval/test/grader_test.rb"
  end

  # Nothing is measured until the instrument is known to discriminate: a number from a
  # grader that inaction satisfies is not a weak signal, it is not a signal.
  desc "Controls + corpus validation — the gate that must pass before any paid run"
  task prove: %i[test controls validate]

  desc "Run the corpus against the agent and write a dated report (needs DEEPSEEK_API_KEY)"
  task run: :prove do
    utf8_env!
    out = ENV.fetch("AGENTEVAL_OUT", File.join(REPORTS, "run-#{Time.now.utc.strftime("%Y%m%d")}.json"))
    sh agenteval_ruby, BIN, "run", "--tasks", "all",
       "--modifiers", ENV.fetch("AGENTEVAL_MODIFIERS", "all"),
       "--repeat", ENV.fetch("AGENTEVAL_REPEAT", "2"),
       "--seeds", ENV.fetch("AGENTEVAL_SEEDS", "1"),
       "--budget", ENV.fetch("AGENTEVAL_BUDGET", "240"),
       "--out", out
  end

  desc "Compare the newest run against the committed baseline (non-zero on a regression)"
  task :compare do
    committed = Dir[File.join(BASELINES, "baseline-*.json")].sort
    local = Dir[File.join(REPORTS, "*.json")].sort
    raise "need a committed baseline under #{BASELINES} or two local reports" if committed.empty? && local.length < 2

    after = local.last
    raise "no run to compare yet (looked under #{REPORTS})" if after.nil?

    before = committed.last || local[-2]
    raise "need two runs to compare (#{after} is the only one)" if before == after

    puts "comparing #{File.basename(before)} -> #{File.basename(after)}"
    sh agenteval_ruby, BIN, "compare", before, after
  end

  # The coding-harness real-model runs (docs/coding-harness/EVAL.md §5). Each arm is a paired
  # run on the same seeds; a failed gate or a regression is a finding, so every arm runs to the
  # end and the exit statuses are reported together.
  ACTING_TASKS = "repair,diagnose,implement,author_tests,rename_across,multi_implement,registry_swap,backlog"
  HARNESS_ARMS = {
    "cache" => { adapters: %w[tamoz-code], tasks: "backlog,planted_constraint", modifiers: "clean",
                 seeds: "1,2,3,4,5", repeat: "1" },
    "capability" => { adapters: %w[tamoz tamoz-code], tasks: ACTING_TASKS, modifiers: "all",
                      seeds: "1,2,3,4", repeat: "2" },
    "fidelity" => { adapters: %w[tamoz-code tamoz-code-small], tasks: "backlog,planted_constraint",
                    modifiers: "clean,noise", seeds: "1,2,3,4", repeat: "2" },
    "instructions" => { adapters: %w[tamoz-code tamoz-code-noguide], tasks: "guidance_convention,guidance_injection",
                        modifiers: "clean", seeds: "1,2,3,4", repeat: "2" }
  }.freeze

  def deepseek_funded!
    require "net/http"
    key = ENV["DEEPSEEK_API_KEY"].to_s
    key = File.read(".env")[/DEEPSEEK_API_KEY\s*=\s*(\S+)/, 1].to_s if key.empty? && File.exist?(".env")
    uri = URI("https://api.deepseek.com/user/balance")
    body = Net::HTTP.get(uri, { "Authorization" => "Bearer #{key}" })
    return if body.include?('"is_available":true')

    abort "DeepSeek reports no usable balance (#{body.strip[0, 160]}); top up before a real run"
  end

  # A real run spends money, so name the blocker for the SELECTED route before spending any. The
# default route is OpenRouter while the DeepSeek direct account is unfunded; either can be chosen
# with AGENTEVAL_PROVIDER / AGENTEVAL_MODEL.
def agenteval_env_key(name)
  key = ENV[name].to_s
  return key unless key.empty?

  dotenv = File.join(__dir__, ".env")
  File.exist?(dotenv) ? File.read(dotenv)[/#{name}\s*=\s*(\S+)/, 1].to_s : ""
end

def openrouter_reachable!
  require "net/http"
  key = agenteval_env_key("OPENROUTER_API_KEY")
  abort "OPENROUTER_API_KEY is not set; export it or use AGENTEVAL_PROVIDER=deepseek" if key.empty?

  body = Net::HTTP.get(URI("https://openrouter.ai/api/v1/models"), { "Authorization" => "Bearer #{key}" })
  return if body.include?('"data"')

  abort "OpenRouter refuses the configured key (#{body.strip[0, 160]}); renew it or use AGENTEVAL_PROVIDER=deepseek"
rescue SocketError, Timeout::Error => e
  abort "OpenRouter is unreachable (#{e.class}); a real run needs the network"
end

def real_run_ready!
  provider = ENV.fetch("AGENTEVAL_PROVIDER", "openrouter")
  provider == "deepseek" ? deepseek_funded! : openrouter_reachable!
end

def harness_step(label, *command, **options)
    sh(*command, **options) { |ok, status| puts "#{label}: #{ok ? 'ok' : "exit #{status.exitstatus}"}" }
  end

  def harness_arm(arm, spec)
    stamp = Time.now.utc.strftime("%Y%m%d%H%M")
    selection = ["--tasks", spec.fetch(:tasks), "--modifiers", spec.fetch(:modifiers), "--seeds", spec.fetch(:seeds)]
    sh agenteval_ruby, BIN, "validate", *selection
    outs = spec.fetch(:adapters).map { |adapter| harness_run(arm, adapter, stamp, selection, spec.fetch(:repeat)) }
    harness_step("#{arm} compare", agenteval_ruby, BIN, "compare", *outs) if outs.length == 2
  end

  def harness_run(arm, adapter, stamp, selection, repeat)
    name = "harness-#{arm}-#{adapter}-#{stamp}"
    sessions = File.expand_path(File.join("agenteval", "sessions", name))
    out = File.join(REPORTS, "#{name}.json")
    harness_step("#{arm} #{adapter}", { "AGENTEVAL_SESSION_DIR" => sessions }, agenteval_ruby, BIN, "run",
                 "--adapter", adapter, *selection, "--repeat", repeat,
                 "--budget", ENV.fetch("AGENTEVAL_BUDGET", "900"), "--out", out)
    return out if adapter == "tamoz"

    FileUtils.mkdir_p(File.join(REPORTS, "traces"))
    harness_step("#{arm} #{adapter} trace", agenteval_ruby, "script/context_trace",
                 File.join(sessions, "sessions"), "--json", out: File.join(REPORTS, "traces", "#{name}.json"))
    out
  end

  namespace :harness do
    HARNESS_ARMS.each do |arm, spec|
      desc "Coding-harness real run: #{arm} arm (#{spec[:adapters].join(' vs ')})"
      task arm => :prove do
        utf8_env!
        real_run_ready!
        harness_arm(arm, spec)
      end
    end

    desc "All coding-harness real runs, in order"
    task all: HARNESS_ARMS.keys
  end

  desc "Promote the newest run to the committed baseline"
  task :baseline do
    latest = Dir[File.join(REPORTS, "*.json")].sort.last
    raise "no run under #{REPORTS} to promote" if latest.nil?

    target = File.join(BASELINES, "baseline-#{File.mtime(latest).utc.strftime("%Y%m%d")}.json")
    FileUtils.cp(latest, target)
    puts "promoted #{File.basename(latest)} -> #{target}"
  end
end

namespace :benchmark do
  # The discrimination gate for the breadth and physical surfaces, the analogue
  # of agenteval:prove. It drives the real graders with control agents (an oracle
  # passes, null/cheap fail, an adversary trips the gate it targets). A publishing
  # run may claim --controls-passed only after this gate is green: the flag is the
  # gate's output, not an operator's assertion.
  CONTROL_SUITES = %w[
    test/benchmark_comms_controls_test.rb
    test/openclaw_mission_controls_test.rb
    test/thermal_tournament_controls_test.rb
  ].freeze

  desc "Prove the benchmark graders discriminate — offline control suites (no model calls)"
  task :controls do
    utf8_env!
    CONTROL_SUITES.each { |suite| sh agenteval_ruby, "-Itest", suite }
  end

  desc "The offline gate a benchmark run must pass before it may claim --controls-passed"
  task prove: :controls
end

task default: :ci
