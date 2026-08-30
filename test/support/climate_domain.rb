# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent"
require_relative "domain_loader"

# P4 exit gate 4: a NOVEL domain authored as DATA in
# test/fixtures/domains/climate.json. ZERO production Ruby: the
# fixed graph is domain-agnostic (B9) and this module is a thin loader over
# the JSON. The climate domain covers a greenhouse temperature/humidity cell.
module ClimateDomain
  DOMAIN = DomainLoader.load("climate")

  CATALOG = DOMAIN.catalog
  OBJECTIVE = DOMAIN.objective
  PROMPT = DOMAIN.prompt
  INTENT_CATALOG = DOMAIN.intent_catalog
  INTENT_TYPES = DOMAIN.intent_types
  FIXTURE_RESPONSES = DOMAIN.fixture_responses

  def self.intent_catalog_digest = DOMAIN.intent_catalog_digest

  def self.document(selected:, hypothesis:)
    DOMAIN.document(selected:, hypothesis:)
  end

  def self.snapshot(**overrides) = DOMAIN.snapshot(**overrides)
end
