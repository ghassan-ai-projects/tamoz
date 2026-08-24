# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/cancellation/version"

TamozGemspec.build(
  name: "tamoz-cancellation",
  version: Tamoz::Cancellation::VERSION,
  summary: "Cancellation signals for Tamoz",
  description: "How work is told to stop: the cancellation token, trap-safe " \
               "INT/TERM installation, interruptible sleep, and process-group " \
               "teardown ladders. Depends on tamoz-core only.",
  dependencies: [
    ["tamoz-core", "= #{Tamoz::Cancellation::VERSION}"]
  ]
)
