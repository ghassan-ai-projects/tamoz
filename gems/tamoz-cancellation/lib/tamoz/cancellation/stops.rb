# frozen_string_literal: true

module Tamoz
  module Cancellation
    # The user's stop for a thread's running turn: the worker registers it, the turn's own steps read it.
    # It is kept out of the graph context on purpose, so the graph engine never aborts a step half-done.
    module Stops
      @tokens = {}
      @lock = Mutex.new

      class << self
        def during(thread_id, token)
          @lock.synchronize { @tokens[thread_id] = token }
          yield
        ensure
          @lock.synchronize { @tokens.delete(thread_id) if @tokens[thread_id].equal?(token) }
        end

        def token(thread_id) = @lock.synchronize { @tokens[thread_id] }

        def requested?(thread_id) = token(thread_id)&.cancelled? || false
      end
    end
  end
end
