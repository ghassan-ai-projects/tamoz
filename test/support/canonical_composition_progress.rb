# frozen_string_literal: true

require_relative 'canonical_composition_routes'

module CanonicalCompositionProgress
  include CanonicalCompositionRoutes

  Oracles = Tamoz::Evals::Benchmark::OpenclawCommsOracles
  Lifecycle = Tamoz::Comms::Lifecycle

  private

  def terminal_view?(fixture, conversation)
    view = fixture.view(fixture.thread_for(conversation))

    view && %i[completed failed blocked].include?(view.status)
  end

  def work_until_terminal(fixture, conversation, worker: nil)
    8.times do
      worker ? worker.poll_once : fixture.work
      break if terminal_view?(fixture, conversation)
    end

    assert terminal_view?(fixture, conversation), 'turn never reached a terminal view'
  end

  def drain_all(fixture)
    4.times do
      break if fixture.outbox(statuses: %w[pending]).empty?

      fixture.drain
    end

    assert_empty fixture.outbox(statuses: %w[pending]), 'outbox never quiesced'
  end

  def delivery_baseline(fixture)
    fixture.outbox.map { |row| row.fetch('delivery_id') }
  end

  def leg_snapshot(fixture, conversation:, request_id:, delivery_baseline:)
    thread = fixture.thread_for(conversation)
    row = fixture.request_row(thread, request_id)
    {
      'conversation_id' => conversation,
      'thread_id' => thread,
      'request_id' => request_id,
      'reference' => Lifecycle::RequestRef.for(request_id),
      'request_status' => row && row.status.to_s,
      'request_row_present' => !row.nil?,
      'terminal_reason' => fixture.view(thread)&.terminal&.dig('reason'),
      'delivery_state' => leg_delivery_state(fixture, delivery_baseline)
    }.compact
  end

  def leg_delivery_state(fixture, baseline_ids)
    fresh = fixture.outbox
                   .reject { |row| baseline_ids.include?(row.fetch('delivery_id')) }
                   .select { |row| Oracles::TERMINAL_KINDS.include?(row['kind']) }
    return 'none' if fresh.empty?

    statuses = fresh.map { |row| row['status'] }.uniq
    statuses.length == 1 ? statuses.first : 'mixed'
  end

  def cancellation_timeline(fixture, conversation, request_id)
    reference = Lifecycle::RequestRef.for(request_id)
    resolved = fixture.request_status(conversation, reference)
    document = resolved.is_a?(Hash) ? resolved.fetch('cancellation', {}) : {}
    stamp = fixture.cancellation_stamp_rows.find { |row| row.fetch('request_id') == request_id } || {}
    requested = stamp['requested_at_ms']
    observed = stamp['observed_at_ms']
    {
      reference:, requested_present: !requested.nil?, observed_present: !observed.nil?,
      requested_le_observed: requested && observed ? requested <= observed : false,
      state: document['state'], terminal_word: document['terminal']
    }
  end
end
