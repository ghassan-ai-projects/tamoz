# frozen_string_literal: true

module Tamoz
  module Harness
    # The note a stopped turn leaves for the next generation.
    module Handoff
      module_function

      def note(plan:, reason:, task:)
        format(PromptPack.fetch('handoff'), reason:, task:, plan: plan ? plan.render : PromptPack.fetch('no_plan'))
      end
    end
  end
end
