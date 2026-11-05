# frozen_string_literal: true

require_relative 'session_context_controls_reports'

module SessionContextControlsFacts
  include SessionContextControlsReports

  ResetRun = Struct.new(:reset, :before, :after)

  private

  def conversation_frame(session, request_id)
    session.send(:conversation_transcript, thread_id: THREAD, request_id:)
  end

  def fragment_texts(frame)
    frame.map { |fragment| fragment.fetch('text') }
  end

  def transcript_layer(session)
    session.context_report(thread: THREAD).document.dig('layers', 'transcript')
  end

  def compact_call_count(model)
    model.calls.count { |call| call.start_with?('context_compact') }
  end

  def episode_flags(state)
    {
      observations: Array(state[:observations]).any?,
      plan_versions: Array(state[:plan_versions]).any?,
      accepted_plan: !state[:accepted_plan].nil?
    }
  end

  def accounting(session)
    {
      tip: latest_tip(session),
      history: session.app.history(thread: THREAD, limit: 100).length,
      usage: session.usage_report(thread: THREAD).document
    }
  end

  def reset_with_accounting(session)
    before = accounting(session)
    reset = session.reset_episode(thread: THREAD, request_id: 'r.reset')
    RECORDS.load!(reset.record)
    ResetRun.new(reset, before, accounting(session))
  end

  def reset_outcome(session, run)
    state = latest_state(session)
    {
      control: run.reset.document.fetch('control'),
      channels_cleared: run.reset.record.fetch('cleared_channels').length.positive?,
      flags: episode_flags(state),
      step_cursor: state.fetch(:step_cursor),
      history_growth: run.after[:history] - run.before[:history]
    }
  end

  def expected_reset_outcome
    {
      control: 'reset', channels_cleared: true,
      flags: { observations: false, plan_versions: false, accepted_plan: false },
      step_cursor: 0, history_growth: 1
    }
  end

  def continuity(observations, accounting)
    [observations, budget_accounting(accounting.fetch(:usage))]
  end

  def truncation_counts(reset, layer)
    [reset.record.fetch('truncated_fragments'), layer.fetch('truncated_by_control'),
     layer.fetch('fragments_visible')]
  end

  def preserved_observations(session, tip)
    session.app.state(thread: THREAD, checkpoint_id: tip.id).state.fetch(:observations)
  end

  def budget_accounting(usage)
    [usage.fetch('pinned_budgets'), usage.dig('observation_bytes', 'ceiling')]
  end

  def tip_fingerprint(tip)
    [tip.id, tip.sequence, RECORDS.digest(tip.state.to_h)]
  end
end
