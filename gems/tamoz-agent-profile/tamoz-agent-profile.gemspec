# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/agent/profile/version'

TamozGemspec.build(
  name: 'tamoz-agent-profile',
  version: Tamoz::Agent::Profile::VERSION,
  summary: 'Trusted profiles for Tamoz agents',
  description: 'Operator-side trusted-profile validation and registries: ' \
               'document, authority, egress, and check-spec validators; ' \
               'secure file handling; and the adoption/transition registries.',
  dependencies: [
    ['tamoz-agent-kernel', "= #{Tamoz::Agent::Profile::VERSION}"],
    ['tamoz-core', "= #{Tamoz::Agent::Profile::VERSION}"]
  ]
)
