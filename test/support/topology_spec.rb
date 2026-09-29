# frozen_string_literal: true

require 'timeout'
require_relative 'subagent_spec'

# The topology quality bar (docs/subagent-topologies-2026-09-29/QUALITY_BAR.md) as an executable specification, on the
# same met-or-pending rule as SubagentSpec.
module TopologySpec
  include SubagentSpec

  MET = %w[].freeze
  PENDING = Hash.new { |hash, key| hash[key] = [] }

  Minitest.after_run do
    PENDING.sort.each { |row, details| warn "topology spec PENDING #{row}: #{details.uniq.join(' | ')}" }
  end

  def spec_row(row)
    yield
    flunk "#{row} now holds: add it to TopologySpec::MET" unless MET.include?(row)
  rescue Minitest::Skip
    raise
  rescue *SubagentSpec::GAP_ERRORS => e
    raise if MET.include?(row) || e.message.include?('add it to TopologySpec::MET')

    detail = e.message.lines.first.to_s.strip[0, 160]
    PENDING[row] << detail
    skip "PENDING GAP #{row}: #{e.class}: #{detail}"
  end

  # Children may run at once, so each child's script is chosen by the marker its brief carries, and only the
  # bookkeeping is locked: a lock around the whole call would serialise the children this team exists to overlap.
  class TopologyTeam < SubagentFixtures::ScriptedTeam
    def initialize(parent:, children: {}, **)
      super(parent:, **)
      @scripts = children.transform_values(&:dup)
      @lock = Mutex.new
    end

    def converse(stage:, messages:, tools:, tool_choice:)
      return super if self.class.parent_side?(tools) || stage != :work_step

      bytes = @lock.synchronize do
        build_conversation(messages:, tools:, tool_choice:).tap do |built|
          requests << built
        end
      end
      turn = child_turn(messages)
      turn = turn.call(messages) if turn.respond_to?(:call)
      @lock.synchronize { stages << stage }
      response(turn, bytes, messages)
    end

    private

    def child_turn(messages)
      text = messages.map { |message| message['content'].to_s }.join("\n")
      @lock.synchronize do
        marker = @scripts.keys.find { |key| text.include?(key) } || raise("no child script for #{text[0, 120]}")
        @scripts.fetch(marker).shift || raise("no scripted child turn left for #{marker}")
      end
    end
  end

  # Each child waits for every other child's first call to have started: only concurrent children get through.
  def overlapping(markers)
    arrived = markers.to_h { |marker| [marker, Queue.new] }
    markers.to_h do |marker|
      [marker, lambda do |_messages|
        (markers - [marker]).each { |other| arrived.fetch(other) << marker }
        Timeout.timeout(5) { (markers.length - 1).times { arrived.fetch(marker).pop } }
        { calls: [read_call('lib/a.rb')] }
      end]
    end
  end

  def fanout_call(briefs, role: 'explore') = ['delegate', { 'role' => role, 'briefs' => briefs }]

  def marked_brief(marker) = "#{marker}: find where invoice totals are rounded and report each file:line."

  def answer(marker, text = "#{marker} found lib/billing/total.rb:1 half-even.")
    [{ calls: [read_call('lib/billing/total.rb')] }, { content: text }]
  end

  def topology_run(parent:, children:, files: EXPLORE_FILES, **session_options)
    with_work_workspace(files:) do |root, adapter|
      script = ->(value) { value.respond_to?(:call) ? value.call(root) : value }
      model = TopologyTeam.new(parent: script.call(parent), children: script.call(children))
      outcome = subagent_session(model:, root:, adapter:, **session_options)
                .start(TASK, thread: 'work', request_id: 'work-1')
      yield outcome, model, root, adapter
    end
  end
end
