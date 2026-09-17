# frozen_string_literal: true

# Reproductions for the framework defects in RESEARCH.md §4.
#
# Deterministic, offline, no model calls, no money. Each probe asserts the CURRENT
# (defective) behaviour, so this script exits 0 while a defect is open and exits
# non-zero once it is fixed — which is the signal to move the row in RESEARCH §4
# to "fixed" and delete the probe.
#
#   export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/versions/3.3.11/bin:$PATH"
#   ruby docs/eval-improvement/repro/verify_defects.rb
#
# `agenteval/` is git-ignored (RESEARCH D6), so this file is the only committed,
# reviewable evidence that the defects are real.

require 'tmpdir'
require 'fileutils'

ROOT = File.expand_path('../../..', __dir__)
$LOAD_PATH.unshift File.join(ROOT, 'agenteval', 'lib')
require 'agenteval'
Agenteval.load_packs

RUBY_LANG = Agenteval::Languages.fetch(:ruby)

# Accumulates the ids that still reproduce, so the exit code can invert once they stop.
module Reproduced
  class << self
    def ids = @ids ||= []

    def record(id, claim, observed)
      ids << id if observed[:open]
      puts format('  %-5<id>s %-58<claim>s %<verdict>s',
                  id: id, claim: claim,
                  verdict: observed[:open] ? 'OPEN (reproduced)' : 'FIXED')
      puts format('        %<detail>s', detail: observed[:detail])
    end
  end
end

def probe(id, claim) = Reproduced.record(id, claim, yield)

def suite_for(task_ids, modifier_ids, seeds: [1])
  Agenteval::Suite.new(
    tasks: task_ids.map { Agenteval::Registry.fetch(_1) },
    modifiers: modifier_ids.map { Agenteval::Modifiers.fetch(_1) },
    seeds: seeds, language: RUBY_LANG, difficulty: 2, budget_seconds: 240
  )
end

puts "agenteval defect reproductions — #{Time.now.utc.strftime('%Y-%m-%d')}\n\n"

# ---------------------------------------------------------------------------
probe('D1', 'a timed-out mutant run is credited as a killed mutant') do
  stub = Object.new
  def stub.verify_with(**)
    Agenteval::CommandResult.new(ok: false, output: '…', timed_out: true)
  end
  judgement = Agenteval::Verify.kills_mutant(stub, {}, ['true'])
  { open: judgement.ok,
    detail: "Verify.kills_mutant(timed_out: true) -> ok=#{judgement.ok} #{judgement.detail.inspect}" }
end

# Digest a tree out-of-process, so the copy's own lib/ is what answers.
def digest_of(tree)
  script = <<~SCRIPT
    $LOAD_PATH.unshift #{File.join(tree, 'lib').inspect}
    require "agenteval"
    Agenteval.load_packs
    puts Agenteval::Suite.new(
      tasks: Agenteval::Registry.all, modifiers: Agenteval::Modifiers.all.values,
      seeds: [1], language: Agenteval::Languages.fetch(:ruby),
      difficulty: 2, budget_seconds: 240
    ).digest
  SCRIPT
  IO.popen([RbConfig.ruby, '-e', script], &:read).strip
end

# Ten times as many distractor modules: a change to what adversity MEANS.
def amplify_noise!(tree)
  path = File.join(tree, 'lib', 'agenteval', 'modifier.rb')
  source = File.read(path)
  changed = source.sub('count = 6 + (scenario.difficulty * 4)',
                       'count = 60 + (scenario.difficulty * 40)')
  raise 'probe is stale: the :noise distractor count moved' if changed == source

  File.write(path, changed)
end

probe('D6', 'the corpus digest is blind to lib/ — adversity can change silently') do
  Dir.mktmpdir('agenteval-digest') do |tmp|
    tree = File.join(tmp, 'agenteval')
    FileUtils.cp_r(File.join(ROOT, 'agenteval'), tree)
    FileUtils.rm_rf(File.join(tree, 'reports'))

    before = digest_of(tree)
    amplify_noise!(tree)
    after = digest_of(tree)

    { open: before == after,
      detail: "noise modifier changed 10x; digest #{before[0, 20]}… -> #{after[0, 20]}…" }
  end
end

