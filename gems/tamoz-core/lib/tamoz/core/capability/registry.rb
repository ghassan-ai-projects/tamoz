# frozen_string_literal: true

module Tamoz
  module Core
    module Capability
      # P18 — the closed set of the four built-in source kinds.
      BUILT_IN_SOURCES = %w[local skill mcp websearch].freeze

      # P18 (docs/P18_CAPABILITY_HOST_PLAN.md §2, C3/C6) — the capability
      # registry. Built at session construction from the four BUILT-IN sources;
      # SEALED after construction. The closed-world invariant (C4/DC-6): the
      # registry is the closed set of built-ins; a fifth/extra/forged source
      # registration fails with `DescriptorConflictError`, and no source object
      # is constructible from skill/catalog/profile/MCP content (invariant 42).
      #
      # The invariant-35 authority intersection is computed ONCE from a
      # policy-derived ADMISSION SET passed in at construction — the registry
      # never re-reads profile policy (that stays the P8 binding +
      # `verify_profile_binding!`). `surface` is descriptors-as-data intersected
      # with the admission set, immutable mid-turn.
      Registry = Data.define(:sources, :surface, :names, :declared) do
        def self.build(sources:, admission_set:)
          unless sources.is_a?(Array) && sources.all? { |s| s.is_a?(Source) }
            raise Tamoz::ConfigurationError, "sources must be Capability::Source values"
          end
          # Closed world (C4/DC-6): every source_id must start with one of the
          # four built-in prefixes — a fifth/forged source fails at
          # construction, never at dispatch.
          sources.each do |source|
            unless built_in_prefix?(source.source_id)
              raise DescriptorConflictError,
                    "source #{source.source_id.inspect} is not a built-in " \
                    "capability source (#{BUILT_IN_SOURCES.inspect})"
            end
          end
          # C3/C6: a source may only carry descriptors that belong to it —
          # descriptor.source_id must match the containing source. This closes
          # the smuggling path (a "local" source cannot surface an
          # "mcp:" descriptor under a built-in prefix).
          sources.each do |source|
            source.descriptors.each do |descriptor|
              unless descriptor.source_id == source.source_id
                raise DescriptorConflictError,
                      "descriptor #{descriptor.id.inspect} (source " \
                      "#{descriptor.source_id.inspect}) does not belong to " \
                      "source #{source.source_id.inspect}"
              end
            end
          end

          registry = build_registry(sources)
          surface = compute_surface(registry, admission_set)
          send(
            :new,
            sources: sources.freeze,
            surface: surface.freeze,
            names: surface.keys.freeze,
            declared: registry.transform_values { |entry| entry.fetch(:descriptor) }.freeze
          )
        end

        # The model-visible surface: descriptor-id => descriptor (the
        # intersection result, immutable).
        def descriptors = surface

        def declared_descriptors = declared

        def admitted?(descriptor_id) = surface.key?(String(descriptor_id))

        def source_for(descriptor_id)
          sources.find do |source|
            source.definition_digests.key?(descriptor_id)
          end
        end

        # C3: a forged/extra registration is refused — the registry is sealed.
        def register(_source)
          raise DescriptorConflictError,
                "the capability registry is sealed; only the four built-in " \
                "sources register at session construction"
        end

        # The registry is constructed ONLY through build — direct value
        # construction would bypass the closed-world and descriptor-source
        # consistency checks (critic finding F4). Data.define provides `new`;
        # it is private here, so `Registry.new(...)` is refused.
        class << self
          private :new
        end

        class << self
          private

          def build_registry(sources)
            sources.each_with_object({}) do |source, registry|
              source.descriptors.each do |descriptor|
                if registry.key?(descriptor.id)
                  raise DescriptorConflictError,
                        "descriptor id #{descriptor.id.inspect} collides across sources"
                end
                registry[descriptor.id] = {source:, descriptor:}
              end
            end
          end

          def compute_surface(registry, admission_set)
            admitted = normalize_admission(admission_set)
            registry.each_with_object({}) do |(descriptor_id, entry), surface|
              next unless entry.fetch(:descriptor).availability == :enabled
              next unless admitted.include?(descriptor_id)

              surface[descriptor_id] = entry.fetch(:descriptor)
            end
          end

          def normalize_admission(admission_set)
            case admission_set
            when Hash
              admission_set.keys.map(&:to_s)
            when Array
              admission_set.map(&:to_s)
            else
              raise Tamoz::ConfigurationError,
                    "admission_set must be a hash or array of capability ids"
            end
          end

          # The four built-in prefixes. A prefixed source_id (skill:/mcp:/
          # websearch:) must carry a non-empty suffix — "skill:" with an empty
          # name is not a valid built-in source id.
          def built_in_prefix?(source_id)
            source_id == "local" ||
              source_id == "websearch" ||
              (source_id.start_with?("skill:") && source_id.length > "skill:".length) ||
              (source_id.start_with?("mcp:") && source_id.length > "mcp:".length) ||
              (source_id.start_with?("websearch:") && source_id.length > "websearch:".length)
          end
        end
      end
    end
  end
end
