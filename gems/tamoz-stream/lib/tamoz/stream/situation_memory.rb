# frozen_string_literal: true

require "tamoz/stream/situation_recall"

module Tamoz
  module Stream
    # Public naming for the recall boundary. Storage-shaped repository rows
    # deliberately cannot be passed here; callers provide an injected port.
    module SituationMemory
      module_function

      def retrieve(recaller:, caller:, snapshot:, query: {terms: []}, limit: 20)
        SituationRecall.validate!(
          recaller.recall(caller:, snapshot:, query:, limit:)
        )
      end

      def related(recaller:, caller:, snapshot:, query: {terms: []}, limit: 20)
        retrieve(recaller:, caller:, snapshot:, query:, limit:)
      end
    end
  end
end
