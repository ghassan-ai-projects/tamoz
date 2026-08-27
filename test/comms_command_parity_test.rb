# frozen_string_literal: true

require_relative 'test_helper'

# Phase 1 wave B (plan 02, work items 3 and 4) — command registry parity and
# the truthful status surface: every name in Commands::KNOWN answers through a
# real handler with its own outcome, every accepted acknowledgement names the
# request reference derived from the durable identity, /status renders both
# lifecycle axes in external vocabulary from durable rows only, and /new,
# /redirect and /whoami behave exactly as the grammar advertises.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
class CommsCommandParityTest < Minitest::Test
  Comms = Tamoz::Comms

  SURFACE_ID = 'telegram-ops'
  BOT_ID = 7_463_512_990
  CONVERSATION_ID = 'telegram:chat:22222222'
  CORRESPONDENT_ID = 'telegram:user:11111111'
  NOW = Time.utc(2026, 8, 10, 12, 0, 0)
  NOT_AVAILABLE = 'That command is not available on this channel.'
  UNKNOWN_REF_REPLY = 'No request with that reference is admitted for this conversation.'
  AMBIGUOUS_REF_REPLY = 'That reference matches more than one request; use the full reference.'

  def test_known_is_exactly_the_handled_command_set
    assert_equal %w[help status new cancel redirect whoami start reset compact usage context think verbose answer],
                 Comms::Commands::KNOWN

    with_gateway do |gateway, transport, _store, _adapter, checkpoints|
      admit_turn(gateway, transport, 101)

      replies = Comms::Commands::KNOWN.map do |word|
        parsed = Comms::Commands.parse("/#{word}")

        assert_equal word, parsed.command, 'every known name must parse as known'

        text = { 'think' => '/think high', 'verbose' => '/verbose quiet' }.fetch(word, "/#{word}")
        reply = drive_command(gateway, transport, text, id: 900 + Comms::Commands::KNOWN.index(word))

        assert_kind_of String, reply, word
        refute_empty reply, word
        refute_equal NOT_AVAILABLE, reply, "#{word} must have a real handler"
        reply
      end

      assert_equal Comms::Commands::KNOWN.length, replies.uniq.length,
                   'each known command answers with its own distinct outcome'
      assert_equal 1, all_request_rows(checkpoints).count { |request| request.operation == :turn },
                   'the command sweep admits no work of its own'
    end
  end

  def test_an_unknown_command_still_gets_typed_unknown_command_and_never_model_input
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      transport.batch([update(1, text: '/eval rm -rf /')])

      assert_equal :served, gateway.serve_once(now: NOW, drain: false)

      assert_equal [%w[ignored unknown_command]], inbound_dispositions(store, 1)
      assert_empty all_request_rows(checkpoints), 'an unknown slash command never becomes a turn'
      assert_equal 'Unknown command.', last_reply
    end
  end

  def test_every_accepted_acknowledgement_names_the_derived_reference
    with_gateway do |gateway, transport, store|
      first = update(101, text: 'make it blue')
      second = update(102, text: 'and the font?')
      transport.batch([first, second])

      assert_equal :served, gateway.serve_once(now: NOW, drain: false)

      first_ref = derived_ref(first)
      second_ref = derived_ref(second)
      accepted = capture.select { |wire| wire.fetch('kind') == 'accepted' }

      assert_equal "Accepted #{first_ref}. I will report committed progress.",
                   accepted.fetch(0).fetch('text')
      assert_equal "Accepted #{second_ref}; queued behind earlier work; " \
                   'I will report committed progress when it runs.',
                   accepted.fetch(1).fetch('text')

      resolved = store.request_status(
        surface_id: SURFACE_ID, conversation_id: CONVERSATION_ID, ref: first_ref, now: NOW
      )

      assert_equal first_ref, resolved.fetch('request_ref'),
                   'the acknowledged reference resolves the stored request'
    end
  end

  def test_status_aggregate_renders_external_vocabulary_with_reference_and_queue_facts
    with_gateway do |gateway, transport, _store, _adapter, checkpoints|
      admit_turn(gateway, transport, 101)
      admit_turn(gateway, transport, 102, now: NOW + 5)
      active_ref = derived_ref(update(102))

      reply = drive_command(gateway, transport, '/status', id: 103)

      assert_leads_with reply, 'Work status: '
      assert_includes reply, 'task=queued', 'the task axis renders the external word'
      assert_includes reply, 'delivery=pending', 'the delivery axis renders the external word'
      assert_includes reply, "Reference #{active_ref}."
      assert_match(/Queue position 1\. Age \d+ ms\./, reply)
      assert_includes reply, 'open requests=2'
      assert_equal 2, all_request_rows(checkpoints).length, '/status admits no work of its own'
    end
  end

  def test_status_by_reference_resolves_one_request_and_refuses_bounded
    with_gateway do |gateway, transport, store|
      admit_turn(gateway, transport, 101)
      first_ref = derived_ref(update(101))

      reply = drive_command(gateway, transport, "/status #{first_ref}", id: 102)

      assert_leads_with reply, "Request #{first_ref}: "
      assert_includes reply, 'task=queued'
      assert_includes reply, 'delivery=pending'

      assert_equal UNKNOWN_REF_REPLY,
                   drive_command(gateway, transport, '/status r0000000000', id: 103)
      assert_equal UNKNOWN_REF_REPLY,
                   drive_command(gateway, transport, '/status not-a-reference', id: 104),
                   'a malformed reference gets the same bounded refusal'

      force_request_status(store, :ambiguous_ref)
      assert_equal AMBIGUOUS_REF_REPLY,
                   drive_command(gateway, transport, "/status #{first_ref}", id: 105)
    ensure
      restore_request_status(store)
    end
  end

  def test_status_by_reference_renders_a_failed_request_in_external_vocabulary
    with_gateway do |gateway, transport, store|
      admit_turn(gateway, transport, 101)
      ref = "r#{'f' * 10}"
      stub_request_status(
        store,
        'thread_id' => 'tg.ops.abc', 'state' => 'idle', 'open_requests' => 0,
        'request_id' => 'f' * 64, 'request_ref' => ref,
        'task_state' => 'failed', 'effect_state' => 'failed',
        'capability_state' => 'not_inspected', 'delivery_state' => 'succeeded',
        'phase' => 'terminal', 'event_kind' => 'terminal', 'event_sequence' => 7,
        'next_action' => 'none', 'terminal_reason' => 'provider_failed'
      )

      reply = drive_command(gateway, transport, "/status #{ref}", id: 102)

      assert_leads_with reply, "Request #{ref}: "
      assert_includes reply, 'task=failed', 'a failed request renders the external word'
      assert_includes reply, 'delivery=delivered', "'succeeded' outbox rows render as delivered"
      assert_includes reply, 'Reason: provider_failed.'
      assert_includes reply, 'next=none'
      refute_includes reply, 'task_state'
    ensure
      restore_request_status(store)
    end
  end

  def test_new_bumps_generation_durably_and_rotates_the_thread_while_history_stays_queryable
    with_gateway do |gateway, transport, store, adapter, checkpoints|
      assert_equal 'No conversation is bound for this channel yet; send a message first.',
                   drive_command(gateway, transport, '/new', id: 90)

      old_thread = admit_turn(gateway, transport, 101)
      old_ref = derived_ref(update(101))

      assert_equal 'New conversation started; earlier history stays in the audit record.',
                   drive_command(gateway, transport, '/new', id: 91)
      assert_equal 1, store.conversation_generation(surface_id: SURFACE_ID, conversation_id: CONVERSATION_ID)

      new_thread = admit_turn(gateway, transport, 102, now: NOW + 5)

      refute_equal old_thread, new_thread, 'the next admission lands on the new generation\'s thread'
      assert_equal 1, checkpoints.request_history(thread_id: new_thread).length
      assert_equal 1, checkpoints.request_history(thread_id: old_thread).length,
                   'work and history on the previous thread stay untouched'
      refute_nil adapter.store.get(Comms::Gateway::THREAD_PROFILE_NAMESPACE, new_thread),
                 'the rotated thread gets its profile binding before work enqueues'

      reply = drive_command(gateway, transport, "/status #{old_ref}", id: 92)

      assert_leads_with reply, "Request #{old_ref}: ",
                        'audit history stays queryable by reference after /new'

      reopened = Tamoz::SQLite::Adapter.new(path: adapter.path)
      begin
        assert_equal 1, reopened.bind_comms_store.conversation_generation(
          surface_id: SURFACE_ID, conversation_id: CONVERSATION_ID
        ), 'the bump is durable across a reopen'
      ensure
        reopened&.close
      end
    end
  end

  def test_redirect_enqueues_the_durable_task_replacement_for_the_referenced_request
    with_gateway do |gateway, transport, _store, _adapter, checkpoints|
      thread = admit_turn(gateway, transport, 101)
      ref = derived_ref(update(101))

      reply = drive_command(gateway, transport, "/redirect #{ref} invert the priority instead", id: 102)

      assert_equal "Redirecting #{ref}; the replacement task is queued.", reply

      history = checkpoints.request_history(thread_id: thread)

      assert_equal %i[turn redirect], history.map(&:operation)
      assert_equal({ 'task' => 'invert the priority instead' }, history.last.payload)
    end
  end

  def test_redirect_refuses_each_typed_case_bounded
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      thread = admit_turn(gateway, transport, 101)
      ref = derived_ref(update(101))
      usage = 'Usage: /redirect r<reference> <new task>'

      assert_equal usage, drive_command(gateway, transport, '/redirect', id: 201)
      assert_equal usage, drive_command(gateway, transport, "/redirect #{ref}", id: 202)
      assert_equal usage, drive_command(gateway, transport, '/redirect totally-wrong some task', id: 203),
                   'a garbled reference refuses typed'
      assert_equal UNKNOWN_REF_REPLY,
                   drive_command(gateway, transport, '/redirect r0000000000 some task', id: 204)

      force_request_status(store, :ambiguous_ref)
      assert_equal AMBIGUOUS_REF_REPLY,
                   drive_command(gateway, transport, "/redirect #{ref} some task", id: 205)
      restore_request_status(store)

      fail_request!(checkpoints, thread)
      assert_equal 'That request has already finished.',
                   drive_command(gateway, transport, "/redirect #{ref} some task", id: 206)

      assert_empty(checkpoints.request_history(thread_id: thread)
                        .select { |request| request.operation == :redirect },
                   'every refused redirect enqueued nothing')
    end
  end

  def test_whoami_names_the_bound_context_and_confers_nothing
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      before = request_row_count(store)

      assert_equal "You are #{CORRESPONDENT_ID} in conversation #{CONVERSATION_ID} " \
                   "on surface #{SURFACE_ID}.",
                   drive_command(gateway, transport, '/whoami', id: 301)
      assert_equal before, request_row_count(store), '/whoami admits no work'
      assert_equal 0, approval_prompt_rows(store), '/whoami touches no approval machinery'
      assert_empty all_request_rows(checkpoints)
    end
  end

  private

  # ===== harness =====

  def with_gateway
    Dir.mktmpdir('tamoz-parity') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      begin
        capture.clear
        checkpoints = graph_definition.compile(checkpointer: adapter).checkpointer
        bind_capture_hook!(adapter)
        store = adapter.bind_comms_store(checkpoints)
        store.deploy_surface(descriptor.wire, now: NOW)
        transport = ScriptedTransport.new
        controls_root = File.join(directory, 'workspace')
        FileUtils.mkdir_p(controls_root)
        session = nil
        gateway = Comms::Gateway.new(
          adapter:, checkpoints:, transport:, descriptor:, poller_owner: 'parity:test',
          controls: ->(_thread) do
            session ||= controls_session(adapter, controls_root)
          end
        )
        yield gateway, transport, store, adapter, checkpoints
      ensure
        adapter&.close
      end
    end
  end

  # The session-access seam under test, built exactly as the CLI wiring builds
  # it: one profile-less Session over the shared runtime database.
  def controls_session(adapter, root)
    Tamoz::Agent::Session.new(
      model: ControlsStubModel.new,
      toolbox: Tamoz::Agent::Toolbox.new(root:),
      checkpointer: adapter
    )
  end

  # Context controls never plan or verify; only /compact's summarization call
  # can reach the model, and the sweep never compacts enough to need it.
  class ControlsStubModel
    def generate(stage:, **)
      return JSON.generate('summary' => 'kept') if stage == :context_compact

      '{}'
    end
  end

  def bind_capture_hook!(adapter)
    sink = capture
    original = adapter.method(:bind_comms_store)
    memo = nil
    # One shared store instance: the gateway binds its own, and the singleton
    # request_status overrides must reach THAT object.
    adapter.define_singleton_method(:bind_comms_store) do |*bound|
      memo ||= begin
        store = original.call(*bound)
        store.define_singleton_method(:append_delivery) do |delivery_wire, **arguments|
          sink << delivery_wire
          super(delivery_wire, **arguments)
        end
        store
      end
    end
  end

  def assert_leads_with(text, prefix, message = nil)
    assert_match(/\A#{Regexp.escape(prefix)}/, text, message)
  end

  def descriptor
    @descriptor ||= Comms::SurfaceDescriptor.build(
      surface_id: SURFACE_ID, revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: BOT_ID, bot_username: 'ops_bot' },
      admission: { direct: 'allowlist', correspondents: [CORRESPONDENT_ID] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 200, per_chat_messages_per_s: 30.0,
                global_messages_per_s: 100.0 }
    )
  end

  def graph_definition
    Tamoz.graph(name: 'parity', version: '1') do
      state :ready, default: true
      node(:finish, implementation_name: 'parity.finish', version: '1') { |_s, _c| { ready: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
  end

  def update(id, text: 'first turn')
    { 'update_id' => id,
      'message' => { 'message_id' => id + 10_000, 'date' => 1_752_700_800,
                     'chat' => { 'id' => 22_222_222, 'type' => 'private' },
                     'from' => { 'id' => 111_111_11 }, 'text' => text } }
  end

  # Every delivery row the gateway appends lands here, so assertions read the
  # exact wires without re-deriving outbox filters.
  def capture = (@parity_capture ||= [])

  def last_reply = capture.last.fetch('text')

  class ScriptedTransport
    def batch(updates) = (@updates = updates)

    def poll(next_offset:, limit:, timeout_s:)
      ids = @updates.map { |update| update.fetch('update_id') }
      { updates: @updates.map { |update| normalize(update) }, next_offset: ids.max && (ids.max + 1) }
    end

    def deliver(delivery)
      (@sent ||= []) << delivery
      { 'message_id' => 1, 'date' => 1 }
    end

    def deliveries = @sent || []

    def normalize(update)
      Comms::InboundEnvelope.new(
        surface_id: SURFACE_ID, surface_revision: 1,
        update_id: update.fetch('update_id'),
        raw_payload_hash: Digest::SHA256.hexdigest(JSON.generate(update)),
        parser_version: 1,
        kind: update.dig('message', 'text').start_with?('/') ? 'command' : 'text',
        correspondent_id: CORRESPONDENT_ID,
        conversation_id: CONVERSATION_ID,
        message_id: update.dig('message', 'message_id'),
        text: update.dig('message', 'text'),
        observed_time: Time.at(update.dig('message', 'date')).utc
      ).wire
    end
  end

  # ===== helpers =====

  def admit_turn(gateway, transport, id, now: NOW)
    transport.batch([update(id)])
    outcome = gateway.serve_once(now:, drain: false)

    raise "admission of update #{id} returned #{outcome.inspect}" unless outcome == :served

    Comms::Admission.thread_id(SURFACE_ID, CONVERSATION_ID,
                               generation: current_generation(gateway))
  end

  def current_generation(gateway)
    gateway.instance_variable_get(:@store)
           .conversation_generation(surface_id: SURFACE_ID, conversation_id: CONVERSATION_ID)
  rescue KeyError
    0
  end

  def drive_command(gateway, transport, text, id:)
    transport.batch([update(id, text:)])

    assert_equal :served, gateway.serve_once(now: NOW + (id % 7) + 1, drain: false)
    last_reply
  end

  # The reference the ack MUST carry, derived independently of the store: the
  # core identity over the raw update bytes, exactly as the normalizer hashes
  # them.
  def derived_ref(raw_update)
    Comms::Lifecycle::RequestRef.for(
      Tamoz::Core::RequestIdentity.request_id(
        surface_id: SURFACE_ID, surface_revision: 1, bot_id: BOT_ID,
        update_id: raw_update.fetch('update_id'),
        raw_payload_hash: Digest::SHA256.hexdigest(JSON.generate(raw_update))
      )
    )
  end

  def force_request_status(store, forced)
    store.define_singleton_method(:request_status) { |*_arguments, **_keywords| forced }
  end

  def stub_request_status(store, projection)
    store.define_singleton_method(:request_status) { |*_arguments, **_keywords| projection }
  end

  def restore_request_status(store)
    return unless store.singleton_class.instance_methods(false).include?(:request_status)

    store.singleton_class.remove_method(:request_status)
  end

  def all_request_rows(checkpoints)
    [0, 1].flat_map do |generation|
      checkpoints.request_history(
        thread_id: Comms::Admission.thread_id(SURFACE_ID, CONVERSATION_ID, generation:)
      )
    end
  end

  def fail_request!(checkpoints, thread)
    checkpoints.open_writer(thread_id: thread, namespace: [], owner_id: 'parity-test',
                            ttl: checkpoints.writer_ttl) do |writer|
      claim = writer.claim_next_request
      writer.terminal_fail(request_id: claim.request_id, operation: claim.operation,
                           reason: 'provider_failed')
    end
  end

  def request_row_count(store)
    store.__send__(:read, 'test.parity.request.count') do |txn|
      txn.scalar('test.parity.request.count', 'SELECT COUNT(*) FROM tamoz_comms_requests').to_i
    end
  end

  def inbound_dispositions(store, update_id)
    store.__send__(:read, 'test.parity.inbound.read') do |txn|
      txn.rows('test.parity.inbound.read',
               'SELECT disposition, reason FROM tamoz_comms_inbound WHERE update_id = ?', [update_id])
    end
  end

  def approval_prompt_rows(store)
    store.__send__(:read, 'test.parity.prompts') do |txn|
      txn.scalar('test.parity.prompts', 'SELECT COUNT(*) FROM tamoz_comms_approval_prompts').to_i
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
