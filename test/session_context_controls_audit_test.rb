# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/session_context_controls_facts'

class SessionContextControlsAuditTest < Minitest::Test
  include SessionContextControlsFacts

  def test_mutations_write_exactly_one_typed_audit_record_and_return_a_typed_projection
    with_session do |session, _workspace|
      assert_equal 0, control_count(session)

      session.set_reasoning_depth(thread: THREAD, request_id: 'r.think', depth: 'high')
      session.set_answer_verbosity(thread: THREAD, request_id: 'r.verbose', verbosity: 'quiet')
      reset = session.reset_episode(thread: THREAD, request_id: 'r.reset')
      controls = Array(latest_state(session)[:context_controls])

      assert_equal(%w[think verbose reset], controls.map { |record| record.fetch('control') })
      assert_equal [3, 'reset'], [controls.length, reset.document.fetch('control')]
      controls.each { |record| RECORDS.load!(record) }
    end
  end

  def test_a_mutation_returns_a_typed_projection_of_its_audit_record
    with_session do |session, _workspace|
      projection = session.set_reasoning_depth(thread: THREAD, request_id: 'r.think', depth: 'high')
      document = projection.document

      assert_kind_of CONTROLS::ContextControlProjection, projection
      assert_equal(
        { 'control' => 'think', 'thread_id' => THREAD, 'preferences' => { 'reasoning_depth' => 'high' } },
        { 'control' => document.fetch('control'), 'thread_id' => document.fetch('thread_id'),
          'preferences' => projection.record.fetch('preferences') }
      )
      assert_match(DIGEST_FORMAT, document.fetch('audit_digest'))
      RECORDS.load!(projection.record)
    end
  end

  def test_unknown_preference_values_fail_closed_and_mutate_nothing
    with_session do |session, _workspace|
      before = control_count(session)

      errors = [
        -> { session.set_reasoning_depth(thread: THREAD, request_id: 'r.bad', depth: 'maximum') },
        -> { session.set_reasoning_depth(thread: THREAD, request_id: 'r.bad', depth: 3) },
        -> { session.set_answer_verbosity(thread: THREAD, request_id: 'r.bad', verbosity: 'loud') }
      ].map { |attempt| assert_raises(ArgumentError, &attempt) }

      assert_match(/quiet, normal, detailed/, errors.last.message)
      assert_equal before, control_count(session)
    end
  end

  # ONE durable stream serves both sides of the truncation contract. After
  # more than the admission window of prior turns, /reset declares exactly
  # the prefix it removed and the next composed frame keeps the newest
  # fragment visible — counts agree between /context and the composition.
  def test_reset_truncation_counts_and_composition_agree_over_one_stream
    with_session do |session, _workspace|
      checkpointer = session.app.checkpointer
      enqueue_turns(checkpointer, 'seed.', 'turn ', 13)

      reset = session.reset_episode(thread: THREAD, request_id: 'r.reset.window')
      layer = transcript_layer(session)

      assert_equal [13, 13, 0], truncation_counts(reset, layer)

      enqueue_turn(checkpointer, 'seed.after', 'turn after reset')
      frame = conversation_frame(session, 'seed.after')
      stream = Tamoz::Agent::SessionPlanningContext.conversation_history(checkpointer, thread_id: THREAD)

      assert_equal ['turn after reset'], fragment_texts(frame),
                   'the newest fragment stays visible after /reset'
      assert_equal layer.fetch('truncated_by_control'), stream.length - frame.length,
                   'exactly the declared number left the frame'
    end
  end

  # Two quick messages queue two turns; the first turn's transcript ends at itself.
  def test_a_turn_transcript_never_includes_a_message_queued_after_it
    with_session do |session, _workspace|
      checkpointer = session.app.checkpointer
      %w[first second].each { |text| enqueue_turn(checkpointer, "burst.#{text}", text) }

      assert_equal(['first'], fragment_texts(conversation_frame(session, 'burst.first')))
    end
  end

  def test_generation_addressing_helpers_are_pure_and_total
    assert_equal 1, CONTROLS.generation_of('plain')
    assert_equal 7, CONTROLS.generation_of('plain.g7')
  end

  # The compact's effect identity derives from the DETERMINISTIC control
  # request id: replaying the same control request resolves to the recorded
  # receipt instead of calling the model a second time.
  def test_a_replayed_compact_request_id_resolves_the_recorded_receipt
    with_compact_session(tenant: 'tenant.replay', check: CHECK_EXACT) do |session, model, _store|
      complete_turn(session)
      baseline = compact_call_count(model)

      first = session.compact_transcript(thread: THREAD, request_id: 'r.compact.replay')

      assert_equal baseline + 1, compact_call_count(model)

      second = session.compact_transcript(thread: THREAD, request_id: 'r.compact.replay')

      assert_equal baseline + 1, compact_call_count(model),
                   'the replay hit the recorded receipt instead of the model'
      assert_equal [first.record.fetch('summary_digest'), 2],
                   [second.record.fetch('summary_digest'), control_count(session)]
    end
  end
end
