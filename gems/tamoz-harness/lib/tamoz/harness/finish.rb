# frozen_string_literal: true

module Tamoz
  module Harness
    # How a work turn that stopped calling tools is reported.
    module Finish
      module_function

      def status(mutated:, verified_after_last_mutation:)
        return 'answered' unless mutated

        verified_after_last_mutation ? 'done' : 'done_unverified'
      end
    end
  end
end
