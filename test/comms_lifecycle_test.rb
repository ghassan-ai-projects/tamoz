# frozen_string_literal: true

require_relative 'test_helper'

# Phase 1 wave A (plan 02, work item 1) — the closed external lifecycle
# vocabulary: frozen state sets, the typed reason registry, exact translation
# tables that fail closed on unknown input, and the short non-authorizing
# request reference shared verbatim by the store's row shape.
# rubocop:disable Minitest/MultipleAssertions
class CommsLifecycleTest < Minitest::Test
  Lifecycle = Tamoz::Comms::Lifecycle

  def test_the_state_sets_and_reason_registry_are_frozen_data
    assert_predicate Lifecycle::TASK_STATES, :frozen?
    assert_predicate Lifecycle::DELIVERY_STATES, :frozen?
    assert_predicate Lifecycle::REASONS, :frozen?

    assert_equal %w[accepted queued running waiting completed failed blocked stopped],
                 Lifecycle::TASK_STATES.to_a
    assert_equal %w[pending delivered failed unknown], Lifecycle::DELIVERY_STATES.to_a
  end

  def test_the_reason_registry_seeds_the_typed_refusal_and_terminal_codes
    %i[authentication_refused capacity_refused integrity_conflict open_request_limit
       inbound_too_large cancelled_by_user provider_failed].each do |code|
      line = Lifecycle::REASONS[code]

      assert_kind_of String, line, code
      refute_empty line, code
    end
    assert_empty(Lifecycle::REASONS.keys.reject { |code| code.is_a?(Symbol) })
  end

  def test_task_translation_table_is_exact
    {
      'idle' => nil,
      'admitted' => 'accepted',
      'queued' => 'queued',
      'running' => 'running',
      'waiting' => 'waiting',
      'blocked' => 'blocked',
      'completed' => 'completed',
      'failed' => 'failed',
      'stopped' => 'stopped'
    }.each do |internal, external|
      assert_equal external, Lifecycle.task_state_for(internal) unless external.nil?
      assert_nil Lifecycle.task_state_for(internal) if external.nil?
    end
  end

  def test_every_translated_task_state_stays_in_the_closed_set
    states = Lifecycle::TASK_TRANSLATIONS.values.compact.uniq

    assert_empty(states - Lifecycle::TASK_STATES)
  end

  def test_unknown_internal_states_fail_closed
    ['claimed', 'redirecting', 'not_started', 'Accepted', '', 'delivered'].each do |state|
      assert_raises(Tamoz::Comms::ValidationError) { Lifecycle.task_state_for(state) }
    end
    assert_raises(Tamoz::Comms::ValidationError) { Lifecycle.task_state_for(nil) }
  end

  def test_delivery_translation_table_is_exact
    {
      'pending' => 'pending',
      'claimed' => 'pending',
      'succeeded' => 'delivered',
      'failed' => 'failed',
      'unknown' => 'unknown'
    }.each do |outbox, external|
      assert_equal external, Lifecycle.delivery_state_for(outbox)
    end
    assert_empty(Lifecycle::DELIVERY_TRANSLATIONS.values.uniq - Lifecycle::DELIVERY_STATES)
  end

  def test_unknown_delivery_statuses_fail_closed_including_external_only_names
    ['delivered', 'sent', 'QUEUED', ''].each do |status|
      assert_raises(Tamoz::Comms::ValidationError) { Lifecycle.delivery_state_for(status) }
    end
    assert_raises(Tamoz::Comms::ValidationError) { Lifecycle.delivery_state_for(nil) }
  end

  def test_the_request_reference_is_short_stable_and_non_authorizing
    request_id = 'f' * 64
    reference = Lifecycle::RequestRef.for(request_id)

    assert_equal 11, reference.length
    assert_match(/\Ar[0-9a-f]{10}\z/, reference)
    assert_equal reference, Lifecycle::RequestRef.for(request_id.dup)
    assert_equal request_id[0, 10], reference[1, 10]
    refute_equal reference, Lifecycle::RequestRef.for('0' + 'f' * 63),
                 'different identities derive different references'
  end

  def test_the_sqlite_row_shape_derives_the_identical_reference
    holder = Class.new { include Tamoz::SQLite::CommsStoreRows }.new

    assert_equal Lifecycle::RequestRef.for('abcdef1234' + 'e' * 54),
                 holder.request_ref('abcdef1234' + 'e' * 54)
  end
end
# rubocop:enable Minitest/MultipleAssertions
