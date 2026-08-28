# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent"
require_relative "domain_loader"

# Real-world sensor (docs/real-world-sensor-tamoz): the thermal-lab supervisory
# domain authored as DATA in test/fixtures/domains/thermal-lab.json. ZERO
# production Ruby (B9); this is a thin loader over the JSON, mirroring
# ClimateDomain. The decision surface is thermal MODE selection, not a diagnosis
# filing. Fixture responses are labeled `fixture` and never shown as evidence of
# a real model path (B8).
module ThermalLabDomain
  DOMAIN = DomainLoader.load("thermal-lab")

  CATALOG = DOMAIN.catalog
  OBJECTIVE = DOMAIN.objective
  PROMPT = DOMAIN.prompt
  INTENT_CATALOG = DOMAIN.intent_catalog
  INTENT_TYPES = DOMAIN.intent_types
  FIXTURE_RESPONSES = DOMAIN.fixture_responses

  def self.intent_catalog_digest = DOMAIN.intent_catalog_digest

  def self.document(selected:, hypothesis:, intent: nil)
    DOMAIN.document(selected:, hypothesis:, intent:)
  end

  def self.snapshot(**overrides) = DOMAIN.snapshot(**overrides)
end
