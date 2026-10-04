# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent"
require_relative "domain_loader"

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
