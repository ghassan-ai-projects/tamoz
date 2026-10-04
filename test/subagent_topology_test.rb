# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require_relative 'support/topology_spec'

# Topology bar rows P (fan-out), V (review) and N (the harness's delegation notes) through the real work route with
# scripted models: these prove the mechanism, never that a topology helps a model (that is the real-model pack).
class SubagentTopologyTest < Minitest::Test
  include TopologySpec

  MARKERS = %w[ALPHA-7 BRAVO-7 CHARLIE-7].freeze

  def fanout_of_three
    [{ calls: [fanout_call(MARKERS.map do |marker|
      marked_brief(marker)
    end)] }, { content: 'Merged.' }]
  end

  def all_answers = MARKERS.to_h { |marker| [marker, answer(marker)] }

  def test_a_fanout_runs_one_child_per_brief_and_no_child_sees_another_brief
    spec_row('P1') do
      topology_run(parent: fanout_of_three, children: all_answers) do |_outcome, model|
        assert_equal 6, model.child_requests.length
        MARKERS.each do |marker|
          own = model.child_requests.select { |bytes| bytes.include?(marker) }

          assert_equal 2, own.length
          (MARKERS - [marker]).each { |other| assert(own.none? { |bytes| bytes.include?(other) }) }
        end
      end
    end
  end

  def test_fanout_children_overlap_in_time
    spec_row('P2') do
      starts = overlapping(MARKERS)
      children = MARKERS.to_h { |marker| [marker, [starts.fetch(marker), { content: "#{marker} done." }]] }
      topology_run(parent: fanout_of_three, children:) do |_outcome, model|
        result = tool_messages(model.parent_requests.last).first

        assert_equal 3, result.scan(/^Subagent explore: done/).length, result
      end
    end
  end

  def test_one_bounded_result_with_a_section_per_brief_in_order
    spec_row('P3') do
      long = (1..300).map { |line| "finding #{line}: lib/billing/total.rb rounds half-even#{'.' * 20}" }.join("\n")
      children = all_answers.merge('CHARLIE-7' => answer('CHARLIE-7', long))
      topology_run(parent: fanout_of_three, children:) do |_outcome, model|
        result = tool_messages(model.parent_requests.last).first
        order = MARKERS.map { |marker| result.index("#{marker} found") || result.index('finding 1:') }

        assert_equal 3, result.scan(/^Subagent explore: /).length
        assert_equal order.sort, order
        assert_operator result.bytesize, :<=, 4096 + 1024
        assert_match(/artifact:sha256:[0-9a-f]{64}/, result)
        assert_equal 3, result.scan(/^Read: /).length
      end
    end
  end

  def test_the_turn_cap_counts_children_not_calls
    spec_row('P4') do
      briefs = ->(prefix, count) { (1..count).map { |index| marked_brief("#{prefix}#{index}") } }
      parent = [{ calls: [fanout_call(briefs.call('ONE-', 3))] }, { calls: [fanout_call(briefs.call('TWO-', 2))] },
                { calls: [delegate_call(marked_brief('SOLO-1'))] }, { content: 'Done.' }]
      children = %w[ONE-1 ONE-2 ONE-3 SOLO-1].to_h { |marker| [marker, answer(marker)] }
      topology_run(parent:, children:) do |_outcome, model|
        results = tool_messages(model.parent_requests.last)

        assert_match(/subagent limit reached/, results[1])
        refute(model.child_requests.any? { |bytes| bytes.include?('TWO-') })
        assert_match(/\ASubagent explore: done/, results[2])
        assert_equal 8, model.child_requests.length
      end
    end
  end

  def test_malformed_fanouts_are_refused_before_any_child_runs
    spec_row('P5') do
      five = (1..5).map { |index| marked_brief("F#{index}") }
      bad = [fanout_call([marked_brief('F1')]), fanout_call(five), fanout_call([marked_brief('F1'), 'x' * 5000]),
             ['delegate', { 'role' => 'explore', 'brief' => BRIEF, 'briefs' => [BRIEF, BRIEF] }],
             ['delegate', { 'role' => 'explore' }]]
      topology_run(parent: [{ calls: bad }, { content: 'Done.' }], children: {}) do |_outcome, model|
        results = tool_messages(model.parent_requests.last)

        assert_equal 5, results.length
        assert(results.all? { |text| text.start_with?('Error:') }, "not all refused: #{results.inspect}")
        assert_empty model.child_requests
      end
    end
  end

  # Dies once every child has finished but before the parent's gate node has checkpointed its result.
  class CrashAfterChildren
    Crash = WorkLoopFixtures::ScriptedConversationModel::Crash

    def initialize = @finished = 0

    def emit(type, _namespace, data = {}, **) # rubocop:disable Naming/PredicateMethod -- the emitter interface
      return false unless type == :task_end

      @finished += 1 if data['graph'] == 'tamoz.agent.subagent' && data['node'] == 'terminal'
      raise Crash, 'lost after the fan-out' if @finished == 3 && data['node'] == 'work_gate'

      false
    end
  end

  def test_a_rerun_gate_node_returns_the_stored_fanout_without_calling_a_child
    spec_row('P6') do
      with_work_workspace(files: EXPLORE_FILES) do |root, adapter|
        first = TopologyTeam.new(parent: fanout_of_three, children: all_answers)
        assert_raises(WorkLoopFixtures::ScriptedConversationModel::Crash) do
          subagent_session(model: first, root:, adapter:)
            .start(TASK, thread: 'work', request_id: 'work-1', emitter: CrashAfterChildren.new)
        end
        second = TopologyTeam.new(parent: [{ content: 'Merged.' }], children: {})
        outcome = subagent_session(model: second, root:, adapter:).recover(thread: 'work', request_id: 'work-1')

        assert_equal 6, first.child_requests.length
        assert_empty second.child_requests
        assert_equal 3, tool_messages(second.parent_requests.last).first.scan(/^Subagent explore: done/).length
        assert_equal 'answered', outcome.state.fetch(:terminal_reason)
      end
    end
  end

  def test_each_child_has_its_own_execution_and_journal
    spec_row('P7') do
      topology_run(parent: fanout_of_three, children: all_answers) do |_outcome, _model, _root, adapter|
        by_execution = child_journal(adapter).group_by { |row| row.fetch(:execution_id) }

        assert_equal 3, by_execution.length
        by_execution.each_value do |rows|
          assert_equal(2, rows.count { |row| row.fetch(:operation) == 'model.converse.work_step' })
        end
      end
    end
  end

  def edit_then(delegation)
    lambda do |root|
      [{ calls: [plan_call(paths: %w[lib], checks: [])] }, { calls: [read_call('lib/a.rb')] },
       { calls: [patch_call(root, 'lib/a.rb', 'A = 1', 'A = 2')] }, { calls: [delegation] }, { content: 'Reviewed.' }]
    end
  end

  def review_call(brief) = ['delegate', { 'role' => 'review', 'brief' => brief }]

  def test_the_review_child_is_handed_the_paths_the_parent_changed
    spec_row('V1') do
      parent = edit_then(review_call('REVIEW-1: check lib/b.rb for defects.'))
      children = { 'REVIEW-1' => [{ calls: [read_call('lib/a.rb')] }, { content: 'No defects found.' }] }
      topology_run(parent:, children:) do |_outcome, model|
        assert_child_ran(model)
        opening = JSON.parse(model.child_requests.first).fetch('messages').last.fetch('content')
        changed = opening.lines.find { |line| line.start_with?('Files changed in this turn:') }

        refute_nil changed, opening
        assert_includes changed, 'lib/a.rb'
        refute_includes changed, 'lib/b.rb'
        assert_match(/\ASubagent review: done/, tool_messages(model.parent_requests.last).last)
      end
    end
  end

  def test_a_review_before_any_change_is_refused
    spec_row('V2') do
      parent = [{ calls: [review_call('REVIEW-2: check the change.')] }, { content: 'Nothing to review.' }]
      topology_run(parent:, children: {}) do |_outcome, model|
        assert_match(/\AError: .*no change/, tool_messages(model.parent_requests.last).first)
        assert_empty model.child_requests
      end
    end
  end

  def test_the_review_child_reads_only_under_the_review_prompt
    spec_row('V3') do
      parent = edit_then(review_call('REVIEW-3: check the change.'))
      children = { 'REVIEW-3' => [{ content: 'No defects found.' }] }
      topology_run(parent:, children:) do |_outcome, model|
        assert_child_ran(model)
        request = JSON.parse(model.child_requests.first)

        assert_equal %w[glob list_directory read_file recall_output search_text], wire_names(model.child_requests.first)
        assert_includes request.fetch('messages').first.fetch('content'), 'Your role: review'
      end
    end
  end

  def many_files = EXPLORE_FILES.merge((1..12).to_h { |index| ["lib/m#{index}.rb", "M#{index} = #{index}\n"] })

  def reading(count) = (1..count).map { |index| { calls: [read_call("lib/m#{index}.rb")] } }

  def test_after_enough_reads_one_note_is_appended_and_earlier_bytes_do_not_move
    spec_row('N1') do
      nudge
      limit = nudge_reads
      topology_run(parent: reading(limit + 2) + [{ content: 'Read.' }], children: {}, files: many_files) do |_o, model|
        requests = model.parent_requests.map { |bytes| JSON.parse(bytes).fetch('messages') }
        noted = requests.index { |messages| messages.any? { |message| message['content'].to_s.include?(nudge) } }

        refute_nil noted
        assert_equal nudge, requests.fetch(noted).last.fetch('content')
        assert_equal requests.fetch(noted - 1), requests.fetch(noted).first(requests.fetch(noted - 1).length)
        assert_equal(1, requests.last.count { |message| message['content'].to_s.include?(nudge) })
      end
    end
  end

  def test_the_window_trigger_fires_once
    spec_row('N2') do
      nudge
      big = EXPLORE_FILES.merge('lib/big.rb' => big_file)
      parent = read_lines(5) + [{ content: 'Read.' }]
      with_work_workspace(files: big) do |root, adapter|
        model = TopologyTeam.new(parent:, children: {}, window: 12_000)
        subagent_session(model:, root:, adapter:, harness: { context_policy: { max_inline_bytes: 4096 } })
          .start(TASK, thread: 'work', request_id: 'work-1')
        last = JSON.parse(model.parent_requests.last).fetch('messages')

        assert_equal(1, last.count { |message| message['content'].to_s.include?(nudge) })
      end
    end
  end

  def test_a_large_opening_alone_never_triggers_the_note
    spec_row('N2') do
      task = "Answer yes. #{'context ' * 1500}"
      with_work_workspace(files: EXPLORE_FILES) do |root, adapter|
        model = TopologyTeam.new(parent: [{ content: 'yes' }], children: {}, window: 12_000)
        subagent_session(model:, root:, adapter:).start(task, thread: 'work', request_id: 'work-1')

        assert_equal 1, model.requests.length
        refute_includes model.requests.first, nudge
      end
    end
  end

  def test_no_note_after_a_delegation_or_with_subagents_off
    spec_row('N3') do
      nudge
      limit = nudge_reads
      delegated = [{ calls: [delegate_call(marked_brief('EARLY-1'))] }] + reading(limit + 2) + [{ content: 'Read.' }]

      topology_run(parent: delegated, children: { 'EARLY-1' => answer('EARLY-1') }, files: many_files) do |_o, model|
        refute(model.parent_requests.any? { |bytes| bytes.include?(nudge) })
      end
      topology_run(parent: reading(limit + 2) + [{ content: 'Read.' }], children: {}, files: many_files,
                   subagents: []) do |_o, model|
        refute(model.requests.any? { |bytes| bytes.include?(nudge) })
      end
    end
  end

  private

  def nudge
    assert_path_exists File.join(Tamoz::Harness::PromptPack::DIRECTORY, 'delegate_nudge.md')
    Tamoz::Harness::PromptPack.fetch('delegate_nudge')
  end

  def nudge_reads
    assert_respond_to Tamoz::Harness::SubagentRoles.shipped, :nudge_reads
    Tamoz::Harness::SubagentRoles.shipped.nudge_reads
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
