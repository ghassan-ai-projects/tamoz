# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Core
    module Capability
      # P18 (docs/P18_CAPABILITY_HOST_PLAN.md §2, C1) — the unified capability
      # descriptor. Restores the MCP_DESIGN §4 descriptor fields, extended for
      # the other three built-in sources (local tools, skills, websearch).
      #
      # The descriptor is DATA + a definition digest: no code, no content path
      # can construct one from skill/catalog/profile/MCP content (invariant 42
      # — "content never grants" stays source-enforced). Model-visible ids are
      # the existing pinned shapes: bare local tool names, bare
      # load_skill/read_skill_resource, mcp:-qualified MCP/websearch ids.
      Descriptor = Data.define(
        :id,            # the model-visible id (pinned shape above)
        :kind,          # :tool | :skill | :mcp_tool | :websearch
        :source_id,     # "local" | "skill:<source>/<name>" | "mcp:<server>/<tool>" | "websearch:<name>"
        :definition_digest,
        :trust,         # :local | :operator | :declared (content never grants)
        :effect_class,  # :read_only | :bounded | :reconcilable
        :protocol_profile,
        :input_schema,  # schema-driven dispatch (MCP §4 — required)
        :output_schema,
        :source_digest,
        :requested_scopes,
        :availability    # :enabled | :disabled
      ) do
        DIGEST_DOMAIN = "tamoz.core.capability_descriptor.v1\n"
        KINDS = %i[tool skill mcp_tool websearch].freeze
        TRUSTS = %i[local operator declared].freeze
        EFFECT_CLASSES = %i[read_only bounded reconcilable].freeze

        def initialize(
          id:, kind:, source_id:, trust:, effect_class:, protocol_profile:,
          input_schema: nil, output_schema: nil, source_digest: nil,
          requested_scopes: [], availability: :enabled, definition_digest: nil
        )
          validated = validate!(
            id:, kind:, source_id:, trust:, effect_class:, protocol_profile:,
            input_schema:, output_schema:, source_digest:, requested_scopes:,
            availability:
          )
          @digest = definition_digest || compute_digest(validated)
          super(**validated, definition_digest: @digest)
        end

        def to_h
          {
            "id" => id, "kind" => kind.to_s, "source_id" => source_id,
            "definition_digest" => definition_digest, "trust" => trust.to_s,
            "effect_class" => effect_class.to_s,
            "protocol_profile" => protocol_profile,
            "input_schema" => input_schema, "output_schema" => output_schema,
            "source_digest" => source_digest,
            "requested_scopes" => requested_scopes,
            "availability" => availability.to_s
          }
        end

        private

        def compute_digest(fields)
          definition = fields.reject { |key, _value| key == :definition_digest }
          "sha256:#{Digest::SHA256.hexdigest(
            DIGEST_DOMAIN + JSON.generate(Tamoz::Core.canonical(definition))
          )}"
        end

        def validate!(**fields)
          id = fields.fetch(:id)
          source_id = fields.fetch(:source_id)
          unless id.is_a?(String) && !id.empty? && id.bytesize <= 512
            raise Tamoz::ConfigurationError, "capability id must be a bounded string"
          end
          unless source_id.is_a?(String) && !source_id.empty? && source_id.bytesize <= 512
            raise Tamoz::ConfigurationError, "capability source_id must be a bounded string"
          end
          unless KINDS.include?(fields.fetch(:kind))
            raise Tamoz::ConfigurationError, "kind must be one of #{KINDS.inspect}"
          end
          unless TRUSTS.include?(fields.fetch(:trust))
            raise Tamoz::ConfigurationError, "trust must be one of #{TRUSTS.inspect}"
          end
          unless EFFECT_CLASSES.include?(fields.fetch(:effect_class))
            raise Tamoz::ConfigurationError, "effect_class must be one of #{EFFECT_CLASSES.inspect}"
          end
          unless %i[enabled disabled].include?(fields.fetch(:availability))
            raise Tamoz::ConfigurationError, "availability must be enabled or disabled"
          end
          unless fields.fetch(:protocol_profile).is_a?(Hash)
            raise Tamoz::ConfigurationError, "protocol_profile must be a hash"
          end
          [fields[:input_schema], fields[:output_schema]].each do |schema|
            next if schema.nil?

            unless schema.is_a?(Hash)
              raise Tamoz::ConfigurationError, "schemas must be hashes"
            end
          end
          unless fields.fetch(:requested_scopes).is_a?(Array) &&
                 fields.fetch(:requested_scopes).all? { |s| s.is_a?(String) }
            raise Tamoz::ConfigurationError, "requested_scopes must be an array of strings"
          end

          {
            id: id.freeze, kind: fields.fetch(:kind), source_id: source_id.freeze,
            trust: fields.fetch(:trust), effect_class: fields.fetch(:effect_class),
            protocol_profile: Tamoz::Core.deep_freeze(fields.fetch(:protocol_profile)),
            input_schema: fields[:input_schema] && Tamoz::Core.deep_freeze(fields[:input_schema]),
            output_schema: fields[:output_schema] && Tamoz::Core.deep_freeze(fields[:output_schema]),
            source_digest: fields[:source_digest]&.freeze,
            requested_scopes: fields.fetch(:requested_scopes).map(&:freeze).freeze,
            availability: fields.fetch(:availability)
          }.freeze
        end
      end
    end
  end
end
