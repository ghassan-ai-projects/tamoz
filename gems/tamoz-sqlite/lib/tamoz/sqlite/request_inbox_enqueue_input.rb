# frozen_string_literal: true

module Tamoz
  module SQLite
    # :nodoc: Immutable values prepared before an enqueue transaction begins.
    RequestInboxEnqueueInput = Data.define(
      :thread,
      :encoded_namespace,
      :id,
      :operation_text,
      :delivery_text,
      :payload_bytes,
      :payload_digest,
      :input_digest
    )
  end
end
