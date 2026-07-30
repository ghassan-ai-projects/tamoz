# frozen_string_literal: true

module Tamoz
  module Graph
    Snapshot = Data.define(
      :checkpoint_id,
      :parent_checkpoint_id,
      :sequence,
      :thread_id,
      :namespace,
      :execution_id,
      :status,
      :logical_step,
      :state,
      :next,
      :pending_task_ids,
      :interrupts,
      :failure,
      :definition_digest
    )
  end
end
