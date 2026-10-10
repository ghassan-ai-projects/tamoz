# frozen_string_literal: true

module Tamoz
  module Comms
    # The durable resume an admitted clarification answer enqueues on its paused thread.
    Resume = Data.define(:thread, :request_id, :payload) do
      def wire = to_h.transform_keys(&:to_s)
    end
  end
end
