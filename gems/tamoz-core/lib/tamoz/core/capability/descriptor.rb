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
          validated = DescriptorRules.new(
            id:, kind:, source_id:, trust:, effect_class:, protocol_profile:,
            input_schema:, output_schema:, source_digest:, requested_scopes:,
            availability:, schema_digest:, approval_policy:, egress_policy_digest:,
            egress_policy_ref:, secret_handling:, request_budget:, output_budget:,
            retry_policy:, reconciliation_policy:
          ).validate!
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
      end
    end
  end
end
