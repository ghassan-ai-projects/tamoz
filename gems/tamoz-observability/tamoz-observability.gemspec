# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/observability/version'

# The helper sets `required_ruby_version` (gemspec_helper.rb line 21); the
# static cop cannot see through it, so this gemspec joins the same
# Gemspec/RequiredRubyVersion exclusion every other gem uses.
TamozGemspec.build(
  name: 'tamoz-observability',
  version: Tamoz::Observability::VERSION,
  summary: 'The observability signal plane for Tamoz',
  description: 'The closed, versioned signal catalog, derived correlation ' \
               'identity, immutable signals, bounded recorders, local journal, ' \
               'content policy, metrics and trace projection.',
  dependencies: [
    ['tamoz-core', "= #{Tamoz::Observability::VERSION}"]
  ]
)
