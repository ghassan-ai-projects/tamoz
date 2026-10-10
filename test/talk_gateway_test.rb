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
      yield(lambda do |hub|
        Comms::Gateway.new(checkpoints:, transport: NoWait.new(hub.transport), descriptor: talk_descriptor,
                           poller_owner: "gateway:#{hub.object_id}", attachments: spool)
      end, store)
    ensure
      adapter&.close
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

  def pass(gateway) = 2.times.map { gateway.serve_once(drain: false) }

  def test_text_voice_and_a_typed_approve_share_one_thread_and_decide_nothing
    with_runtime do |gateway_for, store|
      talk = hub
      senders = [send_async(talk, talk.normalizer.text(update_id: 1, text: 'hello'))]
      senders << send_async(talk, talk.normalizer.utterance(update_id: 2, audio: wav(1), duration_s: 1.0),
                            audio: wav(1))
      senders << send_async(talk, talk.normalizer.text(update_id: 3, text: 'approve:abc'))
      eventually { talk.inbox.size == 3 }
      gateway = gateway_for.call(talk)
      gateway.start(now: NOW)

      assert_equal %i[served served], pass(gateway)
      assert_equal %i[admitted admitted admitted], senders.map(&:value)
      assert_equal([[1, 'request'], [2, 'request'], [3, 'request']], dispositions(store).map { |row| row.first(2) })
      threads = requests(store).flatten

      assert_equal 1, threads.uniq.length
      assert_match(/\Atalk\.talk\.\h{16}\z/, threads.first)
      assert_empty rows(store, 'SELECT * FROM tamoz_comms_decisions')
    ensure
      gateway&.stop
    end
  end

  def test_a_restart_after_admission_before_confirmation_admits_the_resend_once
    with_runtime do |gateway_for, store|
      first = hub
      wire = first.normalizer.utterance(update_id: 5, audio: wav(1), duration_s: 1.0)
      waiting = send_async(first, wire, audio: wav(1))
      gateway = gateway_for.call(first)
      gateway.start(now: NOW)
      gateway.serve_once(drain: false)
      first.stop
      gateway.stop

      assert_equal :stopping, waiting.value, 'the page was never told it was admitted'
      second = hub(floor: store.poll_offset(stream_id: 'talk:page'))
      resend = send_async(second, wire, audio: wav(1))
      restarted = gateway_for.call(second)
      restarted.start(now: NOW)
      pass(restarted)

      assert_equal :admitted, resend.value
      assert_equal 1, requests(store).length
    ensure
      restarted&.stop
    end
  end

  def test_a_pass_that_fails_after_the_fetch_fetches_again_and_admits_once
    with_runtime do |gateway_for, store|
      talk = hub
      waiting = send_async(talk, talk.normalizer.utterance(update_id: 6, audio: wav(1), duration_s: 1.0), audio: wav(1))
      gateway = gateway_for.call(talk)
      gateway.start(now: NOW)
      inner = gateway.instance_variable_get(:@store)
      failures = [Comms::TransientTransportError.new('disk busy')]
      inner.singleton_class.define_method(:admit_and_enqueue) do |*args, **kwargs|
        raise failures.shift if failures.any?

        super(*args, **kwargs)
      end

      assert_equal :transient, gateway.serve_once(drain: false)
      assert_equal %i[served served], pass(gateway)
      assert_equal :admitted, waiting.value
      assert_equal 1, requests(store).length
    ensure
      gateway&.stop
    end
  end

  def test_a_decision_for_no_active_prompt_or_a_foreign_card_decides_nothing
    with_runtime do |gateway_for, store|
      talk = hub
      reference, prompt = Comms::ApprovalPrompt.build(
        surface_id: 'talk', surface_revision: 1, thread_id: 'talk.talk.abc', occurrence_id: 'req-1',
        interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
        required_evidence: :chat_bound, correspondent_id: 'talk:user:1', conversation_id: 'talk:chat:1',
        prompt_ttl_s: 900, created_at: Time.now.utc
      )
      store.insert_prompt(prompt.wire)
      store.activate_prompt(reference_digest: prompt.reference_digest, now: Time.now.utc, receipt: '4242')
      senders = [send_async(talk, talk.normalizer.decision(update_id: 7, action: 'approve', reference: 'nope',
                                                           message_id: 4242))]
      senders << send_async(talk, talk.normalizer.decision(update_id: 8, action: 'approve', reference:,
                                                           message_id: 4243))
      eventually { talk.inbox.size == 2 }
      gateway = gateway_for.call(talk)
      gateway.start(now: NOW)
      pass(gateway)

      assert_equal [[7, 'ignored', 'unknown_reference'], [8, 'rejected', 'binding_mismatch']], dispositions(store)
      assert_empty rows(store, 'SELECT * FROM tamoz_comms_decisions')
      senders << send_async(talk, talk.normalizer.decision(update_id: 9, action: 'approve', reference:,
                                                           message_id: 4242))
      pass(gateway)

      assert_equal [%w[approve talk_user talk]],
                   rows(store, 'SELECT direction, actor_kind, source FROM tamoz_comms_decisions')
      assert_equal %i[admitted admitted admitted], senders.map(&:value)
    ensure
      gateway&.stop
    end
  end

  def test_a_restart_with_an_approval_pending_restores_the_card_and_approve_still_binds
    with_runtime do |gateway_for, store|
      first = hub
      reference, prompt = Comms::ApprovalPrompt.build(
        surface_id: 'talk', surface_revision: 1, thread_id: 'talk.talk.abc', occurrence_id: 'req-1',
        interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
        required_evidence: :chat_bound, correspondent_id: 'talk:user:1', conversation_id: 'talk:chat:1',
        prompt_ttl_s: 900, created_at: Time.now.utc
      )
      store.insert_prompt(prompt.wire)
      card = Comms::Delivery.build(conversation_id: 'talk:chat:1', kind: 'approval_request', text: 'Create notes.txt?',
                                   render_version: 1, content_digest: 'e' * 64,
                                   markup: JSON.generate('reference' => reference, 'actions' => %w[approve deny]))
      store.append_delivery(card.wire, surface_id: 'talk', capacity: 50, reserved_request_id: nil, now: Time.now.utc)
      Comms::DeliveryDrainer.new(store:, transport: first.transport, descriptor: talk_descriptor,
                                 owner: 'drainer:test', sleeper: lambda { |_|
                                 }).drain_once(now: Time.now.utc)
      card_id = first.log.since(after: 0, epoch: nil, timeout_s: 0)['events'].first.fetch('message_id')
      first.stop

      second = hub(floor: card_id)
      second.seed(store.delivered_messages(surface_id: 'talk', limit: 50))
      seeded = second.log.since(after: 0, epoch: nil, timeout_s: 0)['events']

      assert_equal([[card_id, reference, %w[approve deny]]], seeded.map do |event|
        event.values_at('message_id', 'reference', 'actions')
      end)
      waiting = send_async(second, second.normalizer.decision(update_id: 11, action: 'approve', reference:,
                                                              message_id: card_id))
      gateway = gateway_for.call(second)
      gateway.start(now: Time.now.utc)
      pass(gateway)

      assert_equal :admitted, waiting.value
      assert_equal [['approve']], rows(store, 'SELECT direction FROM tamoz_comms_decisions')
    ensure
      gateway&.stop
    end
  end

  def test_a_heard_notice_is_one_unjournaled_control_delivery_per_request
    with_runtime do |gateway_for, store|
      talk = hub
      senders = [1, 2].map { |id| send_async(talk, talk.normalizer.text(update_id: id, text: "question #{id}")) }
      eventually { talk.inbox.size == 2 }
      gateway = gateway_for.call(talk)
      gateway.start(now: NOW)
      pass(gateway)
      senders.each(&:value)
      thread, = requests(store).first
      request_ids = rows(store, 'SELECT request_id FROM tamoz_comms_requests ORDER BY created_at_ms').flatten
      adapter = gateway.instance_variable_get(:@adapter)
      sink = Comms::OutboxDeliverySink.new(adapter:, checkpoints: gateway.instance_variable_get(:@checkpoints))
      notice = lambda { |request_id|
        sink.push(thread_id: thread, kind: 'request.notice', text: 'Heard: «yes»', request_id:)
      }

      assert_equal %i[appended duplicate appended], [notice.call(request_ids[0]), notice.call(request_ids[0]),
                                                     notice.call(request_ids[1])]
      assert_equal [['control', 0, nil], ['control', 0, nil]],
                   rows(store, "SELECT kind, journaled, request_id FROM tamoz_comms_outbox WHERE text = 'Heard: «yes»'")
      assert_equal [['admitted'], ['admitted']], rows(store, 'SELECT projection_state FROM tamoz_comms_requests'),
                   'a notice settles nothing'
    ensure
      gateway&.stop
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
