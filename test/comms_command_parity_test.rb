# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/comms_gateway_harness'

# Phase 1 wave B (plan 02, work items 3 and 4) — command registry parity and
# the truthful status surface: every name in Commands::KNOWN answers through a
# real handler with its own outcome, every accepted acknowledgement names the
# request reference derived from the durable identity, /status renders both
# lifecycle axes in external vocabulary from durable rows only, and /new,
# /redirect and /whoami behave exactly as the grammar advertises.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
class CommsCommandParityTest < Minitest::Test
  include CommsGatewayHarness

  Comms = Tamoz::Comms

  NOT_AVAILABLE = 'That command is not available on this channel.'
  UNKNOWN_REF_REPLY = 'No request with that reference is admitted for this conversation.'
  AMBIGUOUS_REF_REPLY = 'That reference matches more than one request; use the full reference.'

  def test_known_is_exactly_the_handled_command_set
    assert_equal %w[help status new cancel redirect whoami start reset compact usage context think verbose answer],
                 Comms::Commands::KNOWN

    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      admit_turn(gateway, transport, store, 101)

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
    with_gateway do |gateway, transport, store, adapter, checkpoints|
      transport.batch([update(1, text: '/eval rm -rf /')])

      assert_equal :served, gateway.serve_once(now: NOW, drain: false)

      assert_equal [%w[ignored unknown_command]], inbound_dispositions(adapter, 1)
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

      assert_equal "Received #{first_ref}.",
                   accepted.fetch(0).fetch('text')
      assert_equal "Received #{second_ref}.",
                   accepted.fetch(1).fetch('text')

      resolved = store.request_status(
        surface_id: SURFACE_ID, conversation_id: CONVERSATION_ID, ref: first_ref, now: NOW
      )

      assert_equal first_ref, resolved.fetch('request_ref'),
                   'the acknowledged reference resolves the stored request'
    end
  end

  def test_status_aggregate_renders_bounded_human_copy_with_all_refs_and_queue_facts
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      admit_turn(gateway, transport, store, 101)
      admit_turn(gateway, transport, store, 102, now: NOW + 5)
      active_ref = derived_ref(update(102))

      reply = drive_command(gateway, transport, '/status', id: 103)

      assert_leads_with reply, 'Work status: '
      assert_includes reply, 'State: queued'
      assert_includes reply, 'Delivery: not sent yet'
      assert_includes reply, 'Now: '
      assert_includes reply, 'Next: '
      refute_match(/(?:phase|event|effect|capability|worker|task|delivery)=/, reply)
      assert_includes reply, derived_ref(update(101)), 'the aggregate names every open request'
      assert_includes reply, "Active request: #{active_ref}."
      assert_match(/Queue position 1\. Age \d+ ms\./, reply)
      assert_includes reply, 'Open requests: 2; refs: '
      assert_equal 2, all_request_rows(checkpoints).length, '/status admits no work of its own'
    end
  end

  def test_status_by_reference_resolves_one_request_and_refuses_bounded
    with_gateway do |gateway, transport, store|
      admit_turn(gateway, transport, store, 101)
      first_ref = derived_ref(update(101))

      reply = drive_command(gateway, transport, "/status #{first_ref}", id: 102)

      assert_leads_with reply, "Request #{first_ref}: "
      assert_includes reply, 'State: queued'
      assert_includes reply, 'Delivery: not sent yet', 'accepted controls are not request-local delivery'
      refute_match(/(?:phase|event|effect|capability|worker|task|delivery)=/, reply)

      assert_equal UNKNOWN_REF_REPLY,
                   drive_command(gateway, transport, '/status r0000000000', id: 103)
      assert_equal UNKNOWN_REF_REPLY,
                   drive_command(gateway, transport, '/status not-a-reference', id: 104),
                   'a malformed reference gets the same bounded refusal'

      stub_request_status(store, :ambiguous_ref)
      assert_equal AMBIGUOUS_REF_REPLY,
                   drive_command(gateway, transport, "/status #{first_ref}", id: 105)
    ensure
      restore_request_status(store)
    end
  end

  def test_status_by_reference_renders_a_failed_request_in_bounded_human_copy
    with_gateway do |gateway, transport, store|
      admit_turn(gateway, transport, store, 101)
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
      assert_includes reply, 'State: failed', 'a failed request renders the bounded state'
      assert_includes reply, 'Delivery: delivered', "'succeeded' outbox rows render as delivered"
      assert_includes reply, 'Now: The request ended with an error.'
      assert_includes reply, 'Next: No further action.'
      refute_match(/(?:phase|event|effect|capability|worker|task|delivery)=/, reply)
      refute_includes reply, 'provider_failed'
    ensure
      restore_request_status(store)
    end
  end

  def test_status_diagnostics_require_an_explicit_flag_and_reject_extra_arguments
    with_gateway do |gateway, transport, store, _adapter, _checkpoints|
      admit_turn(gateway, transport, store, 101)
      reference = derived_ref(update(101))

      aggregate = drive_command(gateway, transport, '/status --diagnostic', id: 102)
      assert_includes aggregate, 'phase=unknown'
      assert_includes aggregate, 'event=unknown#'
      assert_includes aggregate, 'effect=not_started'
      assert_includes aggregate, 'capability=not_inspected'
      assert_includes aggregate, 'delivery=pending'

      request = drive_command(gateway, transport, "/status #{reference} --diagnostic", id: 103)
      assert_includes request, 'phase=unknown'
      assert_includes request, 'event=unknown#'
      assert_equal Tamoz::Comms::Gateway::STATUS_USAGE_REPLY,
                   drive_command(gateway, transport, '/status --diagnostic extra', id: 104)
    end
  end

  def test_new_bumps_generation_durably_and_rotates_the_thread_while_history_stays_queryable
    with_gateway do |gateway, transport, store, adapter, checkpoints|
      assert_equal 'No conversation is bound for this channel yet; send a message first.',
                   drive_command(gateway, transport, '/new', id: 90)

      old_thread = admit_turn(gateway, transport, store, 101)
      old_ref = derived_ref(update(101))

      assert_equal 'New conversation started; earlier history stays in the audit record.',
                   drive_command(gateway, transport, '/new', id: 91)
      assert_equal 1, store.conversation_generation(surface_id: SURFACE_ID, conversation_id: CONVERSATION_ID)

      new_thread = admit_turn(gateway, transport, store, 102, now: NOW + 5)

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
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      thread = admit_turn(gateway, transport, store, 101)
      ref = derived_ref(update(101))

      reply = drive_command(gateway, transport, "/redirect #{ref} invert the priority instead", id: 102)

      history = checkpoints.request_history(thread_id: thread)
      replacement_ref = Tamoz::Comms::Lifecycle::RequestRef.for(history.last.request_id)

      assert_equal "Replacement queued as #{replacement_ref}; #{ref} remains recorded; " \
                   'committed work is not undone.', reply

      assert_equal %i[turn redirect], history.map(&:operation)
      assert_equal({ 'task' => 'invert the priority instead' }, history.last.payload)
    end
  end

  def test_redirect_refuses_each_typed_case_bounded
    with_gateway do |gateway, transport, store, _adapter, checkpoints|
      thread = admit_turn(gateway, transport, store, 101)
      ref = derived_ref(update(101))
      usage = 'Usage: /redirect r<reference> <new task>'

      assert_equal usage, drive_command(gateway, transport, '/redirect', id: 201)
      assert_equal usage, drive_command(gateway, transport, "/redirect #{ref}", id: 202)
      assert_equal usage, drive_command(gateway, transport, '/redirect totally-wrong some task', id: 203),
                   'a garbled reference refuses typed'
      assert_equal UNKNOWN_REF_REPLY,
                   drive_command(gateway, transport, '/redirect r0000000000 some task', id: 204)

      stub_request_status(store, :ambiguous_ref)
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
    with_gateway do |gateway, transport, store, adapter, checkpoints|
      before = request_row_count(adapter)

      assert_equal "You are #{CORRESPONDENT_ID} in conversation #{CONVERSATION_ID} " \
                   "on surface #{SURFACE_ID}.",
                   drive_command(gateway, transport, '/whoami', id: 301)
      assert_equal before, request_row_count(adapter), '/whoami admits no work'
      assert_equal 0, approval_prompt_rows(adapter), '/whoami touches no approval machinery'
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
        checkpoints = graph_definition('parity').compile(checkpointer: adapter).checkpointer
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

  # Every delivery row the gateway appends lands here, so assertions read the
  # exact wires without re-deriving outbox filters.
  def capture = (@parity_capture ||= [])

  def last_reply = capture.last.fetch('text')

  # ===== helpers =====

  def admit_turn(gateway, transport, store, id, now: NOW)
    transport.batch([update(id)])
    outcome = gateway.serve_once(now:, drain: false)

    raise "admission of update #{id} returned #{outcome.inspect}" unless outcome == :served

    Comms::Admission.thread_id(SURFACE_ID, CONVERSATION_ID,
                               generation: current_generation(store))
  end

  def current_generation(store)
    store.conversation_generation(surface_id: SURFACE_ID, conversation_id: CONVERSATION_ID)
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

  # One seam for both statuses under test: a forced decision symbol and a
  # hand-built projection are the same override with different payloads.
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

  # Durable-row reads over the committed database file: the inbound
  # disposition and prompt tables have no store-level reader, so the audit
  # assertions go straight to the rows the run committed.
  def request_row_count(adapter)
    scalar_over_database(adapter, 'SELECT COUNT(*) FROM tamoz_comms_requests')
  end

  def inbound_dispositions(adapter, update_id)
    database = SQLite3::Database.new(adapter.path)
    database.execute(
      'SELECT disposition, reason FROM tamoz_comms_inbound WHERE update_id = ?', [update_id]
    )
  ensure
    database&.close
  end

  def approval_prompt_rows(adapter)
    scalar_over_database(adapter, 'SELECT COUNT(*) FROM tamoz_comms_approval_prompts')
  end

  def scalar_over_database(adapter, sql)
    database = SQLite3::Database.new(adapter.path)
    database.execute(sql).first&.first.to_i
  ensure
    database&.close
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength, Metrics/ClassLength
