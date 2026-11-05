# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/session_context_controls_facts'

class SessionContextControlsTest < Minitest::Test
  include SessionContextControlsFacts

  def test_preference_controls_are_consumed_by_episode_composition
    with_session do |session, _workspace|
      session.set_reasoning_depth(thread: THREAD, request_id: 'r.think', depth: 'low')
      session.set_answer_verbosity(thread: THREAD, request_id: 'r.verbose', verbosity: 'detailed')

      frame = planning_context.compact_for(latest_state(session), :read_only).context

      assert_equal 'low', frame.dig('directives', 'reasoning_depth')
      assert_equal 'detailed', frame.dig('directives', 'answer_verbosity')
      assert_equal(
        { 'reasoning_depth' => 'low', 'answer_verbosity' => 'detailed' },
        session.context_report(thread: THREAD).document.fetch('preferences')
      )
    end
  end

  def test_reset_clears_episode_state_keeps_audit_history_and_continues_accounting
    with_session do |session, _workspace|
      complete_turn(session)
      populated = latest_state(session)

      assert_equal({ observations: true, plan_versions: true, accepted_plan: true }, episode_flags(populated))
      run = reset_with_accounting(session)

      assert_equal expected_reset_outcome, reset_outcome(session, run)
      assert_equal continuity(populated.fetch(:observations), run.before),
                   continuity(preserved_observations(session, run.before[:tip]), run.after)
    end
  end

  # A second truncating control records its CUMULATIVE prefix, so fragments
  # hidden by the first control never re-enter a later frame.
  def test_a_second_reset_keeps_every_truncation_cumulative
    with_session do |session, _workspace|
      checkpointer = session.app.checkpointer
      enqueue_turns(checkpointer, 'seed.a', 'early ', 5)
      session.reset_episode(thread: THREAD, request_id: 'r.reset.one')

      enqueue_turns(checkpointer, 'seed.b', 'late ', 3)
      second = session.reset_episode(thread: THREAD, request_id: 'r.reset.two')

      assert_equal 8, second.record.fetch('truncated_fragments')

      enqueue_turn(checkpointer, 'seed.c', 'newest turn')

      assert_equal ['newest turn'], fragment_texts(conversation_frame(session, 'seed.c')),
                   'no fragment hidden by an earlier control returns'
    end
  end

  def test_compact_pins_the_transcript_behind_digests_and_audits_before_after
    with_compact_session(tenant: 'tenant.controls', check: CHECK_INCLUDES) do |session, _model, store|
      complete_turn(session)
      before_count = control_count(session)
      record = session.compact_transcript(thread: THREAD, request_id: 'r.compact').record

      # The one CLI turn contributed its own user fragment; the episode's
      # verbose observation outputs are the bulk that got externalized.
      assert_equal(
        { control: 'compact', digest_formats: [true, true], digests_distinct: true, mode: 'model',
          truncated_fragments: 1, summary_digest: RECORDS.digest('summary' => SUMMARY_TEXT),
          control_delta: 1 },
        compact_audit(record).merge(control_delta: control_count(session) - before_count)
      )
      assert_equal({ tenant: 'tenant.controls', provenance: 'conversation_untrusted', bytes_externalized: true },
                   reference_facts(store, record))
      assert_equal [record.fetch('summary_digest'), true], pinned_summary_view(session)
    end
  end

  def test_read_only_controls_change_no_durable_state
    with_session do |session, _workspace|
      complete_turn(session)
      before = tip_fingerprint(latest_tip(session))

      usage = session.usage_report(thread: THREAD)
      composition = session.context_report(thread: THREAD)

      assert_equal before, tip_fingerprint(latest_tip(session))
      assert_equal(
        { control: 'usage', turn_requests: 1, resumed: true, no_pinned_budgets: true,
          observation_ceiling: Tamoz::Agent::SessionNodes::MAX_OBSERVATION_BYTES, reported_keys: [] },
        usage_facts(usage.document)
      )
      assert_equal({ control: 'context', no_preferences: true, goal_authoritative: true, leaked: [] },
                   context_facts(composition.document))
    end
  end

  private

  def pinned_summary_view(session)
    frame = planning_context.compact_for(latest_state(session), :read_only).context
    [frame.dig('conversation', 'earlier_summary', 'digest'),
     session.context_report(thread: THREAD).document.dig('layers', 'transcript', 'earlier_summary_pinned')]
  end
end
