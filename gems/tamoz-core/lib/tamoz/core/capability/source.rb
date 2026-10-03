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
        def initialize(source_id:, descriptors:, definition_digests: nil)
          validate_members!(source_id, descriptors)
          digests = definition_digests || descriptors.to_h { |entry| [entry.id, entry.definition_digest] }
          validate_digests!(digests, descriptors)
          super(
            source_id: source_id.freeze,
            descriptors: descriptors.freeze,
            definition_digests: Tamoz::Core.deep_freeze(digests.transform_keys(&:to_s))
          )
        end

        private

        def validate_members!(source_id, descriptors)
          unless source_id.is_a?(String) && !source_id.empty?
            raise Tamoz::ConfigurationError, "source_id must be a non-empty string"
          end
          unless descriptors.is_a?(Array) && descriptors.all?(Descriptor)
            raise Tamoz::ConfigurationError, "descriptors must be Capability::Descriptor values"
          end
          ids = descriptors.map(&:id)
          return if ids.uniq.length == ids.length

          raise Tamoz::ConfigurationError, "a capability source cannot contain duplicate descriptor ids"
        end

        def validate_digests!(digests, descriptors)
          return if digests.is_a?(Hash) && digests.keys.map(&:to_s).sort == descriptors.map(&:id).sort &&
                    descriptors.all? { |descriptor| digests[descriptor.id] == descriptor.definition_digest }

          raise Tamoz::ConfigurationError, "definition_digests must exactly bind every descriptor definition"
        end
      end
    end
  end
end
