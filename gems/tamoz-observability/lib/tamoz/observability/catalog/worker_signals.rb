# frozen_string_literal: true

module Tamoz
  module Observability
    module Catalog
      # The worker's lifecycle, request and schedule events.
      module WorkerSignals
        REQUEST_STATES = %w[completed failed blocked paused stopped approved denied claimed recovered].freeze
        REQUEST_OPTIONAL = {
          duration_ms: :integer, reason: :low_cardinality, execution_id: :string, status: :low_cardinality
        }.freeze

        module_function

        def seed(catalog)
          lifecycle_events(catalog)
          request_events(catalog)
          schedule_events(catalog)
        end

        def lifecycle_events(catalog)
          %w[started stopped error].each do |state|
            catalog.event("tamoz.worker.#{state}", since: 1, stability: :stable, safety_bearing: false,
                                                   correlation: [], required: {},
                                                   optional: { reason: :low_cardinality },
                                                   content: state == 'error' ? [:error_detail] : [])
          end
        end

        def request_events(catalog)
          REQUEST_STATES.each do |state|
            catalog.event("tamoz.worker.request.#{state}", since: 1, stability: :stable, safety_bearing: false,
                                                           correlation: %i[thread_id occurrence_id],
                                                           required: {}, optional: REQUEST_OPTIONAL)
          end
        end

        def schedule_events(catalog)
          catalog.event('tamoz.worker.schedule.materialized',
                        since: 1, stability: :stable, safety_bearing: false, correlation: [], required: {},
                        optional: { schedule_id: :string, occurrence_id: :string, request_id: :string })
          catalog.event('tamoz.worker.schedule.error', since: 1, stability: :stable, safety_bearing: false,
                                                       correlation: [], required: {},
                                                       optional: { reason: :low_cardinality })
        end
      end
    end
  end
end
