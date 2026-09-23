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

module Tamoz
  module Evals
    module Benchmark
      # The B0 comms conversation fixture: real SQLite stores, the real
      # Telegram::Normalizer, the real Comms::Gateway admission, the real
      # Agent::Worker drain and the real DeliveryDrainer — driven by a fake
      # ScriptedTransport (recorded requests, NO egress) and a deterministic
      # scripted provider. This is Track-A plumbing evidence only.
      class OpenclawCommsFixture
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
        MILESTONE_EVENT_KINDS = %w[request.claimed request.running request.waiting
                                   request.recovered].freeze

        attr_reader :transport, :store, :runtime, :now

        class ScriptedModel
          def initialize(**responses)
            @responses = responses.transform_values { |queue| Array(queue).dup }
          end

          def generate(stage:, system:, prompt:)
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

          def poll(next_offset:, limit:, timeout_s:)
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

        # Records exactly what the worker pushed while the real outbox sink
        # still runs: the committed-fact backing evidence for milestones.
        class RecordingSink
          attr_reader :pushed

          def initialize(inner)
            @inner = inner
            @pushed = []
          end

          def push(event)
            @pushed << event
            @inner.push(event)
          end
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
        CANCEL_REPLY = 'Cancellation requested for '
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

        private def bind_cli_thread(thread_id)
          bound = @runtime.thread_profile(thread_id)
          return if bound == PROFILE_ID

          @runtime.bind_thread_profile(thread_id, PROFILE_ID)
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

        def initialize(model_factory: self.class.model_factory(**DEFAULT_MODEL_RESPONSES),
                       admission_mode: :allowlist, approval_ask: nil, routing: :legacy)
          @now = Time.now.utc
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
            surface_id: SURFACE_ID, revision: SURFACE_REVISION,
            transport: { mode: 'long_poll',
                         credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                         poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
            identity: { expected_bot_id: BOT_ID, bot_username: BOT_USERNAME },
            admission: admission_spec(mode),
            threading: 'conversation', profile_id: PROFILE_ID,
            profile_digest: @runtime.profile(PROFILE_ID).canonical_digest,
            approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
            rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
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
            owner: 'fixture:drainer', batch_size: 50, clock: -> { now }, sleeper: ->(_) {}
          )
          drainer.drain_once(now:)
        end

        def view(thread_id)
          session = @runtime.session_for(thread_id)
          session && session.view(thread: thread_id)
        end

        def status(conversation_id)
          @store.conversation_status(surface_id: SURFACE_ID, conversation_id: conversation_id, now: @now)
        end

        def request_status(conversation_id, ref)
          @store.request_status(surface_id: SURFACE_ID, conversation_id: conversation_id, ref: ref, now: @now)
        end

        def request_ids_for(conversation_id)
          read_rows(
            %w[request_id],
            'SELECT request_id FROM tamoz_comms_requests WHERE conversation_id = ?
             ORDER BY created_at_ms ASC, request_id ASC',
            [conversation_id]
          ).map { |row| row.fetch('request_id') }
        end

        # The durable cancellation-timeline inputs of every comms request:
        # the requested/observed stamps and the projection state whose
        # `completed` value decides whether a raced completion won the race.
        def cancellation_stamp_rows
          read_rows(
            %w[request_id projection_state requested_at_ms observed_at_ms],
            'SELECT request_id, projection_state, cancellation_requested_at_ms,
                    cancellation_observed_at_ms
             FROM tamoz_comms_requests ORDER BY created_at_ms ASC, request_id ASC'
          )
        end

        def history(conversation_id)
          @store.conversation_history(surface_id: SURFACE_ID, conversation_id: conversation_id)
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

        def snapshot(conversations: [CONVERSATION_A])
          facts = {
            'inbound' => inbound_rows,
            'requests' => request_rows,
            'outbox' => outbox_snapshot,
            'history' => conversations.to_h do |conversation|
              [conversation, history(conversation)]
            end,
            'status' => conversations.to_h { |conversation| [conversation, projection(status(conversation))] },
            'session' => conversations.to_h do |conversation|
              [conversation, view_snapshot(view(thread_for(conversation)))]
            end,
            'effects' => effect_rows,
            'sends' => @transport.sends.map { |send| send.transform_keys(&:to_s) },
            'pushed_milestones' => pushed_milestones
          }
          references = facts['requests'].filter_map { |row| row['request_ref'] }.uniq
          facts['request_projections'] = resolved_request_projections(references, conversations)
          facts
        end

        private

        def provision_runtime_directory(approval_ask)
          @workspace = File.join(@directory, 'workspace')
          runtime_dir = File.join(@directory, 'runtime')
          FileUtils.mkdir_p(@workspace)
          FileUtils.mkdir_p(runtime_dir, mode: 0o700)
          write_config(runtime_dir, approval_ask)
          write_profile(runtime_dir)
          runtime_dir
        end

        def deploy_surface_and_bind_correspondent(runtime_dir, admission_mode)
          resolved = Tamoz::Agent::RuntimeDirectory.resolve(path: runtime_dir, env: {})
          @runtime = Tamoz::Agent::WorkerRuntime.open(
            resolved, model_factory: @model_factory, routing: @routing,
            harness: @routing == :work ? { surface: :chat } : {}
          )
          @store = @runtime.adapter.bind_comms_store(@runtime.checkpoints)
          @store.deploy_surface(descriptor(admission_mode).wire, now: @now)
          bind_correspondent(USER_BOUND, CONVERSATION_A)
        end

        def wire_delivery_pipeline(admission_mode)
          @transport = FakeTransport.new(surface_id: SURFACE_ID, surface_revision: SURFACE_REVISION)
          surface = descriptor(admission_mode)
          @gateway = Tamoz::Comms::Gateway.new(
            adapter: @runtime.adapter, checkpoints: @runtime.checkpoints, transport: @transport,
            descriptor: surface, poller_owner: 'fixture:gateway',
            # Production paces a conversation at one message per second and the
            # drainer really sleeps for it. These tests assert the sent chain,
            # not its pacing, so the drainer the gateway drives skips the wait —
            # the send, the scheduled stamp, and the receipt are unchanged.
            drainer: Tamoz::Comms::DeliveryDrainer.new(
              store: @store, transport: @transport, descriptor: surface,
              owner: 'fixture:gateway:drainer', batch_size: 50, sleeper: ->(_) {}
            ),
            controls: ->(thread_id) { @runtime.session_for(thread_id) }
          )
          sink = Tamoz::Comms::OutboxDeliverySink.new(
            adapter: @runtime.adapter, checkpoints: @runtime.checkpoints
          )
          @recording_sink = RecordingSink.new(sink)
          @runtime.install_delivery_sink(@recording_sink)
          @worker = new_worker
        end

        def seed_workspace_files
          File.write(File.join(@workspace, 'note.txt'), "hello\n")
          File.write(File.join(@workspace, 'other.txt'), "world\n")
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

        def pushed_milestones
          @recording_sink.pushed.filter_map do |event|
            next nil unless MILESTONE_EVENT_KINDS.include?(event[:kind].to_s)

            { 'kind' => event[:kind].to_s, 'phase' => event[:phase].to_s,
              'sequence' => event[:sequence], 'request_id' => event[:request_id].to_s }
          end
        end

        def effect_rows
          effect_census.map do |row|
            { 'thread_id' => row[:thread_id], 'effect_key' => row[:effect_key],
              'operation' => row[:operation], 'status' => row[:status] }
          end
        end

        def resolved_request_projections(references, conversations)
          references.to_h do |reference|
            resolved_projection = conversations.filter_map do |conversation|
              resolved = request_status(conversation, reference)
              next nil unless resolved.is_a?(Hash)

              projection(resolved)
            end.first
            [reference, resolved_projection]
          end.compact
        end

        def projection(projection_hash)
          return nil unless projection_hash.is_a?(Hash)

          projection_hash.except('queue_age_ms')
        end

        def view_snapshot(view)
          return { 'status' => 'absent' } unless view

          { 'status' => view.status.to_s,
            'terminal_reason' => view.terminal && view.terminal['reason'],
            'satisfied' => view.terminal && view.terminal['satisfied'] }
        end

        def inbound_rows
          read_rows(%w[update_id disposition reason],
                    'SELECT update_id, disposition, reason FROM tamoz_comms_inbound ORDER BY update_id ASC')
        end

        def request_rows
          rows = read_rows(%w[request_id conversation_id projection_state],
                           'SELECT request_id, conversation_id, projection_state FROM tamoz_comms_requests
                            ORDER BY created_at_ms ASC, request_id ASC')
          rows.map do |row|
            row.merge('request_ref' => Tamoz::Comms::Lifecycle::RequestRef.for(row.fetch('request_id')))
          end
        end

        def read_rows(columns, sql, params = [])
          @runtime.adapter.__send__(:read, operation: 'benchmark.comms_fixture') do |txn|
            txn.rows('benchmark.comms_fixture.select', sql, params).map do |row_array|
              columns.zip(row_array).to_h
            end
          end
        end

        def outbox_snapshot
          outbox.map do |row|
            facts = row['markup'] ? safe_parse(row['markup']) : nil
            # The stored text is what history is compared against, so the
            # snapshot must not truncate it.
            row.except('expires_at_ms', 'claim_expires_at_ms', 'created_at_ms', 'updated_at_ms',
                       'send_started_at_ms')
               .merge('milestone_facts' =>
                        facts.is_a?(Hash) && facts['request_ref'].is_a?(String) ? facts : nil)
          end
        end

        def safe_parse(markup)
          JSON.parse(markup)
        rescue JSON::ParserError
          nil
        end

        def write_config(runtime_dir, approval_ask)
          document = {
            'runtime' => { 'schema_version' => 1 },
            'workspace' => { 'root' => @workspace },
            'sources' => {}
          }
          if approval_ask
            policy_dir = File.join(runtime_dir, 'policy')
            write_ask_policy(policy_dir, **approval_ask)
            document['approval'] = { 'profile' => 'unattended',
                                     'policy_path' => File.join(policy_dir, 'base.yaml') }
          end
          File.write(File.join(runtime_dir, 'config.yaml'), Psych.dump(document))
          File.chmod(0o600, File.join(runtime_dir, 'config.yaml'))
        end

        def write_ask_policy(policy_dir, timeout_s: 86_400, on_timeout: :park)
          require 'fileutils'
          FileUtils.mkdir_p(File.join(policy_dir, 'profiles'))
          File.write(File.join(policy_dir, 'base.yaml'), <<~YAML)
            version: 1
            tool_tiers:
              apply_patch:
                tier: local_execute
                verb: execute
                grant_scopes: [once]
              run_check:
                tier: local_execute
                verb: execute
                grant_scopes: [once]
            fallback_tier:
              tier: read
              verb: unknown
              grant_scopes: [once]
            tiers:
              read:
                default: allow
              local_execute:
                default: ask
                grant_scopes: [once]
            grant_keys:
              local_execute: [verb, tool]
            rules: []
            evidence:
              approve: filesystem_operator
              deny: chat_bound
            simulations: []
            ask:
              timeout_s: #{timeout_s}
              on_timeout: #{on_timeout}
          YAML
          File.write(File.join(policy_dir, 'profiles', 'unattended.yaml'), <<~YAML)
            profile:
              name: unattended
          YAML
        end

        def write_profile(runtime_dir)
          tools = %w[list_directory read_file search_text apply_patch create_file]
          digest = Tamoz::Agent::Toolbox.new(
            root: @workspace, allow_changes: true, checks: {}, allowed_tools: tools
          ).catalog_digest
          document = {
            'profile' => { 'schema_version' => 1, 'profile_id' => PROFILE_ID,
                           'profile_version' => '1.0', 'canonical_root' => @workspace },
            'roots' => { 'workspace' => @workspace },
            'tools' => { 'allowed' => tools },
            'policy' => {
              'allow_changes' => true, 'default_check_safety' => 'read_only',
              'graph_version' => '1', 'behavior_version' => '1.0',
              'tool_catalog_digest' => digest, 'unattended_catalog_digest' => digest
            }
          }
          directory = File.join(runtime_dir, 'profiles')
          FileUtils.mkdir_p(directory, mode: 0o700)
          path = File.join(directory, "#{PROFILE_ID}.yaml")
          File.write(path, Psych.dump(document))
          File.chmod(0o600, path)
        end
      end

      # Caller-owned adapter for the runner's external-input boundary. The
      # benchmark package receives this protocol; only test support knows the
      # concrete fixture and scripted responses.
      class OpenclawCommsAdapter
        def build(**options)
          OpenclawCommsFixture.new(**options)
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
              plan: [{ 'goal' => 'answer the task', 'done_when' => ['the tool returned evidence'],
                       'steps' => [{ 'id' => 's1', 'purpose' => 'gather evidence', 'tool' => 'read_file',
                                     'arguments' => { 'path' => 'note.txt' },
                                     'verification' => 'the output is present' }] }],
              review: [OpenclawCommsFixture::ACCEPTED_REVIEW],
              verify: [
                OpenclawCommsFixture::VERIFY_OK.first,
                { 'answer' => 'operator answer: two plus two is four.', 'satisfied' => true,
                  'evidence' => ['note.txt'] }
              ]
            },
            c7_approval: {
              plan: [
                { 'goal' => 'inspect then fix note.txt', 'done_when' => ['note.txt reads fixed'],
                  'steps' => [{ 'id' => 'look', 'purpose' => 'read the note', 'tool' => 'read_file',
                                'arguments' => { 'path' => 'note.txt' },
                                'verification' => 'the output is present' }] },
                { 'goal' => 'fix note.txt', 'done_when' => ['note.txt reads fixed'],
                  'steps' => [{ 'id' => 'edit', 'purpose' => 'apply the exact replacement',
                                'tool' => 'apply_patch',
                                'arguments' => { 'path' => 'note.txt', 'before' => 'hello', 'after' => 'fixed' },
                                'verification' => 'the receipt reports the new digest' }] }
              ],
              review: [OpenclawCommsFixture::ACCEPTED_REVIEW,
                       OpenclawCommsFixture::ACCEPTED_REVIEW],
              verify: [{ 'answer' => 'fixed', 'satisfied' => true, 'evidence' => ['note.txt'] }]
            },
            c8_waiting: {
              plan: [
                { 'goal' => 'inspect then fix note.txt', 'done_when' => ['the output is present'],
                  'steps' => [{ 'id' => 'look', 'purpose' => 'read the note', 'tool' => 'read_file',
                                'arguments' => { 'path' => 'note.txt' },
                                'verification' => 'the output is present' }] },
                { 'goal' => 'fix note.txt', 'done_when' => ['note.txt reads fixed'],
                  'steps' => [{ 'id' => 'edit', 'purpose' => 'apply the exact replacement',
                                'tool' => 'apply_patch',
                                'arguments' => { 'path' => 'note.txt', 'before' => 'hello', 'after' => 'fixed' },
                                'verification' => 'the receipt reports the new digest' }] }
              ],
              review: [OpenclawCommsFixture::ACCEPTED_REVIEW,
                       OpenclawCommsFixture::ACCEPTED_REVIEW],
              verify: [{ 'answer' => 'fixed', 'satisfied' => true, 'evidence' => ['note.txt'] }]
            }
          }
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
