# frozen_string_literal: true

require_relative 'test_helper'

# ADR-049 / TELEGRAM_COMMUNICATION_FLOW_CONTRACT §7.1 — approval is gated on
# authority evidence, not on transport. These are the bar's group-C oracles
# (TELEGRAM_COMMUNICATION_BAR C1-C3) as executable tests.
#
# C1 is GREEN since plan Phase 3: `resolve_callback` refuses a chat_bound
# approve under the v1 policy with a durable refusal and no decision, and
# deny remains unconditional (INV-A).
# rubocop:disable Lint/UnusedMethodArgument
class CommsEvidenceGatedApprovalTest < Minitest::Test
  Comms = Tamoz::Comms

  def with_engine
    Dir.mktmpdir('tamoz-evidence') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        definition = Tamoz.graph(name: 'evidence', version: '1') do
          state :ready, default: true
          node(:finish, implementation_name: 'evidence.finish', version: '1') { |_s, _c| { ready: true } }
          edge Tamoz::START, :finish
          edge :finish, Tamoz::END
        end
        checkpoints = definition.compile(checkpointer: adapter).checkpointer
        yield adapter, checkpoints
      ensure
        adapter&.close
      end
    end
  end

  def descriptor
    Comms::SurfaceDescriptor.build(
      surface_id: 'telegram-ops', revision: 1,
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: 7_463_512_990, bot_username: 'ops_bot' },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 }
    )
  end

  # C1 / INV-B + INV-D (GREEN since Phase 3): under the v1 policy every effect
  # requires `filesystem_operator`, so a chat_bound Telegram approve must be
  # refused and must NOT put an approve decision in front of the worker.
  def test_a_chat_bound_approve_is_refused_under_v1_policy
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store)

      press(gateway, "approve:#{reference}", update_id: 60)

      decision = pending(adapter, prompt)
      approve_reached_worker = !decision.nil? && decision.fetch('direction') == 'approve'

      refute approve_reached_worker,
             'a chat_bound Telegram approve must not release a filesystem_operator action ' \
             '(ADR-049 INV-B/INV-D); no approve decision may reach the worker under v1 policy'
    end
  end

  # C1 / refusal is durable and non-destructive (contract §7.1): the weak
  # approve records a `rejected`/`insufficient_evidence` inbound row and the
  # prompt stays ACTIVE — a refusal never consumes it.
  def test_a_refused_approve_records_a_durable_refusal_and_leaves_the_prompt_active
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store)

      press(gateway, "approve:#{reference}", update_id: 70)

      rows = inbound_dispositions(adapter)
      refusal = rows.find { |row| row[1] == 'insufficient_evidence' }

      refute_nil refusal, 'the weak approve must record a durable refusal'
      assert_equal 'rejected', refusal[0]

      stored = store.prompt(reference_digest: prompt.reference_digest)

      assert_equal 'active', stored.fetch('status'),
                   'a refusal must not consume the prompt; a later deny stays possible'
    end
  end

  # INV-A after a refused approve: the same bound correspondent can still
  # deny the same prompt — the refusal did not burn the single-use reference.
  def test_a_deny_after_a_refused_approve_still_succeeds
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store)

      press(gateway, "approve:#{reference}", update_id: 70)
      press(gateway, "deny:#{reference}", update_id: 71)

      decision = pending(adapter, prompt, now: Time.utc(2026, 8, 10, 12, 0, 4))

      assert_equal 'deny', decision.fetch('direction')
    end
  end

  # C1 / exact binding (contract §7.1): a press whose correspondent does not
  # match the prompt's bound correspondent records a durable refusal and
  # creates no decision.
  def test_a_cross_correspondent_press_is_refused
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store)

      press(gateway, "approve:#{reference}", update_id: 80, correspondent_id: 222_222_22)

      decision = pending(adapter, prompt)

      assert_nil decision, 'a press outside the prompt binding never resolves'
      rows = inbound_dispositions(adapter)

      assert rows.any? { |row| row[0] == 'rejected' && row[1] == 'binding_mismatch' },
             'the cross-correspondent press must record a durable binding refusal'
    end
  end

  # C1 / INV-A (asymmetry control, GREEN): the equivalent denial still
  # succeeds. Deny is fail-safe and unconditional for the bound correspondent.
  def test_the_equivalent_deny_still_succeeds
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store)

      press(gateway, "deny:#{reference}", update_id: 61)

      decision = pending(adapter, prompt)

      refute_nil decision, 'a denial is always available to the bound correspondent (ADR-049 INV-A)'
      assert_equal 'deny', decision.fetch('direction')
    end
  end

  # C3 / INV-E (guard, GREEN): an approve on an expired prompt yields no
  # approve decision. Absent or ambiguous evidence never approves.
  def test_expired_evidence_never_approves
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store, ttl_s: 1)

      # Press well after the TTL window.
      press(gateway, "approve:#{reference}", update_id: 62, now: Time.utc(2026, 8, 10, 12, 30, 0))

      decision = pending(adapter, prompt, now: Time.utc(2026, 8, 10, 12, 30, 1))
      approve_reached_worker = !decision.nil? && decision.fetch('direction') == 'approve'

      refute approve_reached_worker, 'expired evidence never approves (ADR-049 INV-E)'
    end
  end

  # C2 / INV-C (GREEN since Phase 6): `required_evidence` is a trusted,
  # deterministic function of the pinned interrupts — never model-settable. A
  # hostile interrupt descriptor that tries to declare itself cheap is
  # ignored by the constant policy.
  def test_required_evidence_is_trusted_and_not_model_settable
    hostile = [{ task_id: 't', call_index: 0,
                 descriptor: { 'kind' => 'approve_tool', 'required_evidence' => 'chat_bound' } }]
    reference, prompt = Comms::ApprovalPrompt.build(
      surface_id: 'telegram-ops', surface_revision: 1,
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1', interrupts: hostile,
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      prompt_ttl_s: 900, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
    )

    assert_equal 'filesystem_operator', prompt.required_evidence,
                 'the model-supplied requirement in the descriptor is ignored (INV-C)'
    refute_nil reference
  end

  # C3 / INV-E extension: an approve on an unknown reference (missing
  # evidence) never creates a decision — the single-use reference is the only
  # key to a prompt, and there is no prompt here.
  def test_an_approve_on_an_unknown_reference_never_approves
    with_engine do |adapter, checkpoints|
      _store, gateway = boot(adapter, checkpoints)
      press(gateway, "approve:#{'0' * 32}", update_id: 90)

      decision_store = adapter.bind_comms_decision_store
      rows = decision_store.each_decision(thread_id: 'tg.ops.abc')

      assert_empty rows, 'no prompt, no evidence, no decision (ADR-049 INV-E)'
    end
  end

  # C4 / the gate is evidence-driven, not a hardcoded transport block: an
  # approve on a prompt whose pinned requirement `chat_bound` evidence can
  # meet is granted, while the same press on a `filesystem_operator` prompt is
  # refused (the Phase 3 asymmetry, driven by the pinned value, not by which
  # transport pressed).
  def test_an_approve_is_granted_when_the_requirement_meets_chat_bound_evidence
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store)

      store.__send__(:transaction, operation: 'test.prompt.repin') do |txn|
        txn.execute('test.prompt.repin', <<~SQL, ['chat_bound', prompt.reference_digest])
          UPDATE tamoz_comms_approval_prompts SET required_evidence = ? WHERE reference_digest = ?
        SQL
      end

      press(gateway, "approve:#{reference}", update_id: 95)

      decision = pending(adapter, prompt, now: Time.utc(2026, 8, 10, 12, 0, 4))

      assert_equal 'approve', decision.fetch('direction'),
                   'chat_bound evidence meets a chat_bound requirement (ADR-049 INV-B)'
    end
  end

  # C4 / exact binding across surfaces: a press whose surface does not match
  # the prompt's bound surface records a durable refusal and creates no
  # decision.
  def test_a_cross_surface_press_is_refused
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store)

      press(gateway, "approve:#{reference}", update_id: 96,
                                             surface_id: 'telegram-other', surface_revision: 3)

      decision = pending(adapter, prompt)

      assert_nil decision, 'a press on the wrong surface never resolves (contract §7.1)'
      rows = inbound_dispositions(adapter, surface: 'telegram-other')

      assert rows.any? { |row| row[0] == 'rejected' && row[1] == 'binding_mismatch' },
             'the cross-surface press must record a durable binding refusal'
    end
  end

  private

  def boot(adapter, checkpoints)
    store = adapter.bind_comms_store(checkpoints)
    store.deploy_surface(descriptor.wire, now: Time.utc(2026, 8, 10, 12, 0, 0))
    transport = ScriptedTransport.new
    transport.batch([])
    gateway = Tamoz::Agent::CommsGateway.new(
      adapter:, checkpoints:, transport:, descriptor:, poller_owner: 'gateway:test'
    )
    [store, gateway]
  end

  def active_prompt(store, ttl_s: 900)
    reference, prompt = Comms::ApprovalPrompt.build(
      surface_id: 'telegram-ops', surface_revision: 1,
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      prompt_ttl_s: ttl_s, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
    )
    store.insert_prompt(prompt.wire)
    store.activate_prompt(reference_digest: prompt.reference_digest, now: Time.utc(2026, 8, 10, 12, 0, 1))
    [reference, prompt]
  end

  # rubocop:disable Metrics/ParameterLists -- the callback's bound context
  # (correspondent + surface) is exactly what the binding oracles vary.
  def press(gateway, data, update_id:, correspondent_id: 111_111_11,
            surface_id: 'telegram-ops', surface_revision: 1,
            now: Time.utc(2026, 8, 10, 12, 0, 2))
    transport = gateway.instance_variable_get(:@transport)
    unless surface_id == 'telegram-ops' && surface_revision == 1
      transport = ScriptedTransport.new(surface_id:, surface_revision:)
      gateway.instance_variable_set(:@transport, transport)
    end
    transport.batch([callback_update(data, update_id, correspondent_id:)])
    transport.receipt = { 'message_id' => 1, 'date' => 1 }
    gateway.serve_once(now:)
  end
  # rubocop:enable Metrics/ParameterLists

  def pending(adapter, prompt, now: Time.utc(2026, 8, 10, 12, 0, 3))
    adapter.bind_comms_decision_store.pending_decision_for(
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupt_digest: prompt.interrupt_digest, now:
    )
  end

  # The durable inbound ledger for this surface, newest first — the refusal
  # records of the bar's C1 are rows here, not assertions in prose.
  def inbound_dispositions(adapter, surface: 'telegram-ops')
    adapter.__send__(:read, operation: 'test.inbound.dispositions') do |txn|
      txn.rows('test.inbound.dispositions', <<~SQL, [surface])
        SELECT disposition, reason FROM tamoz_comms_inbound
        WHERE surface_id = ? ORDER BY ingested_at_ms DESC
      SQL
    end
  end

  def callback_update(data, id, correspondent_id: 111_111_11)
    { 'update_id' => id,
      'callback_query' => { 'id' => "q-#{id}", 'from' => { 'id' => correspondent_id },
                            'message' => { 'chat' => { 'id' => 222_222_22, 'type' => 'private' } },
                            'data' => data } }
  end

  class ScriptedTransport
    attr_accessor :receipt

    def initialize(surface_id: 'telegram-ops', surface_revision: 1)
      @surface_id = surface_id
      @surface_revision = surface_revision
    end

    def batch(updates)
      @updates = updates
    end

    def poll(next_offset:, limit:, timeout_s:)
      ids = @updates.map { |update| update.fetch('update_id') }
      { updates: @updates.map { |update| normalize(update) }, next_offset: ids.max && (ids.max + 1) }
    end

    def deliver(_delivery)
      @receipt || { 'message_id' => 1, 'date' => 1 }
    end

    def normalize(update)
      callback = update['callback_query']
      message = callback['message']
      Comms::InboundEnvelope.new(
        surface_id: @surface_id, surface_revision: @surface_revision,
        update_id: update.fetch('update_id'), raw_payload_hash: 'd' * 64,
        parser_version: 1, kind: 'callback',
        correspondent_id: "telegram:user:#{callback.fetch('from').fetch('id')}",
        conversation_id: "telegram:chat:#{message.fetch('chat').fetch('id')}",
        text: callback.fetch('data'), observed_time: Time.utc(2026, 8, 10, 12, 0, 0)
      ).wire
    end
  end
end
# rubocop:enable Lint/UnusedMethodArgument
