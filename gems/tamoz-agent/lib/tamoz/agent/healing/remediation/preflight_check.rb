# frozen_string_literal: true

module Tamoz
  module Agent
    module Healing
      module Remediation
        # Binds one classification to the design §5 preflight context without
        # letting caller-supplied context replace the authoritative attempt data.
        class PreflightCheck
          def initialize(record:, rule:, attempt:, context:)
            @record = record
            @rule = rule
            @attempt = attempt
            @context = context
          end

          def call(classification)
            attributes = {
              record: @record, rule: @rule, classification:, attempt: @attempt,
              requested_form: classification.action_family
            }.merge(@context)
            Preflight.run(Preflight::Context.new(**attributes))
          end
        end
      end
    end
  end
end
