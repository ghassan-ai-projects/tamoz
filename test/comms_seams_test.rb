# frozen_string_literal: true

require_relative 'test_helper'

# Slice B (COMMS_TELEGRAM_PLAN §3) — the closed command table and the three
# seams: Transport, DeliverySink (nil-safe), and the CommsStore contract.
# rubocop:disable Minitest/MultipleAssertions
class CommsSeamsTest < Minitest::Test
  Comms = Tamoz::Comms

  def test_commands_parse_known_commands_and_arguments
    parsed = Comms::Commands.parse('/cancel please')

    assert_equal 'cancel', parsed.command
    assert_equal 'please', parsed.arguments
  end

  def test_commands_are_case_insensitive_without_arguments
    parsed = Comms::Commands.parse('/STATUS')

    assert_equal 'status', parsed.command
    assert_nil parsed.arguments
  end

  def test_commands_accept_only_the_matching_bot_suffix
    assert_equal 'cancel', Comms::Commands.parse('/cancel@ops_bot now', bot_username: 'ops_bot').command
    assert_nil Comms::Commands.parse('/cancel@other_bot now', bot_username: 'ops_bot'),
               'a wrong bot suffix is not our command'
    assert_nil Comms::Commands.parse('/cancel@ops_bot', bot_username: nil),
               'an @suffix without an authenticated bot matches nothing'
  end

  def test_commands_reject_unknown_and_non_commands
    assert_nil Comms::Commands.parse('/eval rm -rf /')
    assert_nil Comms::Commands.parse('not a command')
    assert_nil Comms::Commands.parse('/')
    refute Comms::Commands.known?('eval')
    assert Comms::Commands.looks_like_command?('/help')
  end

  def test_commands_never_expose_authority_words
    %w[profile tool root model budget schedule approve].each do |word|
      assert_nil Comms::Commands.parse("/#{word} x"), "no #{word} command may exist"
    end
  end

  def test_transport_contract_is_structural
    transport = Object.new.extend(Comms::Transport)

    assert_raises(NotImplementedError) { transport.authenticate(nil, nil) }
    assert_raises(NotImplementedError) { transport.poll(next_offset: nil, limit: 1, timeout_s: 1) }
    assert_raises(NotImplementedError) { transport.deliver(nil) }
    assert_raises(NotImplementedError) { transport.signal(:typing) }
  end

  def test_null_sink_discards_events_without_raising
    sink = Comms::DeliverySink.null

    assert_nil sink.push(thread_id: 't', occurrence_id: 'r', kind: 'answer', text: 'hi')
    assert_nil sink.push({})
    assert_same sink, Comms::DeliverySink.null
  end

  def test_comms_store_contract_is_structural_and_versioned
    store = Object.new.extend(Comms::CommsStore)

    assert_equal 2, Comms::CommsStore::CONTRACT_VERSION
    assert_raises(NotImplementedError) do
      store.persist_next_offset(surface_id: 's', bot_id: 1, next_offset: 2, now: Time.now)
    end
    assert_raises(NotImplementedError) { store.append_delivery(nil, surface_id: 's', capacity: 10, now: Time.now) }
    assert_raises(NotImplementedError) do
      store.revoke_binding(correspondent_id: 'telegram:user:1', surface_id: 's', reason: 'x', now: Time.now)
    end
  end

  def test_decision_store_contract_version_pairs
    assert_equal 1, Comms::DecisionStore::CONTRACT_VERSION
  end
end
# rubocop:enable Minitest/MultipleAssertions
