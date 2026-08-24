# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/concurrency/version"

TamozGemspec.build(
  name: "tamoz-concurrency",
  version: Tamoz::Concurrency::VERSION,
  summary: "Thread execution machinery for Tamoz",
  description: "The bounded thread/inline pool with its stuck-worker circuit, " \
               "the single-consumer stream sink, the graph event stream, join " \
               "helpers, and the bounded drain skeleton.",
  dependencies: [
    ["tamoz-cancellation", "= #{Tamoz::Concurrency::VERSION}"],
    ["tamoz-core", "= #{Tamoz::Concurrency::VERSION}"]
  ]
)
