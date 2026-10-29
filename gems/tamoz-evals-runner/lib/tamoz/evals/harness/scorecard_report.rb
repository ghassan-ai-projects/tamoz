# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      # A scorecard's frozen, canonically serialized report document.
      ScorecardReport = Data.define(:document) do
        def initialize(document:)
          super(document: DeepFreeze.call(document))
        end

        def passed? = document.fetch('decision') == 'pass'
        def to_h = document
        def to_json(*_args) = CanonicalJSON.dump(document)
      end
    end
  end
end
