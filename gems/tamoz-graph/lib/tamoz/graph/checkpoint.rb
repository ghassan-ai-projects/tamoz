# frozen_string_literal: true

module Tamoz
  module Graph
    Checkpoint = Data.define(
      :format_version,
      :id,
      :sequence,
      :thread_id,
      :namespace,
      :execution_id,
      :parent_id,
      :graph_name,
      :graph_version,
      :definition_digest,
      :status,
      :logical_step,
      :state,
      :state_bytes,
      :frontier,
      :pending,
      :interrupts,
      :resume_values,
      :attempts,
      :failure,
      :total_tasks
    )
  end
end
