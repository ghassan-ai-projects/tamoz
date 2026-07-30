# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/core/version"

TamozGemspec.build(
  name: "tamoz-core",
  version: Tamoz::Core::VERSION,
  summary: "Shared runtime contracts for Tamoz",
  description: "Immutable values and dependency-light protocols shared by Tamoz packages.",
  dependencies: [["zeitwerk", "~> 2.6"]]
)
