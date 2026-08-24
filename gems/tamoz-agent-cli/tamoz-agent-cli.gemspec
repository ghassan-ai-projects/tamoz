# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/agent/cli/version'

TamozGemspec.build(
  name: 'tamoz-agent-cli',
  version: Tamoz::Agent::CLI::VERSION,
  summary: 'Command line for Tamoz agents',
  description: 'The tamoz executable: argument parsing, rendering, and the ' \
               'worker/schedule/profile/session/comms command groups over the ' \
               'tamoz-agent runtime.',
  dependencies: [
    ['tamoz-agent', "= #{Tamoz::Agent::CLI::VERSION}"],
    ['tamoz-agent-capabilities', "= #{Tamoz::Agent::CLI::VERSION}"],
    ['tamoz-agent-session', "= #{Tamoz::Agent::CLI::VERSION}"]
  ],
  executable: 'tamoz'
)
