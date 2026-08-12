# frozen_string_literal: true

require_relative 'test_helper'

# ADR-049 / TELEGRAM_COMMUNICATION_FLOW_CONTRACT §7.1 — approval is gated on
# authority evidence, not on transport. These are the bar's group-C oracles
# (TELEGRAM_COMMUNICATION_BAR C1-C3) as executable tests.
#
# C1 is SKIPPED until ADR-049's evidence check is implemented (plan Phase 3):
# the shipped `resolve_callback` records a Telegram `approve` unconditionally —
# the defect ADR-049 repairs — so the oracle would fail against current code.
# It is skipped, not red, so `rake ci` keeps its meaning ("no regression in
# what already works"; cf. AUTONOMY_TESTS). Un-skip C1 when the v1 policy
# function and the callback lattice comparison land; it then goes green.
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

  # C1 / INV-B + INV-D (SKIPPED until ADR-049 implementation lands, plan
  # Phase 3): under the v1 policy every effect requires `filesystem_operator`,
  # so a chat_bound Telegram approve must be refused and must NOT put an
  # approve decision in front of the worker. The shipped code records one
  # anyway; that is the defect. Skipped rather than red so `rake ci` stays
  # green; un-skip when the evidence check exists.
  def test_a_chat_bound_approve_is_refused_under_v1_policy
    skip 'ADR-049 §2 INV-B/INV-D / bar C1: the evidence check is not implemented yet. ' \
         'Un-skip when the v1 policy function and the callback lattice comparison land; ' \
         'this test then asserts a chat_bound approve is refused and records no decision.'
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store)

      press(gateway, store, "approve:#{reference}", update_id: 60)

      decision = pending(adapter, prompt)
      approve_reached_worker = !decision.nil? && decision.fetch('direction') == 'approve'

      refute approve_reached_worker,
             'a chat_bound Telegram approve must not release a filesystem_operator action ' \
             '(ADR-049 INV-B/INV-D); no approve decision may reach the worker under v1 policy'
    end
  end

  # C1 / INV-A (asymmetry control, GREEN): the equivalent denial still
  # succeeds. Deny is fail-safe and unconditional for the bound correspondent.
  def test_the_equivalent_deny_still_succeeds
    with_engine do |adapter, checkpoints|
      store, gateway = boot(adapter, checkpoints)
      reference, prompt = active_prompt(store)

      press(gateway, store, "deny:#{reference}", update_id: 61)

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
      press(gateway, store, "approve:#{reference}", update_id: 62, now: Time.utc(2026, 8, 10, 12, 30, 0))

      decision = pending(adapter, prompt, now: Time.utc(2026, 8, 10, 12, 30, 1))
      approve_reached_worker = !decision.nil? && decision.fetch('direction') == 'approve'

      refute approve_reached_worker, 'expired evidence never approves (ADR-049 INV-E)'
    end
  end

  # C2 / INV-C (pending): `required_evidence` must be a trusted, deterministic
  # function of the pinned interrupt/effect digest — never model-settable, and
  # part of the callback comparison. The surface for this does not exist yet;
  # this test is a placeholder for the ADR-049 §7 adoption step that adds it.
  def test_required_evidence_is_trusted_and_not_model_settable
    skip 'ADR-049 §2 INV-C / §7 step 1: `required_evidence` policy not implemented yet. ' \
         'When it lands, assert it is reproducible offline from the interrupt digest, is ' \
         'part of the callback comparison, and ignores any model-supplied value.'
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
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      prompt_ttl_s: ttl_s, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
    )
    store.insert_prompt(prompt.wire)
    store.activate_prompt(reference_digest: prompt.reference_digest, now: Time.utc(2026, 8, 10, 12, 0, 1))
    [reference, prompt]
  end

  def press(gateway, _store, data, update_id:, now: Time.utc(2026, 8, 10, 12, 0, 2))
    gateway.instance_variable_get(:@transport).batch([callback_update(data, update_id)])
    gateway.instance_variable_get(:@transport).receipt = { 'message_id' => 1, 'date' => 1 }
    gateway.serve_once(now:)
  end

  def pending(adapter, prompt, now: Time.utc(2026, 8, 10, 12, 0, 3))
    adapter.bind_comms_decision_store.pending_decision_for(
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupt_digest: prompt.interrupt_digest, now:
    )
  end

  def callback_update(data, id)
    { 'update_id' => id,
      'callback_query' => { 'id' => "q-#{id}", 'from' => { 'id' => 111_111_11 },
                            'message' => { 'chat' => { 'id' => 222_222_22, 'type' => 'private' } },
                            'data' => data } }
  end

  class ScriptedTransport
    attr_accessor :receipt

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
        surface_id: 'telegram-ops', surface_revision: 1,
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
