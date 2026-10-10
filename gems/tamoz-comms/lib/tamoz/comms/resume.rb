# frozen_string_literal: true

module Tamoz
  module Comms
    # The durable resume an admitted clarification answer enqueues on its paused thread.
    Resume = Data.define(:thread, :request_id, :payload)
  end
end
