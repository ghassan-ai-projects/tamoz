# frozen_string_literal: true

module Tamoz
  module Core
    module Capability
      # P18 §2 — one CapabilitySource: a source_id, its frozen descriptors, and
      # a per-source dispatcher interface. The registry is the CLOSED set of
      # the four built-ins; no source object is constructible from
      # skill/catalog/profile/MCP content (invariant 42).
      #
      # The dispatcher interface (implemented by each source's gem):
      #   validate(descriptor, arguments) -> typed D-7 result | raises ToolArgumentError
      #   execute(descriptor, arguments, context:) -> typed result
      Source = Data.define(
        :source_id, :descriptors, :definition_digests
      ) do
        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity -- source admission is one closed contract.
        def initialize(source_id:, descriptors:, definition_digests: nil)
          unless source_id.is_a?(String) && !source_id.empty?
            raise Tamoz::ConfigurationError, "source_id must be a non-empty string"
          end
          unless descriptors.is_a?(Array) && descriptors.all? { |d| d.is_a?(Descriptor) }
            raise Tamoz::ConfigurationError, "descriptors must be Capability::Descriptor values"
          end
          ids = descriptors.map(&:id)
          unless ids.uniq.length == ids.length
            raise Tamoz::ConfigurationError, "a capability source cannot contain duplicate descriptor ids"
          end
          digests = definition_digests ||
                    descriptors.each_with_object({}) do |descriptor, map|
                      map[descriptor.id] = descriptor.definition_digest
                    end
          unless digests.is_a?(Hash) && digests.keys.map(&:to_s).sort == ids.sort &&
                 descriptors.all? { |descriptor| digests[descriptor.id] == descriptor.definition_digest }
            raise Tamoz::ConfigurationError,
                  "definition_digests must exactly bind every descriptor definition"
          end
          super(
            source_id: source_id.freeze,
            descriptors: descriptors.freeze,
            definition_digests: Tamoz::Core.deep_freeze(
              digests.transform_keys(&:to_s)
            )
          )
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      end
    end
  end
end
