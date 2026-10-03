# frozen_string_literal: true

module Tamoz
  module Tools
    # One inventory read: every declared capability against the control-plane gates the caller observed.
    class InventoryProjection
      SOURCE_GATES = %i[configured catalogued materialized reachable].freeze
      GATE_REASONS = {
        configured: 'unconfigured', catalogued: 'uncatalogued', materialized: 'unmaterialized',
        reachable: 'unreachable', verified: 'unverified'
      }.freeze

      def initialize(registry, gates:, phase:, source_reasons:)
        @registry = registry
        @gates = gates.transform_values { |values| values&.map(&:to_s) }
        @phase = phase
        @source_reasons = source_reasons
      end

      def rows
        @registry.declared_descriptors.map { |id, descriptor| row(id, descriptor) }.freeze
      end

      private

      def row(id, descriptor)
        source_id = @registry.source_for(id).source_id
        gates = gate_values(id, source_id)
        verdict = verdict(id, descriptor, source_id, gates)
        {
          'id' => id, 'source_id' => source_id, 'declared' => true,
          **gates.slice(:configured, :catalogued, :materialized, :reachable, :authorized).transform_keys(&:to_s),
          'effective' => verdict[:effective], 'verified' => gates[:verified],
          'phase_visible' => verdict[:phase_visible],
          **descriptor_facts(descriptor), 'reason' => reason(descriptor, source_id, gates, verdict)
        }.freeze
      end

      def gate_values(id, source_id)
        @gates.to_h do |name, values|
          [name, values&.include?(SOURCE_GATES.include?(name) ? source_id : id)]
        end
      end

      def verdict(id, descriptor, source_id, gates)
        admitted = @registry.admitted?(id)
        phase_visible = @phase.to_sym == :discovery ? descriptor.effect_class == :read_only : true
        effective = admitted && phase_visible && descriptor.availability == :enabled &&
                    (gates.values + [!@source_reasons.key?(source_id)]).all?(true)
        { admitted:, phase_visible:, effective: }
      end

      def descriptor_facts(descriptor)
        {
          'approval_required' => descriptor.approval_policy == :required,
          'effect_class' => descriptor.effect_class.to_s,
          'schema_digest' => descriptor.schema_digest,
          'definition_digest' => descriptor.definition_digest
        }
      end

      def reason(descriptor, source_id, gates, verdict)
        return source_reason(source_id) if @source_reasons.key?(source_id)
        return 'disabled' if descriptor.availability == :disabled
        return 'not_admitted' unless verdict[:admitted]
        return 'missing_grant' unless gates[:authorized]
        return 'phase_invisible' unless verdict[:phase_visible]

        gate_reason(gates) || outcome_reason(descriptor, verdict[:effective])
      end

      def source_reason(source_id)
        reason = @source_reasons.fetch(source_id).to_s
        CapabilityHost::INVENTORY_REASONS.include?(reason) ? reason : 'invalid_configuration'
      end

      def gate_reason(gates)
        failed = GATE_REASONS.find { |gate, _reason| gates[gate] == false }
        return failed.last if failed

        'unknown' unless gates.values.all?(true)
      end

      def outcome_reason(descriptor, effective)
        return nil if effective

        descriptor.approval_policy == :required ? 'approval_required' : 'unavailable'
      end
    end

    private_constant :InventoryProjection
  end
end
