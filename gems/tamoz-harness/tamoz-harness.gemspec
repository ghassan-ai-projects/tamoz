# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/harness/version'

TamozGemspec.build(
  name: 'tamoz-harness',
  version: Tamoz::Harness::VERSION,
  summary: 'The coding-harness protocol for Tamoz work loops',
  description: 'The system prompt pack, operator persona and preferences, project guidance, the living plan, ' \
               'native tool-call parsing, loop budgets and the repeat guard, the finish contract and handoff ' \
               'notes. Depends on tamoz-context-engine and tamoz-core only.',
  dependencies: [
    ['tamoz-context-engine', "= #{Tamoz::Harness::VERSION}"],
    ['tamoz-core', "= #{Tamoz::Harness::VERSION}"]
  ],
  runtime_contracts: ['prompts/*.md', 'prompts/*.json']
)
