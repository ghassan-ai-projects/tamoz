# frozen_string_literal: true

require_relative 'openclaw_comms_fixture'

module Tamoz
  # Harness A from docs/openclaw-chat-study-refresh/implementation-plan/
  # 05-experience-harness.md: an in-process mock-Telegram chat an agent (or a
  # person) can drive turn-by-turn against the REAL runtime — real gateway,
  # worker, outbox, drainer, store, and normalizer — with a REAL model provider.
  #
  # Only the transport is simulated (no network). Judging the experience or the
  # answer requires a real provider (DeepSeek); a deterministic-provider run on
  # this harness is plumbing only and is never intelligence evidence.
  module ExperienceSim
    Fixture = Tamoz::Evals::Benchmark::OpenclawCommsFixture

    # A live, drivable transport: an inbound queue you push raw Bot-API updates
    # onto (normalized by the REAL Telegram::Normalizer) and an outbound log
    # that records the full text the bot sent, so the driver can show it back.
    class HarnessTransport
      attr_reader :outbound, :signals

      def initialize(surface_id:, surface_revision:)
        @normalizer = Tamoz::Telegram::Normalizer.new(
          surface_id: surface_id, surface_revision: surface_revision
        )
        @queue = []
        @outbound = []
        @signals = []
        @message_ids = 0
      end

      def enqueue(update) = (@queue << update)

      def poll(next_offset:, limit:, timeout_s: nil) # rubocop:disable Lint/UnusedMethodArgument
        pending = @queue.select { |u| next_offset.nil? || u.fetch('update_id') >= next_offset }
        served = pending.first(limit || 50)
        ids = served.map { |u| u.fetch('update_id') }
        {
          updates: served.map { |u| @normalizer.normalize(u).wire },
          next_offset: ids.max && (ids.max + 1)
        }
      end

      def deliver(delivery)
        @message_ids += 1
        @outbound << {
          message_id: @message_ids, kind: delivery.kind.to_s,
          operation: delivery.operation.to_s, text: delivery.text.to_s,
          markup: delivery.markup, conversation_id: delivery.conversation_id
        }
        { 'message_id' => @message_ids, 'date' => Time.now.to_i }
      end

      def signal(*args)
        @signals << args
        nil
      end
    end

    class Harness < Fixture
      # A real provider by default (real experience/answer evidence). Pass an
      # explicit model_factory (e.g. the fixture's scripted one) ONLY for a
      # deterministic plumbing test — such a run is never intelligence evidence.
      def initialize(provider: nil, model: nil, model_factory: nil,
                     admission_mode: :allowlist, approval_ask: nil)
        @provider = provider || ENV.fetch('TAMOZ_PROVIDER', 'deepseek')
        @model = model || ENV.fetch('TAMOZ_MODEL', 'deepseek-chat')
        @update_seq = 1_000
        @message_seq = 500
        @seen_out = 0
        @last_bot_message_id = nil
        super(model_factory: model_factory || real_model_factory,
              admission_mode: admission_mode, approval_ask: approval_ask)
        bind_thread(Fixture::CONVERSATION_A) if admission_mode == :allowlist
      end

      # Drive one user message fully (admit + run) and return the bot's new cards.
      def say(text)
        enqueue_message(text, reply_to: nil)
        serve
        work_off
      end

      # Render a command without advancing the worker, so status observations
      # can distinguish an idle queue from a claimed request.
      def status_only(reference)
        enqueue_message("/status #{reference}", reply_to: nil)
        serve
        new_outbound
      end

      # Admit a message WITHOUT running the worker (queues an open request); use
      # to set up multiple concurrent open requests before running.
      def admit(text)
        enqueue_message(text, reply_to: nil)
        serve
        new_outbound
      end

      # Run one worker pass and drain; returns new cards.
      def work_off
        @worker.poll_once
        now = Time.now.utc
        3.times { drain(now: now) }
        new_outbound
      end

      # Reply to the bot's last message (I1 natural answer path).
      def reply(text)
        enqueue_message(text, reply_to: @last_bot_message_id)
        serve
        work_off
      end

      # Press an inline button (callback query).
      def tap(data)
        enqueue_update('callback_query' => {
                         'id' => "cb#{next_update_id}", 'data' => data,
                         'from' => { 'id' => Fixture::USER_BOUND },
                         'message' => { 'message_id' => @last_bot_message_id || 1,
                                        'chat' => chat_hash }
                       })
        serve
        work_off
      end

      # Worker events captured this session (worker.error carries swallowed
      # exception reasons), useful when a turn fails opaquely.
      attr_reader :events

      def status_text
        projection = status(Fixture::CONVERSATION_A)
        projection ? JSON.pretty_generate(projection) : '(no status)'
      end

      def conversation_status = status(Fixture::CONVERSATION_A)
      def ref_status(ref) = request_status(Fixture::CONVERSATION_A, ref)

      def provider_label = "#{@provider}/#{@model}"

      private

      def real_model_factory
        provider = @provider
        model = @model
        lambda do |**|
          Tamoz::Agent::ModelClientFactory.build(
            provider: provider, model: model, profile_role: nil,
            environment: ENV, safety: :unsafe
          )
        end
      end

      # Swap the fixture's recorded-only FakeTransport for the live HarnessTransport.
      def wire_delivery_pipeline(admission_mode)
        @transport = HarnessTransport.new(
          surface_id: Fixture::SURFACE_ID, surface_revision: Fixture::SURFACE_REVISION
        )
        @gateway = Tamoz::Comms::Gateway.new(
          adapter: @runtime.adapter, checkpoints: @runtime.checkpoints, transport: @transport,
          descriptor: descriptor(admission_mode), poller_owner: 'sim:gateway',
          controls: ->(thread_id) { @runtime.session_for(thread_id) }
        )
        sink = Tamoz::Comms::OutboxDeliverySink.new(
          adapter: @runtime.adapter, checkpoints: @runtime.checkpoints
        )
        @runtime.instance_variable_set(:@delivery_sink, sink)
        @worker = capturing_worker
      end

      def capturing_worker
        @events ||= []
        Tamoz::Agent::Worker.new(
          runtime: @runtime,
          session_builder: ->(thread_id) { @runtime.session_for(thread_id) },
          emitter: ->(event) { @events << event }, once: true
        )
      end

      def enqueue_message(text, reply_to:)
        message = { 'message_id' => next_message_id, 'chat' => chat_hash,
                    'from' => { 'id' => Fixture::USER_BOUND }, 'text' => text,
                    'date' => Time.now.to_i }
        message['reply_to_message'] = { 'message_id' => reply_to } if reply_to
        enqueue_update('message' => message)
      end

      def serve = @gateway.serve_once(now: Time.now.utc, drain: true)

      def enqueue_update(fields)
        @transport.enqueue({ 'update_id' => next_update_id }.merge(fields))
      end

      def new_outbound
        fresh = @transport.outbound[@seen_out..] || []
        @seen_out = @transport.outbound.length
        @last_bot_message_id = fresh.last[:message_id] if fresh.any?
        fresh
      end

      def chat_hash = { 'id' => chat_numeric, 'type' => 'private' }
      def chat_numeric = Fixture::CONVERSATION_A.split(':').last.to_i
      def next_update_id = (@update_seq += 1)
      def next_message_id = (@message_seq += 1)
    end
  end
end
