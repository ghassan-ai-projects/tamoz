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
          Tamoz::Core.digest(DIGEST_DOMAIN, fields)
        end

        def validate!(**fields)
          validate_identity!(fields)
          validate_classification!(fields)
          validate_required_fields!(fields)
          validate_policies!(fields)
          validate_shapes!(fields)
          budgets = normalized_budgets(fields)
          validate_digests!(fields)
          validate_egress!(fields)
          validate_secret_handling!(fields, budgets)
          frozen_fields(fields, budgets)
        end

        def validate_identity!(fields)
          refuse!("capability id must be a bounded string") unless bounded_string?(fields.fetch(:id))
          return if bounded_string?(fields.fetch(:source_id))

          refuse!("capability source_id must be a bounded string")
        end

        def validate_classification!(fields)
          require_member!(KINDS, fields.fetch(:kind), "kind must be one of #{KINDS.inspect}")
          require_member!(TRUSTS, fields.fetch(:trust), "trust must be one of #{TRUSTS.inspect}")
          require_member!(EFFECT_CLASSES, fields.fetch(:effect_class),
                          "effect_class must be one of #{EFFECT_CLASSES.inspect}")
          require_member!(%i[enabled disabled], fields.fetch(:availability),
                          "availability must be enabled or disabled")
        end

        def validate_required_fields!(fields)
          missing = missing_fields(fields)
          return if missing.empty?

          refuse!("capability descriptor is missing required fields: #{missing.join(', ')}")
        end

        def missing_fields(fields)
          missing = %i[approval_policy egress_policy_digest egress_policy_ref secret_handling
                       request_budget output_budget retry_policy reconciliation_policy].select do |key|
            fields.fetch(key).equal?(MISSING)
          end
          missing << :schema_digest if fields.fetch(:schema_digest).equal?(MISSING)
          missing << :source_digest if fields.fetch(:source_digest).nil?
          missing
        end

        def validate_policies!(fields)
          require_member!(%i[none required], fields.fetch(:approval_policy),
                          "approval_policy must be none or required")
          require_member!(%i[none read_only], fields.fetch(:retry_policy), "retry_policy must be none or read_only")
          require_member!(%i[none explicit], fields.fetch(:reconciliation_policy),
                          "reconciliation_policy must be none or explicit")
          validate_effect_policy!(fields)
        end

        def validate_effect_policy!(fields)
          effect_class = fields.fetch(:effect_class)
          if effect_class == :read_only && fields.fetch(:approval_policy) != :none
            refuse!("read_only capabilities cannot require approval")
          end
          return unless effect_class == :reconcilable && fields.fetch(:reconciliation_policy) != :explicit

          refuse!("reconcilable capabilities require explicit reconciliation")
        end

        def validate_shapes!(fields)
          refuse!("protocol_profile must be a hash") unless fields.fetch(:protocol_profile).is_a?(Hash)
          schemas = fields.values_at(:input_schema, :output_schema)
          refuse!("schemas must be hashes") unless schemas.all? { |schema| schema.nil? || schema.is_a?(Hash) }
          return if string_array?(fields.fetch(:requested_scopes))

          refuse!("requested_scopes must be an array of strings")
        end

        def normalized_budgets(fields)
          {
            request_budget: normalize_budget(fields.fetch(:request_budget), "request_budget", MAX_REQUEST_BYTES),
            output_budget: normalize_budget(fields.fetch(:output_budget), "output_budget", MAX_OUTPUT_BYTES)
          }
        end

        def validate_digests!(fields)
          digests = fields.values_at(:schema_digest, :source_digest, :egress_policy_digest)
          unless digests.all? { |digest| Tamoz::Core.valid_digest?(digest) }
            refuse!("descriptor policy and schema digests must be sha256 digests")
          end
          unless fields.fetch(:schema_digest) == Descriptor.schema_digest_for(*fields.values_at(:input_schema,
                                                                                                :output_schema))
            refuse!("schema_digest does not match the pinned schemas")
          end
          return if fields.fetch(:source_digest) == Descriptor.source_digest_for(fields.fetch(:source_id))

          refuse!("source_digest does not match the capability source")
        end

        def validate_egress!(fields)
          reference = fields.fetch(:egress_policy_ref)
          refuse!("egress_policy_ref is not a truthful bounded reference") unless egress_reference?(reference)
          unless fields.fetch(:egress_policy_digest) == Descriptor.egress_digest_for(reference)
            refuse!("egress_policy_digest does not match the policy reference")
          end
          return if networked?(fields.fetch(:kind)) == (reference != "none")

          refuse!("networked capabilities require an egress policy reference and local capabilities do not")
        end

        def validate_secret_handling!(fields, budgets)
          refuse!("secret_handling must be reject_values") unless fields.fetch(:secret_handling) == :reject_values
          return unless secret_candidates(fields, budgets).any? { |value| Tamoz::Core.secret_shaped?(value) }

          raise Tamoz::SensitiveValueError, "capability descriptors cannot contain credential values"
        end

        def secret_candidates(fields, budgets)
          fields.values_at(:id, :source_id, :schema_digest, :source_digest, :egress_policy_digest,
                           :protocol_profile, :input_schema, :output_schema, :requested_scopes,
                           :egress_policy_ref) + budgets.values
        end

        def frozen_fields(fields, budgets)
          {
            id: fields.fetch(:id).freeze, kind: fields.fetch(:kind), source_id: fields.fetch(:source_id).freeze,
            schema_digest: fields.fetch(:schema_digest), trust: fields.fetch(:trust),
            effect_class: fields.fetch(:effect_class), approval_policy: fields.fetch(:approval_policy),
            egress_policy_digest: fields.fetch(:egress_policy_digest),
            egress_policy_ref: fields.fetch(:egress_policy_ref).freeze,
            secret_handling: fields.fetch(:secret_handling), **budgets,
            retry_policy: fields.fetch(:retry_policy), reconciliation_policy: fields.fetch(:reconciliation_policy),
            protocol_profile: Tamoz::Core.deep_freeze(fields.fetch(:protocol_profile)),
            input_schema: frozen_schema(fields[:input_schema]), output_schema: frozen_schema(fields[:output_schema]),
            source_digest: fields.fetch(:source_digest).freeze,
            requested_scopes: fields.fetch(:requested_scopes).map(&:freeze).freeze,
            availability: fields.fetch(:availability)
          }.freeze
        end

        def frozen_schema(schema)
          schema && Tamoz::Core.deep_freeze(schema)
        end

        def bounded_string?(value)
          value.is_a?(String) && !value.empty? && value.bytesize <= 512
        end

        def string_array?(value)
          value.is_a?(Array) && value.all?(String)
        end

        def egress_reference?(reference)
          reference.is_a?(String) && (reference == "none" || reference.match?(/\A(?:mcp|websearch):[^\s]+\z/))
        end

        def networked?(kind)
          %i[mcp_tool websearch].include?(kind)
        end

        def require_member!(allowed, value, message)
          refuse!(message) unless allowed.include?(value)
        end

        def refuse!(message)
          raise Tamoz::ConfigurationError, message
        end

        def normalize_budget(budget, name, maximum)
          unless budget.is_a?(Hash) && budget.keys.map(&:to_s).sort == ["max_bytes"] &&
                 budget.fetch("max_bytes").is_a?(Integer) && budget.fetch("max_bytes").between?(1, maximum)
            refuse!("#{name} must contain one integer max_bytes between 1 and #{maximum}")
          end

          Tamoz::Core.deep_freeze({ "max_bytes" => budget.fetch("max_bytes") })
        end
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
