# frozen_string_literal: true

require_relative 'subagent_fixtures'
require_relative 'memory_spec'
require_relative 'approval_case'

# The subagent quality bar (docs/subagents-2026-09-29/QUALITY_BAR.md) as an executable specification: a row in MET must
# hold; any other row asserts its target and reports a PENDING gap while Tamoz falls short.
module SubagentSpec
  include SubagentFixtures
  include ApprovalCase

  MET = %w[B9].freeze
  PENDING = Hash.new { |hash, key| hash[key] = [] }

  Minitest.after_run do
    next if PENDING.empty?

    PENDING.sort.each { |row, details| warn "subagent spec PENDING #{row}: #{details.uniq.join(' | ')}" }
  end

  # Only a failed assertion or a Tamoz refusal is a gap. Anything else is a bug in the test and propagates, so every
  # row asserts a precondition (the child ran, the API exists) before it reaches for what the child produced.
  GAP_ERRORS = [Minitest::Assertion, Tamoz::Error].freeze

  def spec_row(row)
    yield
    flunk "#{row} now holds: add it to SubagentSpec::MET" unless MET.include?(row)
  rescue Minitest::Skip
    raise
  rescue *GAP_ERRORS => e
    raise if MET.include?(row) || e.message.include?('add it to SubagentSpec::MET')

    detail = e.message.lines.first.to_s.strip[0, 160]
    PENDING[row] << detail
    skip "PENDING GAP #{row}: #{e.class}: #{detail}"
  end

  class MemoryFixtures
    include MemorySpec

    def project(root) = Tamoz::Agent::Memory::Surface.project_scope(root)

    def seed_knowledge(engine, root, statement) = owner_fact(engine, statement, project: project(root))

    def count(engine, layer)
      table_count(engine.adapter, "SELECT COUNT(DISTINCT memory_id) FROM tamoz_memory_index WHERE layer = '#{layer}'",
                  [])
    end
  end

  def with_memory_workspace(files: EXPLORE_FILES)
    with_work_workspace(files:) do |root, adapter|
      Dir.mktmpdir('tamoz-subagent-memory') do |directory|
        fixtures = MemoryFixtures.new
        engine, memory_adapter = fixtures.memory_engine_at(directory, clock: -> { Time.now })
        yield root, adapter, engine, fixtures
      ensure
        memory_adapter&.close
      end
    end
  end
end
