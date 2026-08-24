# frozen_string_literal: true

module Tamoz
  module Agent
    # Drivers own the bundled approval default: tamoz-agent overrides
    # default_engine with its implement-profile factory. A bare consumer of
    # this gem fails loudly here instead of ever skipping gating.
    module SessionApprovalWiring
      module_function

      def default_engine
        raise NotImplementedError,
              'no approval engine wired: supply approval_engine or override ' \
              "#{name}.default_engine in the driver gem"
      end
    end
  end
end
