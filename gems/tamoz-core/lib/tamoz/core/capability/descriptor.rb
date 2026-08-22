# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Core
    # rubocop:disable Metrics/ModuleLength -- descriptor validation is one closed
    # world contract and keeping its invariants together is intentional.
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
        :schema_digest,
        :trust,         # :local | :operator | :declared (content never grants)
        :effect_class,  # :read_only | :bounded | :reconcilable
        :approval_policy,
        :egress_policy_digest,
        :egress_policy_ref,
        :secret_handling,
        :request_budget,
        :output_budget,
        :retry_policy,
        :reconciliation_policy,
        :protocol_profile,
        :input_schema,  # schema-driven dispatch (MCP §4 — required)
        :output_schema,
        :source_digest,
        :requested_scopes,
        :availability    # :enabled | :disabled
      ) do
        DIGEST_DOMAIN = "tamoz.core.capability_descriptor.v1\n"
        SCHEMA_DIGEST_DOMAIN = "tamoz.core.capability_schema.v1\n"
        SOURCE_DIGEST_DOMAIN = "tamoz.core.capability_source.v1\n"
        EGRESS_DIGEST_DOMAIN = "tamoz.core.capability_egress.v1\n"
        MAX_REQUEST_BYTES = 1 * 1024 * 1024
        MAX_OUTPUT_BYTES = 4 * 1024 * 1024
        MISSING = Object.new.freeze
        KINDS = %i[tool skill mcp_tool websearch].freeze
        TRUSTS = %i[local operator declared].freeze
        EFFECT_CLASSES = %i[read_only bounded reconcilable].freeze

        def initialize(
          id:, kind:, source_id:, trust:, effect_class:, protocol_profile:,
          input_schema: nil, output_schema: nil, source_digest: nil,
          requested_scopes: [], availability: :enabled, definition_digest: nil,
          schema_digest: MISSING, approval_policy: MISSING, egress_policy_digest: MISSING,
          egress_policy_ref: MISSING, secret_handling: MISSING,
          request_budget: MISSING, output_budget: MISSING, retry_policy: MISSING,
          reconciliation_policy: MISSING
        )
          validated = validate!(
            id:, kind:, source_id:, trust:, effect_class:, protocol_profile:,
            input_schema:, output_schema:, source_digest:, requested_scopes:,
            availability:, schema_digest:, approval_policy:, egress_policy_digest:,
            egress_policy_ref:, secret_handling:, request_budget:, output_budget:,
            retry_policy:, reconciliation_policy:
          )
          computed_digest = compute_digest(validated)
          if definition_digest && definition_digest != computed_digest
            raise Tamoz::ConfigurationError,
                  "definition_digest does not match the capability definition"
          end
          @digest = definition_digest || computed_digest
          super(**validated, definition_digest: @digest)
        end

        def to_h
          {
            "id" => id, "kind" => kind.to_s, "source_id" => source_id,
            "definition_digest" => definition_digest, "schema_digest" => schema_digest,
            "trust" => trust.to_s,
            "effect_class" => effect_class.to_s,
            "approval_policy" => approval_policy.to_s,
            "egress_policy_digest" => egress_policy_digest,
            "egress_policy_ref" => egress_policy_ref,
            "secret_handling" => secret_handling.to_s,
            "request_budget" => request_budget,
            "output_budget" => output_budget,
            "retry_policy" => retry_policy.to_s,
            "reconciliation_policy" => reconciliation_policy.to_s,
            "protocol_profile" => protocol_profile,
            "input_schema" => input_schema, "output_schema" => output_schema,
            "source_digest" => source_digest,
            "requested_scopes" => requested_scopes,
            "availability" => availability.to_s
          }
        end

        def self.schema_digest_for(input_schema, output_schema)
          Tamoz::Core.digest(
            SCHEMA_DIGEST_DOMAIN,
            { "input_schema" => input_schema, "output_schema" => output_schema }
          )
        end

        def self.source_digest_for(source_id)
          Tamoz::Core.digest(SOURCE_DIGEST_DOMAIN, { "source_id" => source_id })
        end

        def self.egress_digest_for(egress_policy_ref)
          Tamoz::Core.digest(EGRESS_DIGEST_DOMAIN, { "ref" => egress_policy_ref })
        end

        private

        def compute_digest(fields)
          definition = fields.reject { |key, _value| key == :definition_digest }
          Tamoz::Core.digest(DIGEST_DOMAIN, definition)
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
          effect_class = fields.fetch(:effect_class)
          missing = %i[approval_policy egress_policy_digest egress_policy_ref secret_handling
                       request_budget output_budget retry_policy reconciliation_policy].select do |key|
            fields.fetch(key).equal?(MISSING)
          end
          missing << :schema_digest if fields.fetch(:schema_digest).equal?(MISSING)
          missing << :source_digest if fields.fetch(:source_digest).nil?
          unless missing.empty?
            raise Tamoz::ConfigurationError,
                  "capability descriptor is missing required fields: #{missing.join(', ')}"
          end
          approval_policy = fields.fetch(:approval_policy)
          retry_policy = fields.fetch(:retry_policy)
          reconciliation_policy = fields.fetch(:reconciliation_policy)
          unless %i[none required].include?(approval_policy)
            raise Tamoz::ConfigurationError, "approval_policy must be none or required"
          end
          unless %i[none read_only].include?(retry_policy)
            raise Tamoz::ConfigurationError, "retry_policy must be none or read_only"
          end
          unless %i[none explicit].include?(reconciliation_policy)
            raise Tamoz::ConfigurationError,
                  "reconciliation_policy must be none or explicit"
          end
          if effect_class == :read_only && approval_policy != :none
            raise Tamoz::ConfigurationError,
                  "read_only capabilities cannot require approval"
          end
          if effect_class == :reconcilable && reconciliation_policy != :explicit
            raise Tamoz::ConfigurationError,
                  "reconcilable capabilities require explicit reconciliation"
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
          schema_digest = fields.fetch(:schema_digest)
          source_digest = fields.fetch(:source_digest)
          egress_policy_digest = fields.fetch(:egress_policy_digest)
          request_budget = normalize_budget(fields.fetch(:request_budget), "request_budget",
                                            MAX_REQUEST_BYTES)
          output_budget = normalize_budget(fields.fetch(:output_budget), "output_budget",
                                           MAX_OUTPUT_BYTES)
          unless Tamoz::Core.valid_digest?(schema_digest) &&
                 Tamoz::Core.valid_digest?(source_digest) &&
                 Tamoz::Core.valid_digest?(egress_policy_digest)
            raise Tamoz::ConfigurationError, "descriptor policy and schema digests must be sha256 digests"
          end
          unless schema_digest == Descriptor.schema_digest_for(fields[:input_schema], fields[:output_schema])
            raise Tamoz::ConfigurationError, "schema_digest does not match the pinned schemas"
          end
          unless source_digest == Descriptor.source_digest_for(source_id)
            raise Tamoz::ConfigurationError, "source_digest does not match the capability source"
          end
          egress_policy_ref = fields.fetch(:egress_policy_ref)
          unless egress_policy_ref.is_a?(String) &&
                 (egress_policy_ref == "none" || egress_policy_ref.match?(/\A(?:mcp|websearch):[^\s]+\z/))
            raise Tamoz::ConfigurationError, "egress_policy_ref is not a truthful bounded reference"
          end
          unless egress_policy_digest == Descriptor.egress_digest_for(egress_policy_ref)
            raise Tamoz::ConfigurationError, "egress_policy_digest does not match the policy reference"
          end
          networked = %i[mcp_tool websearch].include?(fields.fetch(:kind))
          if networked != (egress_policy_ref != "none")
            raise Tamoz::ConfigurationError,
                  "networked capabilities require an egress policy reference and local capabilities do not"
          end
          unless fields.fetch(:secret_handling) == :reject_values
            raise Tamoz::ConfigurationError, "secret_handling must be reject_values"
          end
          values = [id, source_id, schema_digest, source_digest, egress_policy_digest,
                    fields.fetch(:protocol_profile), fields[:input_schema], fields[:output_schema],
                    fields.fetch(:requested_scopes), request_budget, output_budget, egress_policy_ref]
          if values.any? { |value| Tamoz::Core.secret_shaped?(value) }
            raise Tamoz::SensitiveValueError,
                  "capability descriptors cannot contain credential values"
          end

          {
            id: id.freeze, kind: fields.fetch(:kind), source_id: source_id.freeze,
            schema_digest:, trust: fields.fetch(:trust), effect_class:, approval_policy:,
            egress_policy_digest:, egress_policy_ref: fields.fetch(:egress_policy_ref).freeze,
            secret_handling: fields.fetch(:secret_handling), request_budget:, output_budget:,
            retry_policy:, reconciliation_policy:,
            protocol_profile: Tamoz::Core.deep_freeze(fields.fetch(:protocol_profile)),
            input_schema: fields[:input_schema] && Tamoz::Core.deep_freeze(fields[:input_schema]),
            output_schema: fields[:output_schema] && Tamoz::Core.deep_freeze(fields[:output_schema]),
            source_digest: source_digest.freeze,
            requested_scopes: fields.fetch(:requested_scopes).map(&:freeze).freeze,
            availability: fields.fetch(:availability)
          }.freeze
        end

        def normalize_budget(value, name, maximum)
          budget = value
          unless budget.is_a?(Hash) && budget.keys.map(&:to_s).sort == ["max_bytes"] &&
                 budget.fetch("max_bytes").is_a?(Integer) && budget.fetch("max_bytes").between?(1, maximum)
            raise Tamoz::ConfigurationError,
                  "#{name} must contain one integer max_bytes between 1 and #{maximum}"
          end

          Tamoz::Core.deep_freeze({ "max_bytes" => budget.fetch("max_bytes") })
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
