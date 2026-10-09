# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/talk/version'

TamozGemspec.build(
  name: 'tamoz-talk',
  version: Tamoz::Talk::VERSION,
  summary: 'Browser talk transport for Tamoz',
  description: 'A browser voice and text channel implementing the Tamoz::Comms::Transport seam: a hardened ' \
               'stdlib HTTP server, an in-memory inbox with confirm-by-next-poll, and the talk page.',
  dependencies: [
    ['tamoz-comms', "= #{Tamoz::Talk::VERSION}"],
    ['tamoz-core', "= #{Tamoz::Talk::VERSION}"]
  ],
  runtime_contracts: ['assets/*']
)
