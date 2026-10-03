# frozen_string_literal: true

module Tamoz
  module Observability
    module Catalog
      # The communication gateway's evidence events.
      module CommsSignals
        SURFACE = { surface: :low_cardinality }.freeze
        REASONED = SURFACE.merge(reason: :low_cardinality).freeze
        DELIVERY_DISPOSITIONS = %w[sent throttled failed unknown coalesced dropped].freeze
        EVENT_DEFAULTS = { safety_bearing: false, correlation: [], required: SURFACE }.freeze

        module_function

        def seed(catalog)
          lifecycle_events(catalog)
          inbound_events(catalog)
          decision_events(catalog)
          delivery_events(catalog)
        end

        def lifecycle_events(catalog)
          event(catalog, 'comms.started')
          event(catalog, 'comms.authenticated')
          event(catalog, 'comms.stopped', optional: { reason: :low_cardinality })
          event(catalog, 'comms.offset.persisted')
        end

        def inbound_events(catalog)
          %w[admitted duplicate].each { |disposition| event(catalog, "comms.inbound.#{disposition}") }
          %w[rejected quarantined].each do |disposition|
            event(catalog, "comms.inbound.#{disposition}", safety_bearing: true, required: REASONED)
          end
        end

        def decision_events(catalog)
          event(catalog, 'comms.request.enqueued', correlation: %i[request_id])
          event(catalog, 'comms.decision.recorded', correlation: %i[thread_id occurrence_id],
                                                    required: SURFACE.merge(direction: :enum))
          event(catalog, 'comms.decision.refused', safety_bearing: true, correlation: %i[thread_id occurrence_id],
                                                   required: REASONED)
        end

        def delivery_events(catalog)
          DELIVERY_DISPOSITIONS.each do |disposition|
            event(catalog, "comms.delivery.#{disposition}", safety_bearing: disposition == 'unknown',
                                                            correlation: %i[occurrence_id],
                                                            optional: { reason: :low_cardinality })
          end
        end

        def event(catalog, name, **attributes)
          catalog.event(name, since: 1, stability: :stable, **EVENT_DEFAULTS, **attributes)
        end
      end
    end
  end
end
