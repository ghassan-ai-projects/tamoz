# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/skills/version'

TamozGemspec.build(
  name: 'tamoz-skills',
  version: Tamoz::Skills::VERSION,
  summary: 'Agent Skills for Tamoz',
  description: 'Portable Agent Skills (SKILL.md directories): the inert compiler, content-addressed identity, ' \
               'the catalog, attributed rendering and digest-pinned resource reads. Grants no authority. ' \
               'Depends on tamoz-core only.',
  dependencies: [
    ['tamoz-core', "= #{Tamoz::Skills::VERSION}"]
  ],
  runtime_contracts: ['skills/**/*', 'data/*.md']
).tap do |spec|
  # TamozGemspec.build already sets this range; restated where RuboCop's Gemspec cop can see it.
  spec.required_ruby_version = Gem::Requirement.new('>= 3.3', '< 5.0')
end
