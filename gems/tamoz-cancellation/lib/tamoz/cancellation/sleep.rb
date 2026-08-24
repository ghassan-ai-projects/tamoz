# frozen_string_literal: true

module Tamoz
  module Cancellation
    module_function

    # Sleep until the deadline but wake the instant the token cancels —
    # `CancellationToken#wait(timeout:)` is exactly that primitive. Returns
    # true when the sleep ended in cancellation, false when it expired.
    def interruptible_sleep(seconds, token:)
      token.wait(timeout: seconds)
    end
  end
end
