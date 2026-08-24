# frozen_string_literal: true

# Thread execution machinery: the bounded pool, the single-consumer stream
# sink, the graph event stream, and the join helper. Consumes cancellation;
# the error hierarchy (PoolCircuitOpenError, PoolWorkerError,
# StreamClosedError, StateLimitError) stays in tamoz-core so every consumer
# keeps sharing it.
require "tamoz/core"
require "tamoz/cancellation"

require_relative "concurrency/version"
require_relative "pool"
require_relative "stream_sink"
require_relative "concurrency/event_stream"
require_relative "concurrency/drain"

module Tamoz
  module Concurrency
    module_function

    # Joins every thread within ONE shared monotonic budget: once the budget
    # is spent, remaining threads are left unjoined (their survival is visible
    # via Thread#alive?).
    def join_all(threads, deadline:)
      finish = Clock.monotonic.now + deadline
      threads.each do |thread|
        remaining = finish - Clock.monotonic.now
        break unless remaining.positive?

        thread.join(remaining)
      end
      nil
    end
  end
end
