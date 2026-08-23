# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/agent/healing/version'

TamozGemspec.build(
  name: 'tamoz-agent-healing',
  version: Tamoz::Agent::Healing::VERSION,
  summary: 'Bounded self-healing for Tamoz agents',
  description: 'The P12 self-healing vertical: the typed failure model, ' \
               'classification and abstention, immutable healing rules with ' \
               'digest-bound rule sets, preflight conditions, the configured-' \
               'check oracle, the promotion gate, durable failure records, and ' \
               'the reviewed remediation protocol over the effect dispatcher.',
  dependencies: [
    ['tamoz-agent-kernel', "= #{Tamoz::Agent::Healing::VERSION}"],
    ['tamoz-tools', "= #{Tamoz::Agent::Healing::VERSION}"],
    ['tamoz-core', "= #{Tamoz::Agent::Healing::VERSION}"]
  ]
)
