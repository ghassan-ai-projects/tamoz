# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/agent/kernel/version'

TamozGemspec.build(
  name: 'tamoz-agent-kernel',
  version: Tamoz::Agent::Kernel::VERSION,
  summary: 'Deliberation substrate for Tamoz agents',
  description: 'The record, receipt, and effect primitives every Tamoz agent ' \
               'is built from: episode values and receipts, the plan/review/' \
               'execute/verify engine, the effect dispatcher, witness ' \
               'gateway/verifier, catalogs, and the error taxonomy.',
  dependencies: [
    ['tamoz-core', "= #{Tamoz::Agent::Kernel::VERSION}"],
    ['tamoz-tools', "= #{Tamoz::Agent::Kernel::VERSION}"],
    ['net-http', '>= 0.5']
  ]
)
