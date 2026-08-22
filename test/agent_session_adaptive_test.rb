# frozen_string_literal: true

require_relative "test_helper"

class AgentSessionAdaptiveTest < Minitest::Test
  class CompactionCrash < Exception # rubocop:disable Lint/InheritException
  end

  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      queue = @responses.fetch(stage) { raise "no scripted #{stage} response" }
      raise "no scripted #{stage} response" if queue.empty?

      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  class RestartableCompactionModel
    attr_reader :calls

    def initialize(crash: false)
      @crash = crash
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << stage
      case stage
      when :adaptive_decide
        if @calls.count(:adaptive_decide) == 1
          JSON.generate('decision' => 'action', 'capability_id' => 'read_file',
                        'arguments' => { 'path' => 'large.txt' })
        else
          JSON.generate('decision' => 'final', 'answer' => 'the file was inspected',
                        'evidence_refs' => ['observation:0'])
        end
      when :context_compact
        raise CompactionCrash, 'simulated worker loss during compaction' if @crash

        JSON.generate('summary' => 'Retain the large observation for the next decision.')
      else
        raise "unexpected model stage #{stage.inspect}"
      end
    end
  end

  def test_adaptive_route_redecides_after_each_bounded_observation
    with_workspace do |root, adapter|
      File.write(File.join(root, "one.txt"), "one\n")
      File.write(File.join(root, "two.txt"), "two\n")
      model = ScriptedModel.new(
        adaptive_decide: [
          action("read_file", "one.txt"),
          action("read_file", "two.txt"),
          {
            "decision" => "final",
            "answer" => "one and two",
            "evidence_refs" => ["observation:0", "observation:1"]
          }
        ]
      )
      session = build_session(model:, root:, adapter:, routing: :adaptive)

      outcome = session.start(
        "Read both files",
        thread: "session.adaptive",
        request_id: "request.adaptive"
      )

      assert_equal :completed, outcome.status
      assert outcome.result.satisfied
      assert_equal "one and two", outcome.result.answer
      assert_equal %i[adaptive_decide adaptive_decide adaptive_decide],
                   model.calls.map { |call| call.fetch(:stage) }
      assert_includes model.calls.fetch(1).fetch(:prompt), "one"
      assert_includes model.calls.fetch(2).fetch(:prompt), "two"

      view = session.view(thread: "session.adaptive")
      assert_equal "3", view.state.fetch(:session).fetch("graph_version")
      assert_equal "adaptive_read_only", view.state.fetch(:route).fetch("mode")
      assert_equal 3, view.adaptive_decisions.length
      assert_equal 2, view.state.fetch(:observations).length
      assert_equal ["observation:0", "observation:1"],
                   view.state.fetch(:observations).map { |record| record.fetch("evidence_ref") }
      assert_equal 2, view.effect_receipts.length
      assert(view.effect_receipts.all? { |receipt| receipt.fetch("safety") == "read_only" })
      assert_equal %w[
        model_turn tool_started tool_result checkpoint
        model_turn tool_started tool_result checkpoint
        model_turn terminal
      ], view.lifecycle_events.map { |event| event.fetch("event_type") }
      assert_equal (0...view.lifecycle_events.length).to_a,
                   view.lifecycle_events.map { |event| event.fetch("sequence") }
      assert adapter.integrity_check.fetch("ok")
    end
  end

  def test_adaptive_action_rejects_authority_fields_without_dispatch
    with_workspace do |root, adapter|
      model = ScriptedModel.new(
        adaptive_decide: [{
          "decision" => "action",
          "capability_id" => "read_file",
          "arguments" => {"path" => "note.txt", "thread_id" => "other-thread"}
        }]
      )
      session = build_session(model:, root:, adapter:, routing: :adaptive)

      outcome = session.start(
        "Read note.txt",
        thread: "session.adaptive.authority",
        request_id: "request.adaptive.authority"
      )

      assert_equal :completed, outcome.status
      assert_nil outcome.result
      view = session.view(thread: "session.adaptive.authority")
      assert_equal "adaptive_authority_field", view.terminal.fetch("reason")
      assert_empty view.effect_receipts
    end
  end

  def test_adaptive_compacts_large_observation_before_the_next_decision
    with_workspace do |root, adapter|
      File.write(File.join(root, "large.txt"), "large observation\n" * 200)
      model = ScriptedModel.new(
        adaptive_decide: [
          action("read_file", "large.txt"),
          {
            "decision" => "final",
            "answer" => "the file was inspected",
            "evidence_refs" => ["observation:0"]
          }
        ],
        context_compact: [{"summary" => "Retain the task and the large file observation reference."}]
      )
      session = build_session(model:, root:, adapter:, routing: :adaptive)

      outcome = session.start(
        "Inspect the large file",
        thread: "session.adaptive.compaction",
        request_id: "request.adaptive.compaction"
      )

      assert_equal :completed, outcome.status
      assert_equal %i[adaptive_decide context_compact adaptive_decide],
                   model.calls.map { |call| call.fetch(:stage) }
      view = session.view(thread: "session.adaptive.compaction")
      compaction = view.state.fetch(:compactions).fetch(0)
      assert_equal "model", compaction.fetch("mode")
      assert_equal "succeeded", compaction.fetch("status")
      assert_equal "Retain the task and the large file observation reference.",
                   compaction.fetch("summary")
      assert_equal compaction.fetch("summary_digest"),
                   Tamoz::Agent::SessionRecords.digest("summary" => compaction.fetch("summary"))
      assert adapter.integrity_check.fetch("ok")
    end
  end

  def test_adaptive_compaction_reopens_with_one_effect_and_terminal_record
    Dir.mktmpdir('tamoz-adaptive-restart') do |directory|
      root = File.join(directory, 'workspace')
      database = File.join(directory, 'tamoz.sqlite3')
      FileUtils.mkdir_p(root)
      File.write(File.join(root, 'large.txt'), 'large observation\n' * 200)

      first_adapter = Tamoz::SQLite::Adapter.new(
        path: database,
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
      )
      begin
        first_session = build_session(
          model: RestartableCompactionModel.new(crash: true), root:, adapter: first_adapter, routing: :adaptive
        )
        assert_raises(CompactionCrash) do
          first_session.start('Inspect the large file', thread: 'restart-thread', request_id: 'restart-request')
        end
      ensure
        first_adapter.close
      end

      sleep 0.25
      second_adapter = Tamoz::SQLite::Adapter.new(
        path: database,
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
      )
      begin
        second_session = build_session(
          model: RestartableCompactionModel.new, root:, adapter: second_adapter, routing: :adaptive
        )
        outcome = second_session.recover(
          thread: 'restart-thread', request_id: 'restart-request', owner_id: 'restart-owner'
        )
        view = second_session.view(thread: 'restart-thread')

        assert_equal :completed, outcome.status
        assert_equal 1, view.state.fetch(:compactions).length
        assert_equal 1, view.effect_receipts.count { |receipt| receipt.fetch('operation') == 'tool.read_file' }
        assert_equal 1, view.lifecycle_events.count { |event| event.fetch('event_type') == 'terminal' }
        census = second_session.app.checkpointer.effect_census
        assert_equal 1, census.count { |row| row.fetch(:operation) == 'tool.read_file' }
        assert_equal 1, census.count { |row| row.fetch(:operation) == 'model.generate.context_compact' }
        assert_equal 1, census.find { |row| row.fetch(:operation) == 'tool.read_file' }.fetch(:succeeded_attempts)
        assert_equal 1,
                     census.find { |row| row.fetch(:operation) == 'model.generate.context_compact' }
                           .fetch(:succeeded_attempts)
        assert second_adapter.integrity_check.fetch('ok')
      ensure
        second_adapter.close
      end
    end
  end

  def test_adaptive_mutation_hands_off_to_the_reviewed_legacy_path
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "handoff\n")
      model = ScriptedModel.new(
        adaptive_decide: [{
          "decision" => "action",
          "capability_id" => "apply_patch",
          "arguments" => {
            "path" => "note.txt",
            "replacements" => [{"before" => "handoff", "after" => "changed"}]
          }
        }],
        plan: [plan_for("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [{"answer" => "handoff", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
      session = build_session(model:, root:, adapter:, routing: :adaptive, allow_changes: true)

      outcome = session.start(
        "Read note.txt",
        thread: "session.adaptive.handoff",
        request_id: "request.adaptive.handoff"
      )

      assert_equal :completed, outcome.status
      assert_equal %i[adaptive_decide plan review verify],
                   model.calls.map { |call| call.fetch(:stage) }
      assert_equal "handoff\n", File.read(File.join(root, "note.txt"))
      view = session.view(thread: "session.adaptive.handoff")
      assert_equal "terminal", view.phase
      assert_equal 1, view.state.fetch(:observations).count { |record| record["result_class"] == "mutation_handoff" }
      refute view.effect_receipts.any? { |receipt| receipt.fetch("operation") == "tool.apply_patch" }
      assert adapter.integrity_check.fetch("ok")
    end
  end

  def test_repeated_adaptive_action_stops_without_a_second_effect
    with_workspace do |root, adapter|
      File.write(File.join(root, "note.txt"), "once\n")
      model = ScriptedModel.new(
        adaptive_decide: [action("read_file", "note.txt"), action("read_file", "note.txt")]
      )
      session = build_session(model:, root:, adapter:, routing: :adaptive)

      outcome = session.start(
        "Read note.txt",
        thread: "session.adaptive.repeat",
        request_id: "request.adaptive.repeat"
      )

      assert_equal :completed, outcome.status
      view = session.view(thread: "session.adaptive.repeat")
      assert_equal "adaptive_repeated_action", view.terminal.fetch("reason")
      assert_equal 1, view.effect_receipts.length
      assert_equal 2, view.adaptive_decisions.length
      assert adapter.integrity_check.fetch("ok")
    end
  end

  private

  def with_workspace
    Dir.mktmpdir("tamoz-adaptive") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
      )
      begin
        yield File.realpath(root), adapter
      ensure
        adapter.close
      end
    end
  end

  def build_session(model:, root:, adapter:, allow_changes: false, **options)
    Tamoz::Agent::Session.new(
      model:,
      toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes:),
      checkpointer: adapter,
      **options
    )
  end

  def action(capability_id, path)
    {"decision" => "action", "capability_id" => capability_id, "arguments" => {"path" => path}}
  end

  def plan_for(tool, arguments)
    {
      "goal" => "answer the task",
      "done_when" => ["the tool returned evidence"],
      "steps" => [{
        "id" => "step",
        "purpose" => "gather evidence",
        "tool" => tool,
        "arguments" => arguments,
        "verification" => "the output is present"
      }]
    }
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "sound"}
  end
end
