# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'psych'
require 'tmpdir'

require 'tamoz/agent'
require 'tamoz/comms'
require 'tamoz/comms/gateway'
require 'tamoz/sqlite'
require 'tamoz/telegram'

require_relative 'openclaw_comms_provisioning'
require_relative 'openclaw_comms_snapshot'

module Tamoz
  module Evals
    module Benchmark
      # The B0 comms conversation fixture: real SQLite stores, the real
      # Telegram::Normalizer, the real Comms::Gateway admission, the real
      # Agent::Worker drain and the real DeliveryDrainer — driven by a fake
      # ScriptedTransport (recorded requests, NO egress) and a deterministic
      # scripted provider. This is Track-A plumbing evidence only.
      class OpenclawCommsFixture
        include OpenclawCommsProvisioning
        include OpenclawCommsSnapshot

        SURFACE_ID = 'telegram-ops'
        SURFACE_REVISION = 1
        BOT_ID = 7_463_512_990
        BOT_USERNAME = 'ops_bot'
        PROFILE_ID = 'trusted'
        CONVERSATION_A = 'telegram:chat:22222222'
        CONVERSATION_B = 'telegram:chat:33333333'
        USER_BOUND = 111_111_11
        USER_OTHER = 44_444_444
        USER_UNKNOWN = 999_999_99

        attr_reader :transport, :store, :runtime, :now

        class ScriptedModel
          def initialize(**responses)
            @responses = responses.transform_values { |queue| Array(queue).dup }
          end

          def generate(stage:, **)
            queue = @responses.fetch(stage) { raise "no scripted #{stage} response" }
            raise "no scripted #{stage} response" if queue.empty?

            value = queue.length == 1 ? queue.first : queue.shift
            value.is_a?(String) ? value : JSON.generate(value)
          end
        end

        # Dies like a kill -9 after a named stage: outside StandardError so no
        # rescue between here and the store can turn it into a tidy failure.
        class Killed < Exception; end # rubocop:disable Lint/InheritException

        class CrashingModel < ScriptedModel
          def initialize(after:, **responses)
            super(**responses)
            @after = after
            @fired = false
          end

          def generate(stage:, **rest)
            result = super
            if !@fired && stage == @after
              @fired = true
              raise Killed, "simulated kill -9 after #{@after}"
            end

            result
          end
        end

        # Fake transport following the ScriptedTransport pattern: batches of
        # raw Bot-API updates normalized by the REAL Telegram::Normalizer,
        # recorded sends, scripted per-send faults. No network.
        class FakeTransport
          attr_reader :sends
          attr_accessor :send_script

          def initialize(surface_id:, surface_revision:)
            @normalizer = Tamoz::Telegram::Normalizer.new(
              surface_id: surface_id, surface_revision: surface_revision
            )
            @updates = []
            @sends = []
            @message_ids = 0
            @send_script = []
          end

          def batch(updates)
            @updates = updates
          end

          def poll(**)
            ids = @updates.map { |update| update.fetch('update_id') }
            {
              updates: @updates.map { |update| @normalizer.normalize(update).wire },
              next_offset: ids.max && (ids.max + 1)
            }
          end

          def deliver(delivery)
            fault = @send_script.shift
            raise fault if fault

            @message_ids += 1
            receipt = { 'message_id' => @message_ids, 'date' => 1_752_700_800 }
            @sends << {
              conversation_id: delivery.conversation_id, kind: delivery.kind,
              journaled: delivery.journaled, receipt_message_id: @message_ids,
              content_digest: delivery.content_digest
            }
            receipt
          end

          def signal(*) = nil
        end

        def self.model_factory(**responses)
          ->(_options) { ScriptedModel.new(**responses) }
        end

        def self.crashing_factory(after:, **responses)
          ->(_options) { CrashingModel.new(after:, **responses) }
        end

        # The durable CLI queue path (the seam gems/tamoz-agent-cli's
        # `queue add` / `cancel` drive): authority is bound write-once, then
        # the turn is submitted to the SAME durable request inbox the gateway
        # admits into, so one thread is reachable from both surfaces. The
        # request id is digest-derived from (thread, purpose), never random,
        # so two runs enqueue byte-identical work.
        CLI_REQUEST_DOMAIN = 'tamoz.evals.benchmark.cli.v1'
        CANCEL_REASON = 'cancelled_by_user'
        CANCEL_REPLY = 'Stopping…'
        CLI_CANCEL_PAYLOAD = { 'task' => { 'cancel' => true, 'reason' => CANCEL_REASON } }.freeze

        def cli_request_id(thread_id, purpose)
          Tamoz::Comms::Canonical.hexdigest(CLI_REQUEST_DOMAIN, [thread_id, purpose])
        end

        def submit_cli_task(thread_id:, purpose:, task:)
          submit_cli_request({ 'task' => task }, thread_id: thread_id, purpose: purpose,
                                                 operation: :turn, delivery: :queue)
        end

        def submit_cli_cancel(thread_id:, purpose: 'cancel')
          submit_cli_request(CLI_CANCEL_PAYLOAD, thread_id: thread_id, purpose: purpose,
                                                 operation: :redirect, delivery: :redirect)
        end

        def request_row(thread_id, request_id)
          @runtime.checkpoints.fetch_request(
            thread_id: thread_id, request_id: request_id, namespace: []
          )
        end

        def durable_request_rows(thread_id)
          @runtime.checkpoints.request_history(thread_id: thread_id, namespace: []).map do |record|
            {
              'request_id' => record.request_id, 'operation' => record.operation.to_s,
              'status' => record.status.to_s, 'payload' => record.payload
            }
          end
        end

        PLAN_STEPS = [
          { 'goal' => 'answer the task', 'done_when' => ['the tool returned evidence'],
            'steps' => [
              { 'id' => 's1', 'purpose' => 'gather evidence', 'tool' => 'read_file',
                'arguments' => { 'path' => 'note.txt' }, 'verification' => 'the output is present' },
              { 'id' => 's2', 'purpose' => 'gather more evidence', 'tool' => 'read_file',
                'arguments' => { 'path' => 'other.txt' }, 'verification' => 'the output is present' }
            ] }.freeze
        ].freeze
        DEFAULT_PLAN = [{ 'goal' => 'answer the task', 'done_when' => ['the tool returned evidence'],
                          'steps' => [{ 'id' => 's1', 'purpose' => 'gather evidence', 'tool' => 'read_file',
                                        'arguments' => { 'path' => 'note.txt' },
                                        'verification' => 'the output is present' }] }].freeze
        ACCEPTED_REVIEW = { 'decision' => 'accept', 'issues' => [], 'rationale' => 'sound' }.freeze
        VERIFY_OK = [{ 'answer' => 'the verified answer', 'satisfied' => true,
                       'evidence' => ['note.txt'] }].freeze
        DEFAULT_MODEL_RESPONSES = { plan: DEFAULT_PLAN, review: [ACCEPTED_REVIEW],
                                    verify: VERIFY_OK }.freeze

        VOICE_OPTIONS = %i[transcriber speech].freeze

        def initialize(model_factory: self.class.model_factory(**DEFAULT_MODEL_RESPONSES),
                       admission_mode: :allowlist, approval_ask: nil, routing: :legacy, **voice)
          unknown = voice.keys - VOICE_OPTIONS
          raise ArgumentError, "unknown keywords: #{unknown.join(', ')}" unless unknown.empty?

          @now = Time.now.utc
          @transcriber = voice[:transcriber]
          @speech = voice.fetch(:speech, false)
          @directory = Dir.mktmpdir('tamoz-comms-b0')
          @model_factory = model_factory
          @routing = routing
          runtime_dir = provision_runtime_directory(approval_ask)
          deploy_surface_and_bind_correspondent(runtime_dir, admission_mode)
          wire_delivery_pipeline(admission_mode)
          seed_workspace_files
        end

        def close
          @runtime&.close
          FileUtils.remove_entry(@directory)
        end

        def descriptor(mode)
          Tamoz::Comms::SurfaceDescriptor.build(
            kind: 'telegram',
            surface_id: SURFACE_ID, revision: SURFACE_REVISION,
            transport: { credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                         poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
            identity: { stream_id: "telegram:bot:#{BOT_ID}" }, settings: { bot_username: BOT_USERNAME },
            admission: admission_spec(mode),
            threading: 'conversation', profile_id: PROFILE_ID,
            profile_digest: @runtime.profile(PROFILE_ID).canonical_digest,
            approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
            rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate', speech: @speech },
            limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                      max_denial_prompts_per_request: 4, outbox_capacity: 500,
                      control_capacity: 500, per_chat_messages_per_s: 1.0,
                      global_messages_per_s: 25.0 }
          )
        end

        def bind_correspondent(user_id, conversation_id)
          @store.bind_correspondent(
            Tamoz::Comms::Binding.new(
              surface_id: SURFACE_ID, surface_revision: SURFACE_REVISION,
              correspondent_id: "telegram:user:#{user_id}",
              conversation_id: conversation_id,
              bound_at: @now, bound_by: 'operator:fixture'
            ).wire, now: @now
          )
        end

        def thread_for(conversation_id)
          Tamoz::Comms::Admission.thread_id(SURFACE_ID, conversation_id)
        end

        # The thread CURRENT admissions derive: control commands such as /new
        # rotate the conversation generation, so drivers must resolve the
        # thread through the same generation derivation as the gateway.
        def current_thread(conversation_id)
          Tamoz::Comms::Admission.thread_id(
            SURFACE_ID, conversation_id,
            generation: @store.conversation_generation(surface_id: SURFACE_ID,
                                                       conversation_id: conversation_id)
          )
        end

        def bind_thread(conversation_id)
          @runtime.bind_thread_profile(thread_for(conversation_id), PROFILE_ID)
        end

        # Serves one gateway pass WITHOUT draining the outbox; returns :served.
        def submit(updates, now: @now)
          @transport.batch(updates)
          @gateway.serve_once(now: now, drain: false)
        end

        # One worker pass over the durable inbox.
        def work = @worker.poll_once

        def drain(now: @now)
          drainer = Tamoz::Comms::DeliveryDrainer.new(
            store: @store, transport: @transport, descriptor: descriptor(:allowlist),
            owner: 'fixture:drainer', clock: -> { now }, sleeper: ->(_) {}
          )
          drainer.drain_once(now:)
        end

        def view(thread_id)
          session = @runtime.session_for(thread_id)
          session&.view(thread: thread_id)
        end

        def status(conversation_id)
          @store.conversation_status(surface_id: SURFACE_ID, conversation_id: conversation_id, now: @now)
        end

        def request_status(conversation_id, ref)
          @store.request_status(surface_id: SURFACE_ID, conversation_id: conversation_id, ref: ref, now: @now)
        end

        def history(conversation_id)
          @store.conversation_history(surface_id: SURFACE_ID, conversation_id:, thread_id: thread_for(conversation_id))
        end

        def outbox(statuses: %w[pending claimed succeeded failed unknown])
          @store.outbox_rows(surface_id: SURFACE_ID, statuses: statuses)
        end

        def effect_census
          @runtime.checkpoints.effect_census(limit: 10_000)
        end

        def fresh_worker = new_worker

        def prompt(reference_digest)
          @store.prompt(reference_digest:)
        end

        def prompt_digest(reference)
          Tamoz::Comms::Canonical.hexdigest(
            Tamoz::Comms::ApprovalPrompt::REFERENCE_DOMAIN, reference
          )
        end

        private

        def bind_cli_thread(thread_id)
          bound = @runtime.thread_profile(thread_id)
          return if bound == PROFILE_ID

          @runtime.bind_thread_profile(thread_id, PROFILE_ID)
        end

        def deploy_surface_and_bind_correspondent(runtime_dir, admission_mode)
          resolved = Tamoz::Agent::RuntimeDirectory.resolve(path: runtime_dir, env: {})
          @runtime = Tamoz::Agent::WorkerRuntime.open(
            resolved, model_factory: @model_factory, routing: @routing,
                      harness: @routing == :work ? { surface: :chat } : {}, transcriber: @transcriber
          )
          @store = @runtime.adapter.bind_comms_store(@runtime.checkpoints)
          @store.deploy_surface(descriptor(admission_mode).wire, now: @now)
          bind_correspondent(USER_BOUND, CONVERSATION_A)
        end

        def wire_delivery_pipeline(admission_mode)
          @transport = FakeTransport.new(surface_id: SURFACE_ID, surface_revision: SURFACE_REVISION)
          surface = descriptor(admission_mode)
          @gateway = Tamoz::Comms::Gateway.new(checkpoints: @runtime.checkpoints, transport: @transport,
                                               descriptor: surface, poller_owner: 'fixture:gateway',
                                               # Production paces a conversation at one message per second and the
                                               # drainer really sleeps for it. These tests assert the sent chain,
                                               # not its pacing, so the drainer the gateway drives skips the wait —
                                               # the send, the scheduled stamp, and the receipt are unchanged.
                                               drainer: Tamoz::Comms::DeliveryDrainer.new(
                                                 store: @store, transport: @transport, descriptor: surface,
                                                 owner: 'fixture:gateway:drainer', sleeper: ->(_) {}
                                               ),
                                               controls: lambda { |thread_id|
                                                 @runtime.session_for(thread_id)
                                               })
          sink = Tamoz::Comms::OutboxDeliverySink.new(
            adapter: @runtime.adapter, checkpoints: @runtime.checkpoints
          )
          @runtime.install_delivery_sink(sink)
          @worker = new_worker
        end

        def new_worker
          Tamoz::Agent::Worker.new(
            runtime: @runtime,
            session_builder: ->(thread_id) { @runtime.session_for(thread_id) },
            emitter: ->(_event) {}, once: true
          )
        end

        def submit_cli_request(payload, thread_id:, purpose:, operation:, delivery:)
          bind_cli_thread(thread_id)
          request_id = cli_request_id(thread_id, purpose)
          @runtime.session_for(thread_id).app.durable_runner.submit(
            payload, thread: thread_id, request_id: request_id,
                     operation: operation, delivery: delivery
          )
          request_id
        end

        def admission_spec(mode)
          return { direct: 'pairing', correspondents: [] } if mode == :pairing

          { direct: 'allowlist', correspondents: ["telegram:user:#{USER_BOUND}"] }
        end
      end

      # Caller-owned adapter for the runner's external-input boundary. The
      # benchmark package receives this protocol; only test support knows the
      # concrete fixture and scripted responses.
      class OpenclawCommsAdapter
        def build(**)
          OpenclawCommsFixture.new(**)
        end

        def model_factory(scenario)
          OpenclawCommsFixture.model_factory(**model_responses.fetch(scenario))
        end

        def crashing_factory(scenario)
          OpenclawCommsFixture.crashing_factory(**crashing_responses.fetch(scenario))
        end

        def crash_error
          OpenclawCommsFixture::Killed
        end

        def surface_id = OpenclawCommsFixture::SURFACE_ID
        def surface_revision = OpenclawCommsFixture::SURFACE_REVISION
        def conversation_a = OpenclawCommsFixture::CONVERSATION_A
        def conversation_b = OpenclawCommsFixture::CONVERSATION_B
        def user_bound = OpenclawCommsFixture::USER_BOUND
        def user_other = OpenclawCommsFixture::USER_OTHER
        def user_unknown = OpenclawCommsFixture::USER_UNKNOWN
        def cancel_reason = OpenclawCommsFixture::CANCEL_REASON
        def cli_cancel_payload = OpenclawCommsFixture::CLI_CANCEL_PAYLOAD
        def cancel_reply = OpenclawCommsFixture::CANCEL_REPLY

        private

        def model_responses
          {
            parity_answer: {
              plan: OpenclawCommsFixture::DEFAULT_PLAN,
              review: [OpenclawCommsFixture::ACCEPTED_REVIEW],
              verify: [
                OpenclawCommsFixture::VERIFY_OK.first,
                { 'answer' => 'operator answer: two plus two is four.', 'satisfied' => true,
                  'evidence' => ['note.txt'] }
              ]
            },
            c7_approval: inspect_then_fix_responses('note.txt reads fixed'),
            c8_waiting: inspect_then_fix_responses('the output is present')
          }
        end

        def inspect_then_fix_responses(first_done_when)
          { plan: [inspect_plan(first_done_when), fix_plan],
            review: [OpenclawCommsFixture::ACCEPTED_REVIEW, OpenclawCommsFixture::ACCEPTED_REVIEW],
            verify: [{ 'answer' => 'fixed', 'satisfied' => true, 'evidence' => ['note.txt'] }] }
        end

        def inspect_plan(done_when)
          { 'goal' => 'inspect then fix note.txt', 'done_when' => [done_when],
            'steps' => [{ 'id' => 'look', 'purpose' => 'read the note', 'tool' => 'read_file',
                          'arguments' => { 'path' => 'note.txt' },
                          'verification' => 'the output is present' }] }
        end

        def fix_plan
          { 'goal' => 'fix note.txt', 'done_when' => ['note.txt reads fixed'],
            'steps' => [{ 'id' => 'edit', 'purpose' => 'apply the exact replacement',
                          'tool' => 'apply_patch',
                          'arguments' => { 'path' => 'note.txt', 'before' => 'hello', 'after' => 'fixed' },
                          'verification' => 'the receipt reports the new digest' }] }
        end

        def crashing_responses
          {
            c2_recovery: { after: :plan, plan: OpenclawCommsFixture::PLAN_STEPS * 2,
                           review: [OpenclawCommsFixture::ACCEPTED_REVIEW],
                           verify: OpenclawCommsFixture::VERIFY_OK },
            c4_recovery: { after: :plan, plan: [default_single_step, default_single_step],
                           review: [OpenclawCommsFixture::ACCEPTED_REVIEW],
                           verify: OpenclawCommsFixture::VERIFY_OK },
            c8_raced_restart: { after: :plan, plan: OpenclawCommsFixture::PLAN_STEPS * 2,
                                review: [OpenclawCommsFixture::ACCEPTED_REVIEW],
                                verify: OpenclawCommsFixture::VERIFY_OK }
          }
        end

        def default_single_step
          { 'goal' => 'answer the task', 'done_when' => ['the tool returned evidence'],
            'steps' => [{ 'id' => 's1', 'purpose' => 'gather evidence', 'tool' => 'read_file',
                          'arguments' => { 'path' => 'note.txt' },
                          'verification' => 'the output is present' }] }
        end
      end
    end
  end
end
