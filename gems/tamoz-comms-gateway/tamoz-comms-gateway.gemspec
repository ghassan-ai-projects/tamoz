# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative '../tamoz-comms/lib/tamoz/comms/version'
require_relative '../tamoz-core/lib/tamoz/core/version'

# The helper sets `required_ruby_version` (gemspec_helper.rb line 21); the
# static cop cannot see through it, so this gemspec joins the same
# Gemspec/RequiredRubyVersion exclusion every other gem uses.
TamozGemspec.build(
  name: 'tamoz-comms-gateway',
  version: Tamoz::Comms::VERSION,
  summary: 'Tamoz communications gateway process boundary',
  description: 'The long-running communications gateway and delivery drainer ' \
               'over the injected Tamoz::Comms transport and store contracts.',
  dependencies: [
    ['tamoz-comms', "= #{Tamoz::Comms::VERSION}"],
    ['tamoz-core', "= #{Tamoz::Core::VERSION}"]
  ]
)
