# frozen_string_literal: true

module Tamoz
  module Stream
    # The worker's ceilings on a requested budget: a hostile budget cannot lift them.
    module BudgetLimits
      MAX_WALL_TIME_SECONDS = 600
      MAX_MODEL_CALLS = 50

      module_function

      def positive_int_or_nil(value)
        int = value.to_i
        int.positive? ? int : nil
      end
    end
  end
end