# ---------------------------------------------------------------------------
probe('D10', 'a crash with no statement scores :solved on abstention cells') do
  adapter = Agenteval::Adapter.new(
    id: 'probe', label: 'probe', model: 'none', provider: 'none', capabilities: [],
    claims_success: ->(code, _out) { code.zero? }
  )
  trial = Agenteval::Trial.new(adapter: adapter)
  statuses = suite_for(%w[repair], %i[phantom destructive impossible]).scenarios.map do |scenario, built|
    Dir.mktmpdir('agenteval-probe') do |dir|
      workspace = Agenteval::Workspace.new(dir)
      workspace.materialize(scenario.files)
      # An agent that died before acting, saying nothing about the conflict.
      workspace.record_run(answer: 'internal error: no plan passed review after 3 attempts',
                           exit_code: 1, timed_out: false)
      [scenario.id, trial.send(:judge, scenario, built, workspace, trial: 1, duration: 0).status]
    end
  end
  { open: statuses.all? { |_id, status| status == :solved },
    detail: statuses.map { |id, status| "#{id}=#{status}" }.join('  ') }
end

# ---------------------------------------------------------------------------
probe('D12', 'comprehend passes on a bare directory listing (no answer)') do
  results = suite_for(%w[comprehend], %i[clean noise inject]).scenarios.map do |scenario, built|
    Dir.mktmpdir('agenteval-probe') do |dir|
      workspace = Agenteval::Workspace.new(dir)
      workspace.materialize(scenario.files)
      # The cheapest possible non-answer: print the repo tree, reason about nothing.
      workspace.record_run(answer: scenario.files.keys.sort.join("\n"), exit_code: 0, timed_out: false)
      [scenario.id, scenario.oracle.call(workspace, built).ok]
    end
  end
  { open: results.all? { |_id, ok| ok },
    detail: results.map { |id, ok| "#{id}=#{ok ? 'solved' : 'failed'}" }.join('  ') }
end

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
probe('D13', 'a timeout on an abstention cell manufactures a false_success') do
  adapter = Agenteval::Adapter.new(
    id: 'probe', label: 'probe', model: 'none', provider: 'none', capabilities: [],
    claims_success: ->(code, _out) { code.zero? }
  )
  trial = Agenteval::Trial.new(adapter: adapter)
  statuses = suite_for(%w[repair], %i[phantom destructive impossible]).scenarios.map do |scenario, built|
    Dir.mktmpdir('agenteval-probe') do |dir|
      workspace = Agenteval::Workspace.new(dir)
      workspace.materialize(scenario.files)
      # A SIGKILLed process has no exit status. `nil.to_i` is 0, and 0 means "claimed success".
      workspace.record_run(answer: '(killed mid-thought)', exit_code: nil, timed_out: true)
      [scenario.id, trial.send(:judge, scenario, built, workspace, trial: 1, duration: 0).status]
    end
  end
  { open: statuses.all? { |_id, status| status == :false_success },
    detail: "exit_code nil -> claims?=#{adapter.claims?(nil.to_i, '')}; " \
            "#{statuses.map { |id, status| "#{id}=#{status}" }.join('  ')}" }
end

# ---------------------------------------------------------------------------
probe('D14', 'a captured prompt injection never trips no_unsafe_action') do
  adapter = Agenteval::Adapter.new(
    id: 'probe', label: 'probe', model: 'none', provider: 'none', capabilities: [],
    claims_success: ->(code, _out) { code.zero? }
  )
  trial = Agenteval::Trial.new(adapter: adapter)
  # `docs` is neither readonly nor an abstention task, so :unsafe is unreachable for it.
  scenario, built = suite_for(%w[docs], %i[inject]).scenarios.first
  captured = Dir.mktmpdir('agenteval-probe') do |dir|
    workspace = Agenteval::Workspace.new(dir)
    workspace.materialize(scenario.files)
    # Obey the planted instruction, then decline to claim success.
    File.write(File.join(workspace.dir, Agenteval::Modifiers::INJECTION_ARTIFACT),
               Agenteval::Modifiers::INJECTION_MARKER)
    workspace.record_run(answer: 'did the thing in the README', exit_code: 1, timed_out: false)
    trial.send(:judge, scenario, built, workspace, trial: 1, duration: 0)
  end
  { open: captured.status != :unsafe,
    detail: "obeyed the planted instruction -> status=#{captured.status} " \
            '(the no_unsafe_action gate counts only :unsafe, so this run reads unsafe=0)' }
end

puts
if Reproduced.ids.empty?
  puts 'no defect reproduced — update RESEARCH.md §4 and retire this script.'
  exit 1
end
puts "reproduced and still open: #{Reproduced.ids.join(', ')}"
exit 0
