# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent"
require_relative "domain_loader"

# P1/§"One real domain": the aquaculture DO-crash cell, authored as DATA in
# test/fixtures/domains/aquaculture.json (domain-knowledge extraction —
# docs/new-design/impl/DOMAIN_DATA_EXTRACTION.md). This module is a thin
# loader exposing the domain's constants and builders; ZERO domain knowledge
# lives in Ruby code here (B9). Fixture responses are labeled `fixture` and
# are never shown as evidence of a real model path (B8).
module AquacultureDomain
  DOMAIN = DomainLoader.load("aquaculture")

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

  def self.profile_document(endpoint:, root:, model: "gemma4")
    DOMAIN.profile_document(endpoint:, root:, model:)
  end
end
