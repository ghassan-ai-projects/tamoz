# frozen_string_literal: true

module Tamoz
  module Approval
    Grant = Data.define(
      :key,
      :scope,
      :session_id,
      :policy_rev,
      :created_at_ms,
      :expires_at_ms
    )
  end
end
