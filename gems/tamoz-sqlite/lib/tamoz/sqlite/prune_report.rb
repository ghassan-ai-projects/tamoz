# frozen_string_literal: true

module Tamoz
  module SQLite
    PruneReport = Data.define(
      :thread_id,
      :namespace,
      :kept_minimum,
      :deleted_checkpoint_ids,
      :created_at_ms
    ) do
      def deleted_count = deleted_checkpoint_ids.length
    end
  end
end
