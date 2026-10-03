# frozen_string_literal: true

module Tamoz
  module Observability
    module Catalog
      # The model and tool call events producers emit around every model request and tool dispatch.
      module ModelSignals
        SPINE = %i[thread_id execution_id request_id task_id].freeze
        EFFECT_SPINE = (SPINE + %i[effect_key]).freeze
        PROVIDER = { provider: :low_cardinality, model: :low_cardinality }.freeze
        MODEL_CALL_OPTIONAL = {
          duration_ms: :integer,
          input_tokens: :integer, output_tokens: :integer,
          cache_read_tokens: :integer, cache_write_tokens: :integer,
          request_digest: :digest, response_digest: :digest,
          cost_value: :string, cost_currency: :string, cost_basis: :enum,
          pricing_source: :string, pricing_version: :string
        }.freeze

        module_function

        def seed(catalog)
          call_events(catalog)
          agent_model_events(catalog)
          agent_tool_events(catalog)
          catalog.event('tamoz.agent.compatibility.failure', since: 1, stability: :stable, safety_bearing: false,
                                                             correlation: SPINE,
                                                             required: PROVIDER.merge(reason: :low_cardinality))
        end

        def call_events(catalog)
          catalog.event('tamoz.model.call', since: 1, stability: :stable, safety_bearing: false,
                                            correlation: SPINE, required: PROVIDER.merge(outcome: :enum),
                                            optional: MODEL_CALL_OPTIONAL,
                                            content: %i[input_messages output_messages system_instructions])
          catalog.event('tamoz.tool.call', since: 1, stability: :stable, safety_bearing: false,
                                           correlation: EFFECT_SPINE,
                                           required: { tool: :low_cardinality, outcome: :enum },
                                           optional: { duration_ms: :integer, argument_digest: :digest,
                                                       result_digest: :digest },
                                           content: %i[tool_arguments tool_results])
        end

        def agent_model_events(catalog)
          %w[prepare start].each do |phase|
            agent_model_event(catalog, phase, required: PROVIDER, optional: { request_digest: :digest })
          end
          agent_model_event(catalog, 'finish', required: PROVIDER.merge(outcome: :enum),
                                               optional: { duration_ms: :integer, request_digest: :digest,
                                                           response_digest: :digest })
          agent_model_event(catalog, 'ambiguous', required: PROVIDER, optional: { request_digest: :digest },
                                                  safety_bearing: true)
        end

        def agent_model_event(catalog, phase, required:, optional:, safety_bearing: false)
          catalog.event("tamoz.agent.model.#{phase}", since: 1, stability: :stable, safety_bearing:,
                                                      correlation: EFFECT_SPINE, required:, optional:)
        end

        def agent_tool_events(catalog)
          catalog.event('tamoz.agent.tool.prepare', since: 1, stability: :stable, safety_bearing: false,
                                                    correlation: EFFECT_SPINE, required: { tool: :low_cardinality },
                                                    optional: { argument_digest: :digest })
          catalog.event('tamoz.agent.tool.finish', since: 1, stability: :stable, safety_bearing: false,
                                                   correlation: EFFECT_SPINE,
                                                   required: { tool: :low_cardinality, outcome: :enum },
                                                   optional: { duration_ms: :integer, result_digest: :digest })
        end
      end
    end
  end
end
