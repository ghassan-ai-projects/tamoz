# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/approval/version'

TamozGemspec.build(
  name: 'tamoz-approval',
  version: Tamoz::Approval::VERSION,
  summary: 'Approval and permission policy for Tamoz',
  description: 'Single policy owner for tool-call approval decisions: ' \
               'immutable request/decision/grant values, a policy-as-data ' \
               'engine, and digest-pinned YAML policy documents.',
  dependencies: [
    ['tamoz-core', "= #{Tamoz::Approval::VERSION}"]
  ],
  runtime_contracts: ['policy/**/*.yaml']
)
