# frozen_string_literal: true

require_relative 'test_helper'

class CapabilityDescriptorContractTest < Minitest::Test
  Capability = Tamoz::Core::Capability

  def descriptor(**overrides)
    Capability::Descriptor.new(
      id: 'read_file',
      kind: :tool,
      source_id: 'local',
      trust: :local,
      effect_class: :read_only,
      approval_policy: :none,
      egress_policy_ref: "none",
      egress_policy_digest: Capability::Descriptor.egress_digest_for("none"),
      secret_handling: :reject_values,
      request_budget: { "max_bytes" => 16 * 1024 },
      output_budget: { "max_bytes" => 64 * 1024 },
      retry_policy: :read_only,
      reconciliation_policy: :none,
      schema_digest: Capability::Descriptor.schema_digest_for(
        { "type" => "object" }, { "type" => "object" }
      ),
      source_digest: Capability::Descriptor.source_digest_for("local"),
      protocol_profile: { 'transport' => 'in_process' },
      input_schema: { 'type' => 'object' },
      output_schema: { 'type' => 'object' }, **overrides
    )
  end

  def test_descriptor_materializes_complete_policy_and_schema_bindings
    value = descriptor

    assert Tamoz::Core.valid_digest?(value.definition_digest)
    assert Tamoz::Core.valid_digest?(value.schema_digest)
    assert Tamoz::Core.valid_digest?(value.source_digest)
    assert Tamoz::Core.valid_digest?(value.egress_policy_digest)
    assert_equal :none, value.approval_policy
    assert_equal :reject_values, value.secret_handling
    assert_equal({ 'max_bytes' => 16 * 1024 }, value.request_budget)
    assert_equal({ 'max_bytes' => 64 * 1024 }, value.output_budget)
    assert_equal :read_only, value.retry_policy
    assert_equal :none, value.reconciliation_policy
  end

  def test_definition_digest_is_verified_against_all_descriptor_fields
    error = assert_raises(Tamoz::ConfigurationError) do
      descriptor(definition_digest: "sha256:#{'0' * 64}")
    end
    assert_includes error.message, 'definition_digest'
  end

  def test_unknown_effect_class_and_policy_values_fail_closed
    assert_raises(Tamoz::ConfigurationError) { descriptor(effect_class: :unknown_effects) }
    assert_raises(Tamoz::ConfigurationError) { descriptor(approval_policy: :optional) }
    assert_raises(Tamoz::ConfigurationError) { descriptor(secret_handling: :forward_values) }
  end

  def test_source_digest_map_must_bind_every_descriptor
    source = Capability::Source.new(source_id: 'local', descriptors: [descriptor])
    assert_raises(Tamoz::ConfigurationError) do
      Capability::Source.new(
        source_id: 'local',
        descriptors: [descriptor],
        definition_digests: { 'read_file' => "sha256:#{'1' * 64}" }
      )
    end
    assert_equal descriptor.definition_digest, source.definition_digests.fetch('read_file')
  end
end
