# frozen_string_literal: true

module Tamoz
  module SQLite
    # What a claim writes onto a request: the status it takes, the execution it
    # binds to, and — for a redirect — the execution it cancels.
    RequestClaimBinding = Data.define(
      :status, :execution_id, :target_execution_id, :cancellation_generation
    )
  end
end
