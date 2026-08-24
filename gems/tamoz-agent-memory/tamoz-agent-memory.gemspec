# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/agent/memory/version'

TamozGemspec.build(
  name: 'tamoz-agent-memory',
  version: Tamoz::Agent::Memory::VERSION,
  summary: 'Durable memory for Tamoz agents',
  description: 'The memory vertical for Tamoz agents: Memory::Engine and its ' \
               'sub-services (admission, retrieval, consolidation, lifecycle, ' \
               'behavior transitions, wisdom), MemoryRecord and ' \
               'VerifiedOutcomeReference values, and the memory error family, ' \
               'assembled over the SQLite-backed memory store.',
  dependencies: [
    ['tamoz-agent-kernel', "= #{Tamoz::Agent::Memory::VERSION}"],
    ['tamoz-core', "= #{Tamoz::Agent::Memory::VERSION}"],
    ['tamoz-sqlite', "= #{Tamoz::Agent::Memory::VERSION}"],
    ['tamoz-tools', "= #{Tamoz::Agent::Memory::VERSION}"]
  ]
)
