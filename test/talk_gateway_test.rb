# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/talk_fixtures'
require 'json'

# The talk transport under the real comms gateway and SQLite store (plumbing; no model).
# rubocop:disable Minitest/MultipleAssertions
class TalkGatewayTest < Minitest::Test
  include TalkFixtures

  Comms = Tamoz::Comms

  # The updates under test are already held, so a confirming poll never needs to wait for more.
  class NoWait < SimpleDelegator
    def poll(next_offset:, limit:, **) = __getobj__.poll(next_offset:, limit:, timeout_s: 0)
  end
  NOW = Time.utc(2026, 10, 9, 12)

  def with_runtime
    Dir.mktmpdir('tamoz-talk-gateway') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      checkpoints = graph.compile(checkpointer: adapter).checkpointer
      store = adapter.bind_comms_store(checkpoints)
      store.deploy_surface(talk_descriptor.wire, now: NOW)
      spool = Tamoz::Core::AttachmentSpool.new(File.join(directory, 'attachments'))
      yield(gateway_factory(checkpoints, spool), store)
    ensure
      adapter&.close
    end
  end

  def gateway_factory(checkpoints, spool)
    lambda do |hub|
      Comms::Gateway.new(checkpoints:, transport: NoWait.new(hub.transport), descriptor: talk_descriptor,
                         poller_owner: "gateway:#{hub.object_id}", attachments: spool)
    end
  end

  def graph
    Tamoz.graph(name: 'talk-gateway', version: '1') do
      state :ready, default: true
      node(:finish, implementation_name: 'talk-gateway.finish', version: '1') { |_s, _c| { ready: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end

  def hub(floor: 0, **) = Tamoz::Talk::Hub.new(descriptor: talk_descriptor, token: TOKEN, floor:, port: 0, **)

  def send_async(hub, wire, audio: nil)
    Thread.new { hub.inbox.submit(wire, audio:, timeout_s: 10) }.tap { eventually { hub.inbox.size.positive? } }
  end

  def rows(store, sql)
    store.__send__(:read, 'test.talk.read') { |txn| txn.rows('test.talk.read', sql, []) }
  end

  def requests(store) = rows(store, 'SELECT thread_id FROM tamoz_comms_requests ORDER BY created_at_ms')

  def dispositions(store)
    rows(store,
         'SELECT update_id, disposition, reason FROM tamoz_comms_inbound ORDER BY update_id')
  end

  def pass(gateway) = Array.new(2) { gateway.serve_once(drain: false) }

  def decisions(store) = rows(store, 'SELECT * FROM tamoz_comms_decisions')

  def start_gateway(gateway_for, talk, now: NOW)
    gateway_for.call(talk).tap { |gateway| gateway.start(now:) }
  end

  def with_gateway(gateway_for, talk, now: NOW)
    gateway = start_gateway(gateway_for, talk, now:)
    yield gateway
  ensure
    gateway&.stop
  end

  def await_inbox(talk, size) = eventually { talk.inbox.size == size }

  def outcomes(senders) = senders.map(&:value)

  def thread_ids(store) = requests(store).flatten

  def decided_updates(store) = dispositions(store).map { |row| row.first(2) }

  def request_ids(store) = rows(store, 'SELECT request_id FROM tamoz_comms_requests ORDER BY created_at_ms').flatten

  def utterance_wire(talk, update_id) = talk.normalizer.utterance(update_id:, audio: wav(1), duration_s: 1.0)

  def send_wire(talk, wire) = send_async(talk, wire, audio: wav(1))

  def send_questions(talk) = [1, 2].map { |id| send_text(talk, id, "question #{id}") }

  def admit_one_pass_then_stop(gateway_for, talk)
    with_gateway(gateway_for, talk) do |gateway|
      gateway.serve_once(drain: false)
      talk.stop
    end
  end

  def restart_hub(store, card_id)
    hub(floor: card_id).tap { |talk| talk.seed(store.delivered_messages(surface_id: 'talk', limit: 50)) }
  end

  def card_summaries(talk)
    log_events(talk).map { |event| event.values_at('message_id', 'reference', 'actions') }
  end

  def submit_text_voice_and_approve(talk)
    senders = [send_text(talk, 1, 'hello'), send_utterance(talk, 2), send_text(talk, 3, 'approve:abc')]
    await_inbox(talk, 3)
    senders
  end

  def send_text(talk, update_id, text) = send_async(talk, talk.normalizer.text(update_id:, text:))

  def send_utterance(talk, update_id)
    send_async(talk, talk.normalizer.utterance(update_id:, audio: wav(1), duration_s: 1.0), audio: wav(1))
  end

  def send_decision(talk, update_id, reference, message_id)
    send_async(talk, talk.normalizer.decision(update_id:, action: 'approve', reference:, message_id:))
  end

  def insert_prompt(store, receipt: nil)
    reference, prompt = Comms::ApprovalPrompt.build(
      surface_id: 'talk', surface_revision: 1, thread_id: 'talk.talk.abc', occurrence_id: 'req-1',
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      required_evidence: :chat_bound, correspondent_id: 'talk:user:1', conversation_id: 'talk:chat:1',
      prompt_ttl_s: 900, created_at: Time.now.utc
    )
    store.insert_prompt(prompt.wire)
    store.activate_prompt(reference_digest: prompt.reference_digest, now: Time.now.utc, receipt:) if receipt
    reference
  end

  def log_events(talk) = talk.log.since(after: 0, epoch: nil, timeout_s: 0)['events']

  def deliver_approval_card(store, talk, reference)
    card = Comms::Delivery.build(conversation_id: 'talk:chat:1', kind: 'approval_request', text: 'Create notes.txt?',
                                 render_version: 1, content_digest: 'e' * 64,
                                 markup: JSON.generate('reference' => reference, 'actions' => %w[approve deny]))
    store.append_delivery(card.wire, surface_id: 'talk', capacity: 50, reserved_request_id: nil, now: Time.now.utc)
    Comms::DeliveryDrainer.new(store:, transport: talk.transport, descriptor: talk_descriptor,
                               owner: 'drainer:test', sleeper: ->(_) {}).drain_once(now: Time.now.utc)
    log_events(talk).first.fetch('message_id')
  end

  def notice_pusher(gateway, thread)
    sink = Comms::OutboxDeliverySink.new(adapter: gateway.instance_variable_get(:@adapter),
                                         checkpoints: gateway.instance_variable_get(:@checkpoints))
    lambda { |request_id|
      sink.push(thread_id: thread, kind: 'request.notice', text: 'Heard: «yes»', request_id:)
    }
  end

  def fail_next_admission(gateway, error)
    failures = [error]
    gateway.instance_variable_get(:@store).singleton_class.define_method(:admit_and_enqueue) do |*args, **kwargs|
      raise failures.shift if failures.any?

      super(*args, **kwargs)
    end
  end

  def test_text_voice_and_a_typed_approve_share_one_thread_and_decide_nothing
    with_runtime do |gateway_for, store|
      talk = hub
      senders = submit_text_voice_and_approve(talk)

      with_gateway(gateway_for, talk) do |gateway|
        assert_equal %i[served served], pass(gateway)
      end

      assert_equal %i[admitted admitted admitted], outcomes(senders)
      assert_equal([[1, 'request'], [2, 'request'], [3, 'request']], decided_updates(store))
      threads = thread_ids(store)

      assert_equal 1, threads.uniq.length
      assert_match(/\Atalk\.talk\.\h{16}\z/, threads.first)
      assert_empty decisions(store)
    end
  end

  def test_a_restart_after_admission_before_confirmation_admits_the_resend_once
    with_runtime do |gateway_for, store|
      first = hub
      wire = utterance_wire(first, 5)
      waiting = send_wire(first, wire)
      admit_one_pass_then_stop(gateway_for, first)

      assert_equal :stopping, waiting.value, 'the page was never told it was admitted'
      second = hub(floor: store.poll_offset(stream_id: 'talk:page'))
      resend = send_wire(second, wire)
      with_gateway(gateway_for, second) { |restarted| pass(restarted) }

      assert_equal :admitted, resend.value
      assert_equal 1, requests(store).length
    end
  end

  def test_a_pass_that_fails_after_the_fetch_fetches_again_and_admits_once
    with_runtime do |gateway_for, store|
      talk = hub
      waiting = send_utterance(talk, 6)
      with_gateway(gateway_for, talk) do |gateway|
        fail_next_admission(gateway, Comms::TransientTransportError.new('disk busy'))

        assert_equal :transient, gateway.serve_once(drain: false)
        assert_equal %i[served served], pass(gateway)
      end

      assert_equal :admitted, waiting.value
      assert_equal 1, requests(store).length
    end
  end

  def test_a_decision_for_no_active_prompt_or_a_foreign_card_decides_nothing
    with_runtime do |gateway_for, store|
      talk = hub
      reference = insert_prompt(store, receipt: '4242')
      senders = [send_decision(talk, 7, 'nope', 4242), send_decision(talk, 8, reference, 4243)]
      await_inbox(talk, 2)
      with_gateway(gateway_for, talk) do |gateway|
        pass(gateway)

        assert_equal [[7, 'ignored', 'unknown_reference'], [8, 'rejected', 'binding_mismatch']], dispositions(store)
        assert_empty decisions(store)
        senders << send_decision(talk, 9, reference, 4242)
        pass(gateway)
      end

      assert_equal [%w[approve talk_user talk]],
                   rows(store, 'SELECT direction, actor_kind, source FROM tamoz_comms_decisions')
      assert_equal %i[admitted admitted admitted], outcomes(senders)
    end
  end

  def test_a_restart_with_an_approval_pending_restores_the_card_and_approve_still_binds
    with_runtime do |gateway_for, store|
      first = hub
      reference = insert_prompt(store)
      card_id = deliver_approval_card(store, first, reference)
      first.stop

      second = restart_hub(store, card_id)

      assert_equal [[card_id, reference, %w[approve deny]]], card_summaries(second)
      waiting = send_decision(second, 11, reference, card_id)
      with_gateway(gateway_for, second, now: Time.now.utc) { |gateway| pass(gateway) }

      assert_equal :admitted, waiting.value
      assert_equal [['approve']], rows(store, 'SELECT direction FROM tamoz_comms_decisions')
    end
  end

  def test_a_heard_notice_is_one_unjournaled_control_delivery_per_request
    with_runtime do |gateway_for, store|
      talk = hub
      senders = send_questions(talk)
      await_inbox(talk, 2)
      notice = with_gateway(gateway_for, talk) do |gateway|
        pass(gateway)
        outcomes(senders)
        notice_pusher(gateway, thread_ids(store).first)
      end
      first_id, second_id = request_ids(store)

      assert_equal %i[appended duplicate appended], [first_id, first_id, second_id].map(&notice)
      assert_equal [['control', 0, nil], ['control', 0, nil]],
                   rows(store, "SELECT kind, journaled, request_id FROM tamoz_comms_outbox WHERE text = 'Heard: «yes»'")
      assert_equal [['admitted'], ['admitted']], rows(store, 'SELECT projection_state FROM tamoz_comms_requests'),
                   'a notice settles nothing'
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
