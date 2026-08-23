# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/agent/improvement/version'

TamozGemspec.build(
  name: 'tamoz-agent-improvement',
  version: Tamoz::Agent::Improvement::VERSION,
  summary: 'Bounded self-improvement for Tamoz agents',
  description: 'The self-improvement vertical for Tamoz agents: candidate ' \
               'provenance, the bounded heuristic generator, paired baseline/' \
               'holdout evaluation reports, the human-gated candidate lifecycle, ' \
               'and promotion/rollback over the memory behavior-transition seam.',
  dependencies: [
    ['tamoz-agent-kernel', "= #{Tamoz::Agent::Improvement::VERSION}"],
    ['tamoz-agent-memory', "= #{Tamoz::Agent::Improvement::VERSION}"]
  ]
)
