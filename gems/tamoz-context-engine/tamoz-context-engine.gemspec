# frozen_string_literal: true

require_relative '../gemspec_helper'
require_relative 'lib/tamoz/context_engine/version'

TamozGemspec.build(
  name: 'tamoz-context-engine',
  version: Tamoz::ContextEngine::VERSION,
  summary: 'Context-window management for Tamoz agent loops',
  description: 'A frozen request header and request series, an append-only surface log, ' \
               'reversible spill, a deterministic tool-result pruner, cache-aware compaction, ' \
               'a token meter, and disjoint cache usage accounting. Depends on tamoz-core only.',
  dependencies: [
    ['tamoz-core', "= #{Tamoz::ContextEngine::VERSION}"]
  ],
  runtime_contracts: ['prompts/*.md']
)
