# frozen_string_literal: true

require_relative "test_helper"

# Phase 3 work item 1: typed context-control semantics at the session layer.
class SessionContextControlsTest < Minitest::Test
  CONTROLS = Tamoz::Agent::SessionContextControls
  RECORDS = Tamoz::Agent::SessionRecords
  THREAD = "thread.controls"

  class ScriptedModel
    attr_reader :calls

    def initialize(digest, summary)
      @digest = digest
      @summary = summary
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      phase = begin
        JSON.parse(prompt)["phase"]
      rescue StandardError
        nil
      end || "verify"
      @calls << "#{stage}:#{phase}"
      case stage
      when :plan then JSON.generate(phase == "discovery" ? discovery : action)
      when :review then JSON.generate("decision" => "accept", "issues" => [], "rationale" => "sound")
      when :context_compact then @summary
      else
        JSON.generate("answer" => "value is 2", "satisfied" => true, "evidence" => ["app.rb"])
      end
    end

    private

    def discovery
      {
        "goal" => "read the current value",
        "done_when" => ["app.rb has been read"],
        "steps" => [
          {
            "id" => "look",
            "purpose" => "read the file",
            "tool" => "read_file",
            "arguments" => {"path" => "app.rb"},
            "verification" => "the digest is present"
          }
        ]
      }
    end

    def action
      {
        "goal" => "set value to 2",
        "done_when" => ["app.rb contains value = 2 and the check passes"],
        "steps" => [
          {
            "id" => "edit",
            "purpose" => "apply the exact replacement",
            "tool" => "apply_patch",
            "arguments" => {
              "path" => "app.rb",
              "expected_sha256" => @digest,
              "before" => "value = 1",
              "after" => "value = 2"
            },
            "verification" => "the receipt reports the new digest"
          },
          {
            "id" => "check",
            "purpose" => "run the configured check",
            "tool" => "run_check",
            "arguments" => {"name" => "answer"},
            "verification" => "the check exits zero"
          }
        ]
      }
    end
  end

  def test_mutations_write_exactly_one_typed_audit_record_and_return_a_typed_projection
    with_session do |session, workspace|
      assert_equal 0, control_count(session)

      projection = session.set_reasoning_depth(thread: THREAD, request_id: "r.think", depth: "high")
      assert_kind_of CONTROLS::ContextControlProjection, projection
      document = projection.document
      assert_equal "think", document.fetch("control")
      assert_equal THREAD, document.fetch("thread_id")
      assert_equal({"reasoning_depth" => "high"}, projection.record.fetch("preferences"))
      assert_match(/\Asha256:[0-9a-f]{64}\z/, document.fetch("audit_digest"))
      RECORDS.load!(projection.record)

      session.set_answer_verbosity(thread: THREAD, request_id: "r.verbose", verbosity: "quiet")
      reset = session.reset_episode(thread: THREAD, request_id: "r.reset")

      assert_equal "reset", reset.document.fetch("control")

      controls = Array(latest_state(session)[:context_controls])
      assert_equal %w[think verbose reset], controls.map { |record| record.fetch("control") }
      assert_equal 3, controls.length
      controls.each { |record| RECORDS.load!(record) }
    end
  end

  def test_unknown_preference_values_fail_closed_and_mutate_nothing
    with_session do |session, workspace|
      before = control_count(session)

      assert_raises(ArgumentError) do
        session.set_reasoning_depth(thread: THREAD, request_id: "r.bad", depth: "maximum")
      end
      assert_raises(ArgumentError) do
        session.set_reasoning_depth(thread: THREAD, request_id: "r.bad", depth: 3)
      end
      error = assert_raises(ArgumentError) do
        session.set_answer_verbosity(thread: THREAD, request_id: "r.bad", verbosity: "loud")
      end
      assert_match(/quiet, normal, detailed/, error.message)

      assert_equal before, control_count(session)
    end
  end

  def test_preference_controls_are_consumed_by_episode_composition
    with_session do |session, workspace|
      session.set_reasoning_depth(thread: THREAD, request_id: "r.think", depth: "low")
      session.set_answer_verbosity(thread: THREAD, request_id: "r.verbose", verbosity: "detailed")

      frame = planning_context.compact_for(latest_state(session), :read_only).context

      assert_equal "low", frame.dig("directives", "reasoning_depth")
      assert_equal "detailed", frame.dig("directives", "answer_verbosity")
      assert_equal(
        {"reasoning_depth" => "low", "answer_verbosity" => "detailed"},
        session.context_report(thread: THREAD).document.fetch("preferences")
      )
    end
  end

  def test_reset_clears_episode_state_keeps_audit_history_and_continues_accounting
    with_session do |session, workspace|
      complete_turn(session)
      populated = latest_state(session)
      refute_empty Array(populated[:observations])
      refute_empty Array(populated[:plan_versions])
      refute_nil populated[:accepted_plan]
      tip_before = session.app.checkpointer.latest(thread_id: THREAD, namespace: [])
      history_before = session.app.history(thread: THREAD, limit: 100).length
      usage_before = session.usage_report(thread: THREAD).document

      reset = session.reset_episode(thread: THREAD, request_id: "r.reset")

      assert_equal "reset", reset.document.fetch("control")
      assert_operator reset.record.fetch("cleared_channels").length, :>, 0
      RECORDS.load!(reset.record)

      cleared = latest_state(session)
      assert_empty Array(cleared[:observations])
      assert_empty Array(cleared[:plan_versions])
      assert_nil cleared[:accepted_plan]
      assert_equal 0, cleared.fetch(:step_cursor)

      history = session.app.history(thread: THREAD, limit: 100)
      assert_equal history_before + 1, history.length
      preserved = session.app.state(thread: THREAD, checkpoint_id: tip_before.id).state
      assert_equal populated.fetch(:observations), preserved.fetch(:observations)

      usage_after = session.usage_report(thread: THREAD).document
      assert_equal usage_before.fetch("pinned_budgets"), usage_after.fetch("pinned_budgets")
      assert_equal usage_before.dig("observation_bytes", "ceiling"),
                   usage_after.dig("observation_bytes", "ceiling")
    end
  end

  # ONE durable stream serves both sides of the truncation contract. After
  # more than the admission window of prior turns, /reset declares exactly
  # the prefix it removed and the next composed frame keeps the newest
  # fragment visible — counts agree between /context and the composition.
  def test_reset_truncation_counts_and_composition_agree_over_one_stream
    with_session do |session, _workspace|
      checkpointer = session.app.checkpointer
      13.times do |index|
        checkpointer.enqueue_request(
          thread_id: THREAD, request_id: "seed.#{index}", operation: :turn,
          payload: { 'task' => "turn #{index}" }, delivery: :queue
        )
      end

      reset = session.reset_episode(thread: THREAD, request_id: "r.reset.window")
      assert_equal 13, reset.record.fetch("truncated_fragments")

      report = session.context_report(thread: THREAD).document
      transcript_layer = report.dig("layers", "transcript")
      assert_equal 13, transcript_layer.fetch("truncated_by_control")
      assert_equal 0, transcript_layer.fetch("fragments_visible")

      checkpointer.enqueue_request(
        thread_id: THREAD, request_id: "seed.after", operation: :turn,
        payload: { 'task' => 'turn after reset' }, delivery: :queue
      )
      frame = session.send(:conversation_transcript, thread_id: THREAD, request_id: "seed.after")
      stream = Tamoz::Agent::SessionPlanningContext.conversation_history(checkpointer, thread_id: THREAD)

      assert_equal ['turn after reset'], frame.map { |fragment| fragment.fetch('text') },
                   'the newest fragment stays visible after /reset'
      assert_equal transcript_layer.fetch('truncated_by_control'), stream.length - frame.length,
                   'exactly the declared number left the frame'
    end
  end

  # Two quick messages queue two turns; the first turn's transcript ends at itself.
  def test_a_turn_transcript_never_includes_a_message_queued_after_it
    with_session do |session, _workspace|
      checkpointer = session.app.checkpointer
      %w[first second].each do |text|
        checkpointer.enqueue_request(thread_id: THREAD, request_id: "burst.#{text}", operation: :turn,
                                     payload: { 'task' => text }, delivery: :queue)
      end

      frame = session.send(:conversation_transcript, thread_id: THREAD, request_id: 'burst.first')

      assert_equal ['first'], frame.map { |fragment| fragment.fetch('text') }
    end
  end

  # A second truncating control records its CUMULATIVE prefix, so fragments
  # hidden by the first control never re-enter a later frame.
  def test_a_second_reset_keeps_every_truncation_cumulative
    with_session do |session, _workspace|
      checkpointer = session.app.checkpointer
      5.times do |index|
        checkpointer.enqueue_request(
          thread_id: THREAD, request_id: "seed.a#{index}", operation: :turn,
          payload: { 'task' => "early #{index}" }, delivery: :queue
        )
      end
      session.reset_episode(thread: THREAD, request_id: 'r.reset.one')

      3.times do |index|
        checkpointer.enqueue_request(
          thread_id: THREAD, request_id: "seed.b#{index}", operation: :turn,
          payload: { 'task' => "late #{index}" }, delivery: :queue
        )
      end
      second = session.reset_episode(thread: THREAD, request_id: 'r.reset.two')

      assert_equal 8, second.record.fetch('truncated_fragments')

      checkpointer.enqueue_request(
        thread_id: THREAD, request_id: 'seed.c', operation: :turn,
        payload: { 'task' => 'newest turn' }, delivery: :queue
      )
      frame = session.send(:conversation_transcript, thread_id: THREAD, request_id: 'seed.c')

      assert_equal ['newest turn'], frame.map { |fragment| fragment.fetch('text') },
                   'no fragment hidden by an earlier control returns'
    end
  end

  def test_generation_addressing_helpers_are_pure_and_total
    assert_equal 1, CONTROLS.generation_of("plain")
    assert_equal 7, CONTROLS.generation_of("plain.g7")
  end

  def test_compact_pins_the_transcript_behind_digests_and_audits_before_after
    summary_text = "The user asked to change the value; it is done."
    Dir.mktmpdir("tamoz-context-compact") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      initial = ("#{'p' * 60}\n" * 300) + "value = 1\n"
      File.write(File.join(workspace, "app.rb"), initial)
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.sqlite3"))
      store = adapter.bind_artifact_store(tenant: "tenant.controls")
      begin
        model = ScriptedModel.new(Digest::SHA256.hexdigest(initial), JSON.generate("summary" => summary_text))
        session = Tamoz::Agent::Session.new(
          model:,
          toolbox: Tamoz::Agent::Toolbox.new(
            root: File.realpath(workspace),
            allow_changes: true,
            checks: {
              "answer" => [RbConfig.ruby, "-e",
                           %q{abort("wrong") unless File.read("app.rb").include?("value = 2")}]
            }
          ),
          checkpointer: adapter,
          artifact_store: store,
          artifact_tenant: "tenant.controls"
        )
        complete_turn(session)
        before_count = control_count(session)
        projection = session.compact_transcript(thread: THREAD, request_id: "r.compact")
        record = projection.record

        assert_equal before_count + 1, control_count(session)
        assert_equal "compact", record.fetch("control")
        assert_match(/\Asha256:[0-9a-f]{64}\z/, record.fetch("before_digest"))
        assert_match(/\Asha256:[0-9a-f]{64}\z/, record.fetch("after_digest"))
        refute_equal record.fetch("before_digest"), record.fetch("after_digest")
        assert_equal "model", record.fetch("compaction_mode")
        # The one CLI turn contributed its own user fragment; the episode's
        # verbose observation outputs are the bulk that got externalized.
        assert_equal 1, record.fetch("truncated_fragments")
        pinned = record.fetch("summary_digest")
        assert_equal RECORDS.digest("summary" => summary_text), pinned

        reference = record.fetch("artifact_refs").fetch(0)
        assert_equal "tenant.controls", reference.fetch("tenant")
        assert_equal "conversation_untrusted", reference.fetch("provenance")
        resolved = store.resolve(reference.fetch("digest"))
        assert_includes resolved.fetch("bytes"), "pppp"

        frame = planning_context.compact_for(latest_state(session), :read_only).context
        assert_equal pinned, frame.dig("conversation", "earlier_summary", "digest")
        assert_equal true, session.context_report(thread: THREAD).document
                                .dig("layers", "transcript", "earlier_summary_pinned")
      ensure
        adapter&.close
      end
    end
  end

  # The compact's effect identity derives from the DETERMINISTIC control
  # request id: replaying the same control request resolves to the recorded
  # receipt instead of calling the model a second time.
  def test_a_replayed_compact_request_id_resolves_the_recorded_receipt
    summary_text = "The user asked to change the value; it is done."
    Dir.mktmpdir("tamoz-context-compact-replay") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      initial = ("#{'p' * 60}\n" * 300) + "value = 1\n"
      File.write(File.join(workspace, "app.rb"), initial)
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.sqlite3"))
      store = adapter.bind_artifact_store(tenant: "tenant.replay")
      begin
        model = ScriptedModel.new(Digest::SHA256.hexdigest(initial), JSON.generate("summary" => summary_text))
        session = Tamoz::Agent::Session.new(
          model:,
          toolbox: Tamoz::Agent::Toolbox.new(
            root: File.realpath(workspace),
            allow_changes: true,
            checks: {
              "answer" => [RbConfig.ruby, "-e",
                           %q{abort("wrong") unless File.read("app.rb") == "value = 2\n"}]
            }
          ),
          checkpointer: adapter,
          artifact_store: store,
          artifact_tenant: "tenant.replay"
        )
        complete_turn(session)
        compact_calls = lambda do
          model.calls.count { |call| call.start_with?("context_compact") }
        end
        baseline = compact_calls.call

        first = session.compact_transcript(thread: THREAD, request_id: "r.compact.replay")

        assert_equal baseline + 1, compact_calls.call

        second = session.compact_transcript(thread: THREAD, request_id: "r.compact.replay")

        assert_equal baseline + 1, compact_calls.call,
                     'the replay hit the recorded receipt instead of the model'
        assert_equal first.record.fetch("summary_digest"), second.record.fetch("summary_digest")
        assert_equal 2, control_count(session)
      ensure
        adapter&.close
      end
    end
  end

  def test_read_only_controls_change_no_durable_state
    with_session do |session, workspace|
      complete_turn(session)
      before_tip = session.app.checkpointer.latest(thread_id: THREAD, namespace: [])
      before_digest = RECORDS.digest(before_tip.state.to_h)

      usage = session.usage_report(thread: THREAD)
      composition = session.context_report(thread: THREAD)

      after_tip = session.app.checkpointer.latest(thread_id: THREAD, namespace: [])
      assert_equal before_tip.id, after_tip.id
      assert_equal before_tip.sequence, after_tip.sequence
      assert_equal before_digest, RECORDS.digest(after_tip.state.to_h)

      document = usage.document
      assert_equal "usage", document.fetch("control")
      assert_equal 1, document.fetch("requests").fetch("turn")
      assert_operator document.fetch("requests").fetch("resume", 0), :>=, 1
      assert_empty document.fetch("pinned_budgets")
      assert_equal Tamoz::Agent::SessionNodes::MAX_OBSERVATION_BYTES,
                   document.dig("observation_bytes", "ceiling")
      refute document.key?("tokens")
      refute document.key?("cost")

      composition_document = composition.document
      assert_equal "context", composition_document.fetch("control")
      assert_empty composition_document.fetch("preferences")
      assert_includes composition_document.dig("layers", "authoritative_keys"), "goal"
      projected = JSON.generate(composition_document)
      refute_includes projected, "set value to 2"
      refute_includes projected, "value is 2"
    end
  end

  private

  def planning_context
    configuration = Struct.new(:memory, :memory_owner).new(nil, nil)
    Tamoz::Agent::SessionPlanningContext.new(configuration:, memory: nil)
  end

  def latest_state(session)
    session.app.state(thread: THREAD).state
  end

  def control_count(session)
    tip = session.app.checkpointer.latest(thread_id: THREAD, namespace: [])
    tip ? Array(tip.state[:context_controls]).length : 0
  end

  def complete_turn(session)
    session.start("set value to 2", thread: THREAD, request_id: "r0")
    drive_to_completion(session)
  end

  def drive_to_completion(session, thread: THREAD)
    view = session.view(thread:)
    index = 0
    while index < 8 && !view.interrupts.empty?
      index += 1
      session.resume(
        {view.interrupts.first.task_id => {0 => true}},
        thread:, request_id: "resume.#{index}"
      )
      view = session.view(thread:)
    end
    assert_equal :completed, view.status
  end

  def with_session
    Dir.mktmpdir("tamoz-context-controls") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "tamoz.sqlite3"))
      begin
        model = ScriptedModel.new(Digest::SHA256.hexdigest("value = 1\n"), '{"summary":"keep the goal"}')
        session = Tamoz::Agent::Session.new(
          model:,
          toolbox: Tamoz::Agent::Toolbox.new(
            root: File.realpath(workspace),
            allow_changes: true,
            checks: {
              "answer" => [RbConfig.ruby, "-e",
                           %q{abort("wrong") unless File.read("app.rb") == "value = 2\n"}]
            }
          ),
          checkpointer: adapter
        )
        yield session, File.realpath(workspace)
      ensure
        adapter&.close
      end
    end
  end
end
