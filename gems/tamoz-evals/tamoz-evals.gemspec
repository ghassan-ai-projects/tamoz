# frozen_string_literal: true

require_relative "../gemspec_helper"
require_relative "lib/tamoz/evals/version"

TamozGemspec.build(
  name: "tamoz-evals",
  version: Tamoz::Evals::VERSION,
  summary: "Evaluation and release evidence for Tamoz",
  description: "Canonical artifacts, conformance suites, comparison, and release gates.",
  executable: "tamoz-eval"
)
