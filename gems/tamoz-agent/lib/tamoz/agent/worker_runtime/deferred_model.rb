# frozen_string_literal: true

module Tamoz
  module Agent
    class WorkerRuntime
      # A model that is not built until something actually asks it to generate.
      #
      # `tamoz status` and `tamoz queue list` read durable state and never call a
      # model. Constructing sessions eagerly would make them fail on a machine
      # with no provider configured, which is exactly the machine an operator is
      # most likely to be debugging on. Deferring construction keeps inspection
      # working without giving the inspection path a second, weaker code path of
      # its own.
      class DeferredModel
        def initialize(&build)
          @build = build
          @monitor = Mutex.new
        end

        def generate(...)
          model.generate(...)
        end

        def after_effect_started(operation:)
          model.after_effect_started(operation:) if model.respond_to?(:after_effect_started)
        end

        private

        def model
          @monitor.synchronize { @model ||= @build.call }
        end
      end
    end
  end
end
