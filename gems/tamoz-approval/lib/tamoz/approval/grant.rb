# frozen_string_literal: true

require 'json'
require 'tamoz/core'

module Tamoz
  module Approval
    Grant = Data.define(
      :key,
      :scope,
      :session_id,
      :policy_rev,
      :created_at_ms,
      :expires_at_ms
    ) do
      # The one durable text encoding for a grant key: core-canonical (keys
      # sorted and stringified, recursed) so a stored row and its later
      # lookup serialize to identical bytes regardless of field order.
      def self.key_text(key)
        JSON.generate(Tamoz::Core.canonical(key))
      end
    end

    # Millisecond values are epoch milliseconds from the Engine's injected
    # wall clock; `expires_at_ms` is filtered by the Engine, so stores treat
    # it as an opaque field.
  end
end
