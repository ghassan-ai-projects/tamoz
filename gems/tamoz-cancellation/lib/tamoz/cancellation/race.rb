# frozen_string_literal: true

module Tamoz
  # Waits that end the moment a token cancels.
  module Cancellation
    module_function

    # The block's value, or CancelledError the moment the token cancels. The block runs on its
    # own thread; once abandoned it finishes on its own and its result is dropped.
    def race(token)
      outcome = Queue.new
      runner = Thread.new do
        outcome << [:value, yield]
      rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised on the caller's thread
        outcome << [:error, e]
      end
      runner.report_on_exception = false
      subscription = token.on_cancel { |reason| outcome << [:cancelled, reason] }
      kind, value = outcome.pop
      raise value if kind == :error
      raise CancelledError, "cancelled: #{value}" if kind == :cancelled

      value
    ensure
      subscription&.unsubscribe
    end
  end
end
