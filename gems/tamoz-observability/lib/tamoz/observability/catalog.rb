# frozen_string_literal: true

module Tamoz
  module Observability
    # The seeded, closed registry (design §6.1, §8): every name an existing
    # accepted design has already published — the worker's request lifecycle,
    # the comms evidence events (COMMS_DESIGN §16), and the model/tool events
    # (M4_PLAN §13, minus TTFT, which a non-streaming model path cannot
    # measure). Producers emit names; this catalog is the contract.
    module Catalog
      MODEL_SPINE = %i[thread_id execution_id request_id task_id].freeze
      MODEL_EFFECT_SPINE = (MODEL_SPINE + %i[effect_key]).freeze
      PROVIDER = { provider: :low_cardinality, model: :low_cardinality }.freeze
      SURFACE = { surface: :low_cardinality }.freeze

      def self.fetch(name) = CATALOG.fetch(name)
      def self.registered?(name) = CATALOG.registered?(name)
      def self.names = CATALOG.names
      def self.entries = CATALOG.entries
      def self.validate_signal(signal) = CATALOG.validate_signal(signal)
      def self.safety_bearing?(name) = CATALOG.safety_bearing?(name)

      def self.seed(catalog)
        model_events(catalog)
        worker_events(catalog)
        comms_events(catalog)
      end

      def self.model_events(catalog)
        catalog.event(
          'tamoz.model.call', since: 1, stability: :stable, safety_bearing: false,
                              correlation: MODEL_SPINE,
                              required: PROVIDER.merge(outcome: :enum),
                              optional: {
                                duration_ms: :integer,
                                input_tokens: :integer, output_tokens: :integer,
                                cache_read_tokens: :integer, cache_write_tokens: :integer,
                                request_digest: :digest, response_digest: :digest,
                                cost_value: :string, cost_currency: :string, cost_basis: :enum,
                                pricing_source: :string, pricing_version: :string
                              },
                              content: %i[input_messages output_messages system_instructions]
        )
        catalog.event(
          'tamoz.tool.call', since: 1, stability: :stable, safety_bearing: false,
                             correlation: MODEL_EFFECT_SPINE,
                             required: { tool: :low_cardinality, outcome: :enum },
                             optional: { duration_ms: :integer, argument_digest: :digest, result_digest: :digest },
                             content: %i[tool_arguments tool_results]
        )
        %w[prepare start].each do |phase|
          catalog.event(
            "tamoz.agent.model.#{phase}", since: 1, stability: :stable, safety_bearing: false,
                                          correlation: MODEL_EFFECT_SPINE, required: PROVIDER,
                                          optional: { request_digest: :digest }
          )
        end
        catalog.event(
          'tamoz.agent.model.finish', since: 1, stability: :stable, safety_bearing: false,
                                      correlation: MODEL_EFFECT_SPINE, required: PROVIDER.merge(outcome: :enum),
                                      optional: { duration_ms: :integer, request_digest: :digest, response_digest: :digest }
        )
        catalog.event(
          'tamoz.agent.model.ambiguous', since: 1, stability: :stable, safety_bearing: true,
                                         correlation: MODEL_EFFECT_SPINE, required: PROVIDER,
                                         optional: { request_digest: :digest }
        )
        catalog.event(
          'tamoz.agent.tool.prepare', since: 1, stability: :stable, safety_bearing: false,
                                      correlation: MODEL_EFFECT_SPINE, required: { tool: :low_cardinality },
                                      optional: { argument_digest: :digest }
        )
        catalog.event(
          'tamoz.agent.tool.finish', since: 1, stability: :stable, safety_bearing: false,
                                     correlation: MODEL_EFFECT_SPINE, required: { tool: :low_cardinality, outcome: :enum },
                                     optional: { duration_ms: :integer, result_digest: :digest }
        )
        catalog.event(
          'tamoz.agent.compatibility.failure', since: 1, stability: :stable, safety_bearing: false,
                                               correlation: MODEL_SPINE, required: PROVIDER.merge(reason: :low_cardinality)
        )
      end
      private_class_method :model_events

      def self.worker_events(catalog)
        %w[started stopped error].each do |state|
          catalog.event(
            "tamoz.worker.#{state}", since: 1, stability: :stable, safety_bearing: false,
                                     correlation: [], required: {}, optional: { reason: :low_cardinality },
                                     content: state == 'error' ? [:error_detail] : []
          )
        end
        %w[completed failed blocked paused stopped approved denied claimed recovered].each do |state|
          catalog.event(
            "tamoz.worker.request.#{state}", since: 1, stability: :stable, safety_bearing: false,
                                             correlation: %i[thread_id occurrence_id],
                                             required: {},
                                             optional: {
                                               duration_ms: :integer, reason: :low_cardinality,
                                               execution_id: :string, status: :low_cardinality
                                             }
          )
        end
        catalog.event(
          'tamoz.worker.schedule.materialized', since: 1, stability: :stable, safety_bearing: false,
                                                correlation: [], required: {},
                                                optional: { schedule_id: :string, occurrence_id: :string, request_id: :string }
        )
        catalog.event(
          'tamoz.worker.schedule.error', since: 1, stability: :stable, safety_bearing: false,
                                         correlation: [], required: {}, optional: { reason: :low_cardinality }
        )
      end
      private_class_method :worker_events

      def self.comms_events(catalog)
        catalog.event('comms.started', since: 1, stability: :stable, safety_bearing: false,
                                       correlation: [], required: SURFACE)
        catalog.event('comms.authenticated', since: 1, stability: :stable, safety_bearing: false,
                                             correlation: [], required: SURFACE)
        catalog.event('comms.stopped', since: 1, stability: :stable, safety_bearing: false,
                                       correlation: [], required: SURFACE, optional: { reason: :low_cardinality })
        catalog.event('comms.offset.persisted', since: 1, stability: :stable, safety_bearing: false,
                                                correlation: [], required: SURFACE)
        %w[admitted duplicate].each do |disposition|
          catalog.event("comms.inbound.#{disposition}", since: 1, stability: :stable,
                                                        safety_bearing: false, correlation: [], required: SURFACE)
        end
        %w[rejected quarantined].each do |disposition|
          catalog.event("comms.inbound.#{disposition}", since: 1, stability: :stable,
                                                        safety_bearing: true, correlation: [],
                                                        required: SURFACE.merge(reason: :low_cardinality))
        end
        catalog.event('comms.request.enqueued', since: 1, stability: :stable, safety_bearing: false,
                                                correlation: %i[request_id], required: SURFACE)
        catalog.event('comms.decision.recorded', since: 1, stability: :stable, safety_bearing: false,
                                                 correlation: %i[thread_id occurrence_id], required: SURFACE.merge(direction: :enum))
        catalog.event('comms.decision.refused', since: 1, stability: :stable, safety_bearing: true,
                                                correlation: %i[thread_id occurrence_id],
                                                required: SURFACE.merge(reason: :low_cardinality))
        %w[sent throttled failed unknown coalesced dropped].each do |disposition|
          catalog.event("comms.delivery.#{disposition}", since: 1, stability: :stable,
                                                         safety_bearing: disposition == 'unknown', correlation: %i[occurrence_id],
                                                         required: SURFACE, optional: { reason: :low_cardinality })
        end
      end

      def self.metric_catalog(catalog)
        metrics = {
          'tamoz.inbox.depth' => %i[status],
          'tamoz.occurrence.oldest_age_ms' => %i[status],
          'tamoz.effect.blocked' => %i[operation],
          'tamoz.effect.unknown' => %i[operation],
          'tamoz.approval.pending' => [],
          'tamoz.lease.held' => [],
          'tamoz.budget.exhaustions' => %i[budget],
          'tamoz.thread.tombstoned' => [],
          'tamoz.turn.duration_ms' => %i[outcome profile surface],
          'tamoz.plan.attempts' => %i[kind outcome],
          'tamoz.review.rejected' => %i[reason_class],
          'tamoz.approval.wait_ms' => %i[outcome],
          'tamoz.model.call.duration_ms' => %i[provider model outcome],
          'tamoz.model.tokens' => %i[provider model kind],
          'tamoz.model.cache.epoch_changed' => %i[reason],
          'tamoz.tool.call.duration_ms' => %i[tool source outcome],
          'tamoz.tool.denied' => %i[tool source reason_class],
          'tamoz.effect.attempts' => %i[operation safety outcome],
          'tamoz.store.commit_ms' => %i[namespace_kind],
          'tamoz.store.busy_retries' => [],
          'tamoz.lease.wait_ms' => [],
          'tamoz.lease.lost' => [],
          'tamoz.verify.outcome' => %i[result],
          'tamoz.repair.attempts' => %i[outcome],
          'tamoz.stop.safe' => %i[reason_class],
          'tamoz.telemetry.dropped' => %i[signal reason lane],
          'tamoz.telemetry.divergence' => %i[reason_class],
          'tamoz.telemetry.export' => %i[outcome]
        }
        metrics.each do |name, labels|
          catalog.measurement(name, since: 1, stability: :stable, labels:)
        end
      end
      private_class_method :comms_events

      CATALOG = SignalCatalog.new.tap do |catalog|
        seed(catalog)
        metric_catalog(catalog)
      end.freeze
    end
  end
end
