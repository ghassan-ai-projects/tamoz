# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      # DR-3 retrieval layer (C1). One instance per cell, configured by the
      # treatment's `memory_epoch`. The decision is deterministic: which PUBLIC
      # records in the treatment's visible epochs matched the turn's prompt.
      # RESTRICTED records are never injectable in any treatment; the scan still
      # matches them and surfaces them as `matched_restricted_ids` so the report
      # can prove the hard-zero property is non-vacuous (C8).
      class MemoryRetrieval
        VISIBLE_EPOCHS = {
          "none" => [],
          "experience" => %w[experience],
          "knowledge" => %w[experience knowledge],
          "wisdom" => %w[experience knowledge wisdom]
        }.freeze
        RESTRICTED = "restricted"

        Recall = Data.define(:injected_ids, :matched_restricted_ids) do
          def initialize(injected_ids: [], matched_restricted_ids: [])
            super(
              injected_ids: DeepFreeze.call(injected_ids),
              matched_restricted_ids: DeepFreeze.call(matched_restricted_ids)
            )
          end
        end

        attr_reader :epoch

        def initialize(config)
          @epoch = config.fetch("epoch", "none")
          @visible = VISIBLE_EPOCHS.fetch(@epoch) do
            raise ExecutionError, "unknown memory epoch #{@epoch.inspect}"
          end
        end

        def recall(store:, query:)
          scan = store.scan(query)
          injected = scan.fetch("matched_ids").select do |memory_id|
            metadata = store.metadata(memory_id)
            @visible.include?(metadata.fetch("epoch")) &&
              metadata.fetch("classification") != RESTRICTED
          end
          Recall.new(
            injected_ids: injected,
            matched_restricted_ids: scan.fetch("matched_restricted_ids")
          )
        end
      end
    end
  end
end
