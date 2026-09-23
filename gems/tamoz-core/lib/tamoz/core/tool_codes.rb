# frozen_string_literal: true

module Tamoz
  module Core
    # The stable refusal codes the work route puts in front of the planner. The code is the
    # contract — a test pins it and the planner is told what to do next in the same sentence —
    # so neither ever changes once shipped.
    module ToolCodes
      NOT_OBSERVED = 'not_observed'
      STALE_FILE = 'stale_file'

      module_function

      def render(code, sentence) = "Error [#{code}]: #{sentence}"
    end
  end
end
