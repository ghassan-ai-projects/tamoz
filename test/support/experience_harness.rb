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

      def sends = @outbound

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

      def files = (@files ||= {})

      def fetch_attachment(file_id, max_bytes:)
        bytes = files.fetch(file_id) { raise Tamoz::Comms::TransientTransportError, 'no such file' }
        raise Tamoz::Comms::ResponseTooLargeError, 'file is too big' if bytes.bytesize > max_bytes

        bytes
      end

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
                     admission_mode: :allowlist, approval_ask: nil, routing: :legacy, transcriber: nil)
        @provider = provider || ENV.fetch('TAMOZ_PROVIDER', 'deepseek')
        @model = model || ENV.fetch('TAMOZ_MODEL', 'deepseek-chat')
        @update_seq = 1_000
        @message_seq = 500
        @seen_out = 0
        @last_bot_message_id = nil
        super(model_factory: model_factory || real_model_factory,
              admission_mode: admission_mode, approval_ask: approval_ask,
              routing:, transcriber:)
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

      attr_reader :transport

      def handoff_folder = File.join(@runtime.path, 'attachments')

      def handoffs = Dir.exist?(handoff_folder) ? Dir.children(handoff_folder) : []

      def forget_handoffs = handoffs.each { |name| File.delete(File.join(handoff_folder, name)) }

      def admit_document(bytes, mime_type:)
        file_id = "doc-#{next_update_id}"
        @transport.files[file_id] = bytes
        enqueue_update('message' => { 'message_id' => next_message_id, 'chat' => chat_hash,
                                      'from' => { 'id' => Fixture::USER_BOUND }, 'date' => Time.now.to_i,
                                      'document' => { 'file_id' => file_id, 'file_unique_id' => "u-#{file_id}",
                                                      'mime_type' => mime_type } })
        serve
      end

      def send_document(bytes, name:, mime_type:, caption: nil)
        file_id = "doc-#{next_update_id}"
        @transport.files[file_id] = bytes
        document = { 'file_id' => file_id, 'file_unique_id' => "u-#{file_id}", 'file_name' => name,
                     'mime_type' => mime_type, 'file_size' => bytes.bytesize }
        message = { 'message_id' => next_message_id, 'chat' => chat_hash, 'from' => { 'id' => Fixture::USER_BOUND },
                    'date' => Time.now.to_i, 'document' => document, 'caption' => caption }.compact
        enqueue_update('message' => message)
        serve
        work_off
      end

      def send_photo(bytes, caption: nil, run: true)
        file_id = "photo-#{next_update_id}"
        @transport.files[file_id] = bytes
        sizes = [{ 'file_id' => "#{file_id}-thumb", 'file_unique_id' => "u-#{file_id}-t", 'width' => 90, 'height' => 60 },
                 { 'file_id' => file_id, 'file_unique_id' => "u-#{file_id}", 'width' => 1280, 'height' => 960,
                   'file_size' => bytes.bytesize }]
        message = { 'message_id' => next_message_id, 'chat' => chat_hash, 'from' => { 'id' => Fixture::USER_BOUND },
                    'date' => Time.now.to_i, 'photo' => sizes, 'caption' => caption }.compact
        enqueue_update('message' => message)
        serve
        run ? work_off : new_outbound
      end

      def send_voice(bytes, duration: 4, forwarded: false)
        file_id = "voice-#{next_update_id}"
        @transport.files[file_id] = bytes
        message = { 'message_id' => next_message_id, 'chat' => chat_hash, 'from' => { 'id' => Fixture::USER_BOUND },
                    'date' => Time.now.to_i,
                    'voice' => { 'file_id' => file_id, 'file_unique_id' => "u-#{file_id}", 'duration' => duration,
                                 'mime_type' => 'audio/ogg', 'file_size' => bytes.bytesize } }
        if forwarded
          message['forward_origin'] =
            { 'type' => 'hidden_user', 'sender_user_name' => 'someone', 'date' => 1 }
        end
        enqueue_update('message' => message)
        serve
        work_off
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

      def reference(index = -1)
        Tamoz::Comms::Lifecycle::RequestRef.for(request_ids_for(Fixture::CONVERSATION_A).fetch(index))
      end

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
        surface = descriptor(admission_mode)
        @gateway = Tamoz::Comms::Gateway.new(
          adapter: @runtime.adapter, checkpoints: @runtime.checkpoints, transport: @transport,
          descriptor: surface, poller_owner: 'sim:gateway',
          # Production paces a conversation at one message per second and the
          # drainer really sleeps for it; every `serve` pays that second. This
          # harness drives turns, not pacing, so the drainer it owns skips the
          # wait — the send, the scheduled stamp, and the receipt are unchanged.
          drainer: Tamoz::Comms::DeliveryDrainer.new(
            store: @store, transport: @transport, descriptor: surface,
            owner: 'sim:gateway:drainer', batch_size: 50, sleeper: ->(_) {}
          ),
          controls: ->(thread_id) { @runtime.session_for(thread_id) },
          attachments: Tamoz::Core::AttachmentSpool.new(handoff_folder)
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
