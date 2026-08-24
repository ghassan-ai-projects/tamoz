# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/otel/version'

TamozGemspec.build(
  name: 'tamoz-otel',
  version: Tamoz::OTel::VERSION,
  summary: 'Bounded OTLP/HTTP export for Tamoz observability',
  description: 'A dependency-light, governed OTLP/HTTP exporter for Tamoz signals.',
  dependencies: [
    ['tamoz-concurrency', "= #{Tamoz::OTel::VERSION}"],
    ['tamoz-observability', "= #{Tamoz::OTel::VERSION}"]
  ]
)
