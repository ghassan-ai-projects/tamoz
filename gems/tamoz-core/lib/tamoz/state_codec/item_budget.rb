# frozen_string_literal: true

module Tamoz
  class StateCodec
    # The total-items ceiling one encode or load may spend.
    class ItemBudget
      def initialize(maximum, error_class)
        @maximum = maximum
        @error_class = error_class
        @items = 0
      end

      def spend!(count, path:)
        @items += count
        return if @items <= @maximum

        raise @error_class, "#{path}: collections exceed #{@maximum} total items"
      end
    end
  end
end
