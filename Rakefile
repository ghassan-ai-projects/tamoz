# frozen_string_literal: true

require "rake/testtask"
require "rbconfig"

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
SLOW_TESTS = %w[
  test/sqlite_raw_oracle_test.rb
  test/mcp_invocation_test.rb
  test/agent_session_kill_matrix_test.rb
  test/sqlite_convergence_probe_test.rb
  test/mcp_supervisor_test.rb
  test/sqlite_scenario_driver_test.rb
  test/m2_evidence_test.rb
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


LIB_FLAGS = %w[
  tamoz-core tamoz-graph tamoz-sqlite tamoz-tools tamoz-agent
  tamoz-evals tamoz-mcp tamoz-scheduler tamoz-stream
].map { |name| "-Igems/#{name}/lib" }.join(" ").freeze

# Measured wall-clock seconds per file (`rake test_profile` regenerates these).
# Used to BIN-PACK the shards: round-robin left one worker trailing a 23-second
# file while others idled, which set the floor for the whole run.
#
# Anything absent uses DEFAULT_WEIGHT — being wrong about a fast file costs
# almost nothing, whereas being wrong about a slow one costs the whole run, so
# only the slow tail needs to be accurate.
DEFAULT_WEIGHT = 0.7
TEST_WEIGHTS = {
  "test/sqlite_raw_oracle_test.rb" => 23.4,
  "test/mcp_invocation_test.rb" => 21.1,
  "test/agent_session_kill_matrix_test.rb" => 20.9,
  "test/sqlite_convergence_probe_test.rb" => 16.2,
  "test/mcp_supervisor_test.rb" => 12.1,
  "test/sqlite_scenario_driver_test.rb" => 7.3,
  "test/m2_evidence_test.rb" => 6.4,
  "test/websearch_invocation_test.rb" => 4.4,
  "test/agent_scorecard_test.rb" => 3.7,
  "test/memory_treatment_profile_test.rb" => 3.2,
  "test/m1_evidence_test.rb" => 3.0,
  "test/agent_mcp_capability_source_test.rb" => 2.5,
  "test/mcp_catalog_test.rb" => 2.4,
  "test/graph_execution_test.rb" => 2.4,
  "test/subprocess_runner_test.rb" => 2.1,
  "test/agent_worker_mcp_test.rb" => 1.5,
  "test/agent_session_test.rb" => 1.5,
  "test/agent_cli_test.rb" => 1.4
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
    sh ENOLA_BIN, 'check', '--fail-on=cycles,layers', '--min-confidence=0.8', '.'
  end
end

desc 'The full quality gate: rubocop (with TODO drift), reek, coverage, architecture'
task quality: ['quality:rubocop', 'quality:reek', 'quality:coverage', 'quality:architecture']

desc "The everyday gate — fast, and honest about what it skips"
task ci: ['design:validate', :syntax, :test_fast, 'quality:rubocop_gate', 'quality:reek', 'quality:architecture'] do
  skipped = (SLOW_TESTS + SERIAL_TESTS).length
  warn ""
  warn "ci: #{skipped} slow files were NOT run (subprocess, crash-matrix, packaging,"
  warn "    evidence). Run `rake ci_full` before committing anything touching"
  warn "    durability, MCP, packaging or the committed evidence artifacts."
end

# The complete gate. Stays SERIAL for the test phase: a parallel run is one
# contended process table away from a false failure, and the gate that decides
# whether something ships should not have that property.
desc "The complete gate — nothing skipped (use before committing)"
task ci_full: ["design:validate", :syntax, :test, :test_slow]

desc "The complete gate with the test phase sharded across processes"
task ci_fast: ["design:validate", :syntax, :test_parallel]

task default: :ci
