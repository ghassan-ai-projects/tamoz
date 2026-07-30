# frozen_string_literal: true

module Tamoz
  module Clock
    class Monotonic
      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      INSTANCE = new.freeze
    end

    module_function

    def monotonic
      Monotonic::INSTANCE
    end

    private_constant :Monotonic
  end
end
