# frozen_string_literal: true

require_relative 'test_helper'

class CapabilityInventoryTest < Minitest::Test
  Capability = Tamoz::Core::Capability

  def descriptor(id, effect_class: :read_only)
    Capability::Descriptor.new(
      id:, kind: :tool, source_id: 'local', trust: :local, effect_class:,
      approval_policy: effect_class == :read_only ? :none : :required,
      egress_policy_ref: "none",
      egress_policy_digest: Capability::Descriptor.egress_digest_for("none"),
      secret_handling: :reject_values,
      request_budget: { "max_bytes" => 16 * 1024 },
      output_budget: { "max_bytes" => 64 * 1024 },
      retry_policy: effect_class == :read_only ? :read_only : :none,
      reconciliation_policy: :none,
      schema_digest: Capability::Descriptor.schema_digest_for(
        { 'type' => 'object' }, { 'type' => 'object' }
      ),
      source_digest: Capability::Descriptor.source_digest_for('local'),
      protocol_profile: { 'transport' => 'in_process' },
      input_schema: { 'type' => 'object' }, output_schema: { 'type' => 'object' }
    )
  end

  def test_inventory_is_pure_and_distinguishes_declared_from_effective
    host = Tamoz::Tools::CapabilityHost.new(
      sources: [Capability::Source.new(
        source_id: 'local',
        descriptors: [descriptor('read_file'), descriptor('write_file', effect_class: :bounded)]
      )],
      admission_set: ['read_file']
    )

    rows = host.inventory(
      configured_sources: ['local'], catalogued_sources: ['local'],
      materialized_sources: ['local'], reachable_sources: ['local'],
      authorized_ids: ['read_file'], verified_ids: ['read_file'], phase: :discovery
    )
    read = rows.find { |row| row.fetch('id') == 'read_file' }
    write = rows.find { |row| row.fetch('id') == 'write_file' }

    assert read.fetch('declared')
    assert read.fetch('effective')
    assert read.fetch('phase_visible')
    assert_nil read.fetch('reason')
    assert write.fetch('declared')
    refute write.fetch('effective')
    assert_equal 'not_admitted', write.fetch('reason')
    assert_equal(%w[read_file write_file], rows.map { |row| row.fetch('id') })
    assert_predicate rows, :frozen?
    assert rows.all?(&:frozen?)
  end

  def test_inventory_reports_phase_invisibility_without_changing_registry
    host = Tamoz::Tools::CapabilityHost.new(
      sources: [Capability::Source.new(
        source_id: 'local', descriptors: [descriptor('write_file', effect_class: :bounded)]
      )],
      admission_set: ['write_file']
    )

    row = host.inventory(
      configured_sources: ['local'], catalogued_sources: ['local'],
      materialized_sources: ['local'], reachable_sources: ['local'],
      authorized_ids: ['write_file'], verified_ids: ['write_file'], phase: :discovery
    ).fetch(0)

    assert row.fetch('declared')
    refute row.fetch('phase_visible')
    refute row.fetch('effective')
    assert_equal 'phase_invisible', row.fetch('reason')
    assert_equal ['write_file'], host.registry.names
  end

  def test_source_health_reason_cannot_coexist_with_effective_capability
    host = Tamoz::Tools::CapabilityHost.new(
      sources: [Capability::Source.new(
        source_id: 'local', descriptors: [descriptor('read_file')]
      )],
      admission_set: ['read_file']
    )

    row = host.inventory(
      configured_sources: ['local'], catalogued_sources: ['local'],
      materialized_sources: ['local'], reachable_sources: ['local'],
      authorized_ids: ['read_file'], verified_ids: ['read_file'],
      source_reasons: {'local' => 'handshake_failed'}
    ).fetch(0)

    refute row.fetch('effective')
    assert_equal 'handshake_failed', row.fetch('reason')
  end
end
