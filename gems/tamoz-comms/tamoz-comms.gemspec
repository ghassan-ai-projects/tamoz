# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/comms/version'

# The helper sets `required_ruby_version` (gemspec_helper.rb line 21); the
# static cop cannot see through it, so this gemspec joins the same
# Gemspec/RequiredRubyVersion exclusion every other gem uses.
TamozGemspec.build(
  name: 'tamoz-comms',
  version: Tamoz::Comms::VERSION,
  summary: 'Communication channels for Tamoz',
  description: 'Channel values, identity/admission policy, rendering, ' \
               'the Transport seam and the structural CommsStore contract; ' \
               'transports ship as separate adapter gems.',
  dependencies: [
    ['tamoz-core', "= #{Tamoz::Comms::VERSION}"]
  ]
)
