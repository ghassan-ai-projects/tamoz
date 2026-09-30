# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/research/version'

TamozGemspec.build(
  name: 'tamoz-research',
  version: Tamoz::Research::VERSION,
  summary: 'The rules of a Tamoz deep-research run',
  description: 'Research plans, waves, cited sources checked against the pages read, the merged ledger, the ' \
               'stop rule, the report and the run folder. Pure: no I/O, no model or network call. Depends on ' \
               'tamoz-core only.',
  dependencies: [
    ['tamoz-core', "= #{Tamoz::Research::VERSION}"]
  ],
  runtime_contracts: ['data/*.json']
).tap do |spec|
  # TamozGemspec.build already sets this range; restated where RuboCop's Gemspec cop can see it.
  spec.required_ruby_version = Gem::Requirement.new('>= 3.3', '< 5.0')
end
