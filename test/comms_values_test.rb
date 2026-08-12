# frozen_string_literal: true

require_relative 'test_helper'

# Slice B (COMMS_TELEGRAM_PLAN §3) — the tamoz-comms value layer: every
# channel value validates and freezes all fields, round-trips its durable wire
# form, and derives domain-separated digests deterministically (design §6).
#
# Each case asserts one value's whole contract — validation, digest, wire — in
# one scenario.
# rubocop:disable Minitest/MultipleAssertions
class CommsValuesTest < Minitest::Test
  Comms = Tamoz::Comms

  def surface_fields
    {
      surface_id: 'telegram-ops', revision: 3, kind: 'telegram',
      transport: { mode: 'long_poll',
                   credential_ref: { kind: 'env', name: 'TAMOZ_TELEGRAM_BOT_TOKEN' },
                   poll_timeout_s: 30, batch: 50, max_response_bytes: 262_144 },
      identity: { expected_bot_id: 7_463_512_990 },
      admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] },
      threading: 'conversation', profile_id: 'ops',
      approvals: { mode: 'deny_only', prompt_ttl_s: 900 },
      rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'truncate' },
      limits: { max_inbound_bytes: 8192, max_open_requests: 50,
                max_denial_prompts_per_request: 4, outbox_capacity: 500,
                control_capacity: 50, per_chat_messages_per_s: 1.0,
                global_messages_per_s: 25.0 },
      classification: 'restricted'
    }
  end

  def surface(**overrides)
    Comms::SurfaceDescriptor.build(**surface_fields, **overrides)
  end

  def test_surface_digest_is_domain_separated_and_revision_sensitive
    a = surface
    b = surface

    assert_match(/\A[0-9a-f]{64}\z/, a.definition_digest)
    assert_equal a.definition_digest, b.definition_digest
    refute_equal a.definition_digest, surface(profile_id: 'other').definition_digest,
                 'a profile change must change the content address'
    refute_equal a.definition_digest, surface(revision: 4).definition_digest
  end

  def test_surface_fields_are_frozen
    descriptor = surface

    assert_predicate descriptor, :frozen?
    assert_predicate descriptor.transport, :frozen?
    assert_raises(FrozenError) { descriptor.transport[:mode] = 'webhook' }
  end

  def test_surface_rejects_an_empty_allowlist
    error = assert_raises(Comms::ValidationError) do
      surface(admission: { direct: 'allowlist', correspondents: [] })
    end
    assert_match(/empty allowlist/, error.message)
  end

  def test_surface_rejects_open_modes_and_unknown_kinds
    assert_raises(Comms::ValidationError) { surface(kind: 'slack') }
    assert_raises(Comms::ValidationError) { surface(threading: 'by_thread') }
    assert_raises(Comms::ValidationError) { surface(admission: { direct: 'open' }) }
    assert_raises(Comms::ValidationError) { surface(approvals: { mode: 'grant', prompt_ttl_s: 900 }) }
    assert_raises(Comms::ValidationError) { surface(rendering: { format: 'plain', max_parts: 5, part_characters: 3500, overflow: 'upload' }) }
  end

  def test_surface_wire_round_trip
    descriptor = surface
    copy = Comms::SurfaceDescriptor.from_wire(descriptor.wire)

    assert_equal descriptor.definition_digest, copy.definition_digest
    assert_equal descriptor.wire, copy.wire
    assert_equal({ direct: 'allowlist', correspondents: ['telegram:user:11111111'] }, copy.admission)
  end

  def test_surface_digest_is_deterministic_across_key_order
    left = surface(admission: { direct: 'allowlist', correspondents: ['telegram:user:11111111'] })
    right = surface(admission: { correspondents: ['telegram:user:11111111'], direct: 'allowlist' })

    assert_equal left.definition_digest, right.definition_digest
  end

  def envelope(**overrides)
    base = {
      surface_id: 'telegram-ops', surface_revision: 3, update_id: 12_345,
      raw_payload_hash: 'a' * 64, parser_version: 1, kind: 'text',
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      text: 'hello', observed_time: Time.utc(2026, 8, 10, 12, 0, 0)
    }
    Comms::InboundEnvelope.new(**base, **overrides)
  end

  def test_envelope_validates_ids_text_and_kinds
    assert_raises(Comms::ValidationError) { envelope(update_id: 'abc') }
    assert_raises(Comms::ValidationError) { envelope(correspondent_id: 'telegram:chat:1') }
    assert_raises(Comms::ValidationError) { envelope(conversation_id: 'tg:chat:2') }
    assert_raises(Comms::ValidationError) { envelope(kind: 'media') }
    assert_raises(Comms::ValidationError) { envelope(text: 'x' * 9000) }
    assert_raises(Comms::ValidationError) { envelope(command: 'help', arguments: nil, text: '/help') }
  end

  def test_envelope_wire_round_trip
    value = envelope
    copy = Comms::InboundEnvelope.from_wire(value.wire)

    assert_equal value.wire, copy.wire
    assert_equal value.observed_time, copy.observed_time
    assert_predicate copy, :text?
    refute_predicate copy, :command?
  end

  def delivery(**overrides)
    Comms::Delivery.build(
      conversation_id: 'telegram:chat:22222222', kind: 'answer',
      text: 'here is the answer', part_index: 0, part_count: 1,
      journaled: true, render_version: 1, content_digest: 'b' * 64,
      **overrides
    )
  end

  def test_delivery_id_is_derived_and_part_version_sensitive
    a = delivery
    b = delivery

    assert_equal a.delivery_id, b.delivery_id
    refute_equal a.delivery_id, delivery(part_index: 1, part_count: 2).delivery_id
    refute_equal a.delivery_id, delivery(render_version: 2).delivery_id
    refute_equal a.delivery_id, delivery(text: 'different bytes', content_digest: 'c' * 64).delivery_id,
                 'different content must not collide under the same logical id'
  end

  def test_delivery_identity_key_distinguishes_repeated_occurrences
    first = delivery(identity_key: 'occurrence-1')
    repeat = delivery(identity_key: 'occurrence-1')
    second = delivery(identity_key: 'occurrence-2')

    assert_equal first.delivery_id, repeat.delivery_id
    refute_equal first.delivery_id, second.delivery_id
  end

  def test_delivery_rejects_an_unbounded_identity_key
    assert_raises(Comms::ValidationError) { delivery(identity_key: 'x' * 257) }
  end

  def test_delivery_validates_kinds_parts_and_operations
    assert_raises(Comms::ValidationError) { delivery(kind: 'spam') }
    assert_raises(Comms::ValidationError) { delivery(part_index: 2, part_count: 1) }
    assert_raises(Comms::ValidationError) { delivery(part_count: 0) }
    assert_raises(Comms::ValidationError) { delivery(operation: 'delete_message') }
    assert_raises(Comms::ValidationError) { delivery(journaled: 'yes') }
    assert_raises(Comms::ValidationError) { delivery(text: 'x' * 5000) }
  end

  def test_delivery_wire_round_trip
    value = delivery
    copy = Comms::Delivery.from_wire(value.wire)

    assert_equal value.wire, copy.wire
    assert_equal 'answer', copy.kind
    refute_predicate copy, :ephemeral?
  end

  def binding(**overrides)
    Comms::Binding.new(
      surface_id: 'telegram-ops', surface_revision: 3,
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      bound_at: Time.utc(2026, 8, 10, 12, 0, 0), bound_by: 'operator:ghassan',
      **overrides
    )
  end

  def test_binding_validates_status_and_revocation
    value = binding

    assert_predicate value, :active?
    refute_predicate value, :revoked?
    assert_raises(Comms::ValidationError) { binding(status: 'pending') }
    assert_raises(Comms::ValidationError) { binding(status: 'revoked') }
    assert_raises(Comms::ValidationError) { binding(correspondent_id: 'telegram:chat:1') }
  end

  def test_binding_wire_round_trip
    value = binding

    assert_equal value.wire, Comms::Binding.from_wire(value.wire).wire
  end

  def test_conversation_validates_route
    conversation = Comms::Conversation.new(
      surface_id: 'telegram-ops', surface_revision: 3,
      conversation_id: 'telegram:chat:22222222', thread_id: 'tg.ops.abc',
      profile_id: 'ops', bound_at: Time.utc(2026, 8, 10, 12, 0, 0)
    )

    assert_equal 'tg.ops.abc', conversation.thread_id
    assert_equal conversation.wire, Comms::Conversation.from_wire(conversation.wire).wire
    assert_raises(Comms::ValidationError) do
      Comms::Conversation.new(surface_id: 'telegram-ops', surface_revision: 3,
                              conversation_id: 'telegram:chat:22222222', thread_id: 'tg.ops.abc',
                              profile_id: 'ops', threading: 'by_message',
                              bound_at: Time.utc(2026, 8, 10, 12, 0, 0))
    end
  end

  def test_prompt_reference_is_single_use_and_digest_only
    reference_a, prompt_a = Comms::ApprovalPrompt.build(
      surface_id: 'telegram-ops', surface_revision: 1,
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      prompt_ttl_s: 900, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
    )
    reference_b, prompt_b = Comms::ApprovalPrompt.build(
      surface_id: 'telegram-ops', surface_revision: 1,
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      prompt_ttl_s: 900, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
    )

    assert_match(/\A[0-9a-f]{32}\z/, reference_a, 'the reference is exactly 128 bits')
    assert_match(/\A[0-9a-f]{64}\z/, prompt_a.reference_digest)
    refute_equal reference_a, reference_b, 'two prompts never share a reference'
    refute_equal prompt_a.reference_digest, prompt_b.reference_digest
    assert prompt_a.expired?(Time.utc(2026, 8, 10, 12, 30, 0)), 'the prompt expires after its TTL'
    assert_equal prompt_a.wire, Comms::ApprovalPrompt.from_wire(prompt_a.wire).wire
  end

  def test_prompt_pins_required_evidence_from_the_trusted_policy
    _reference, prompt = Comms::ApprovalPrompt.build(
      surface_id: 'telegram-ops', surface_revision: 1,
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      prompt_ttl_s: 900, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
    )

    assert_equal 'filesystem_operator', prompt.required_evidence,
                 'under v1 policy every prompt pins filesystem_operator (ADR-049 INV-D)'
    assert_equal prompt.required_evidence, Comms::ApprovalPrompt.from_wire(prompt.wire).required_evidence

    legacy_wire = prompt.wire.except('required_evidence')

    assert_equal 'filesystem_operator',
                 Comms::ApprovalPrompt.from_wire(legacy_wire).required_evidence,
                 'a pre-migration wire without the field reads the safe default (never under-gated)'
  end

  def test_prompt_rejects_a_non_lattice_required_evidence
    prompt = Comms::ApprovalPrompt.build(
      surface_id: 'telegram-ops', surface_revision: 1,
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      prompt_ttl_s: 900, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
    ).last

    error = assert_raises(Comms::ValidationError) do
      Comms::ApprovalPrompt.from_wire(prompt.wire.merge('required_evidence' => 'root'))
    end
    assert_match(/evidence must be one of/, error.message)
  end

  def test_prompt_validates_lifecycle_fields
    prompt = Comms::ApprovalPrompt.build(
      surface_id: 'telegram-ops', surface_revision: 1,
      thread_id: 'tg.ops.abc', occurrence_id: 'req-1',
      interrupts: [{ task_id: 't', call_index: 0, descriptor: { 'kind' => 'approve_tool' } }],
      correspondent_id: 'telegram:user:11111111', conversation_id: 'telegram:chat:22222222',
      prompt_ttl_s: 900, created_at: Time.utc(2026, 8, 10, 12, 0, 0)
    ).last

    assert_raises(Comms::ValidationError) do
      Comms::ApprovalPrompt.from_wire(prompt.wire.merge('status' => 'consumed'))
    end
    assert_raises(Comms::ValidationError) do
      Comms::ApprovalPrompt.from_wire(prompt.wire.merge('status' => 'active'))
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions
