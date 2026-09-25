# frozen_string_literal: true

# How work is told to stop: the cancellation token, trap-safe INT/TERM
# installation, interruptible sleep, and process-group teardown. Depends on
# tamoz-core only (Clock, SafeText, the error hierarchy); it spawns no pools
# and joins no threads of its own.
require "tamoz/core"

require_relative "cancellation/version"
require_relative "cancellation_token"
require_relative "cancellation/trap"
require_relative "cancellation/sleep"
require_relative "cancellation/race"
require_relative "cancellation/stops"
require_relative "cancellation/process_group"

module Tamoz
  module Cancellation
  end
end
