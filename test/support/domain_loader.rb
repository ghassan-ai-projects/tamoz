# frozen_string_literal: true

require "json"
require "tamoz/core"
require "tamoz/agent"

# Domain-knowledge extraction (docs/new-design/impl/DOMAIN_DATA_EXTRACTION.md):
# the domain content (catalogs, prompts, intents, watch-property rules,
# compensation maps, presets, snapshots, fixtures, benchmark-family config)
# lives in test/fixtures/domains/*.json — ZERO domain knowledge in Ruby code.
# This loader is the machinery: it rebuilds the fully-expanded intent-catalog
# entries (schema, digest, presets, compensation), the fixture documents
# (probability normalization), and the snapshots from the data.
#
# ORDER IS DIGEST-SIGNIFICANT: JCS canonicalization sorts hash keys but does
# NOT sort arrays. The loader preserves intent_types insertion order and the
# catalog array order exactly; it never sorts.
class DomainLoader
  FIXTURES_ROOT = File.expand_path("../fixtures/domains", __dir__)

  # The registered domain names — the single source of truth for which
  # fixtures exist (a new domain JSON is picked up automatically).
  def self.domains
    Dir[File.join(FIXTURES_ROOT, "*.json")].map { |path| File.basename(path, ".json") }.sort.freeze
  end

  def self.load(name)
    path = File.join(FIXTURES_ROOT, "#{name}.json")
    data = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
    new(data).freeze
  rescue JSON::ParserError, KeyError => e
    raise "#{name.inspect} (#{path}): #{e.message}"
  end

  # The shared intent-entry machinery, parameterized by the domain's data.
  # Reproduces the exact schema/digest/presets/compensation shape the wire
  # binds (description interpolation, parameter_schema_digest, watch
  # properties from JSON, compensation note/priority, policy, rate limit).
  def self.intent_entry(type:, risk:, compensation_map:, watch_preset:, watch_properties:)
    writable = type == "install_watch_condition" ? [] : %w[hypothesis]
    compensation_target = compensation_map.values.any? { |mapping| mapping.values.include?(type) }
    properties = {
      "entity_id" => {"type" => "string"},
      "situation_id" => {"type" => "string"},
      "situation_version" => {"type" => "integer"}
    }
    writable.each { |field| properties[field] = {"type" => "string", "maxLength" => 512} }
    if compensation_target
      properties["note"] = {"type" => "string", "maxLength" => 512}
      properties["priority"] = {"type" => "string", "maxLength" => 16}
    end
    if type == "install_watch_condition"
      watch_properties.each { |field, property| properties[field] = property }
    end
    schema = {"type" => "object", "additionalProperties" => false, "properties" => properties}
    entry = {
      "type" => type,
      "risk_class" => risk,
      "description" => "#{type} (#{risk})",
      "parameter_schema" => schema,
      "parameter_schema_digest" => "sha256:#{Digest::SHA256.hexdigest(Tamoz::Core.jcs(schema))}",
      "model_writable_fields" => writable,
      "presets" => type == "install_watch_condition" ? {"default" => watch_preset} : {"default" => {}},
      "policy" => {"requires_approval" => false},
      "rate_limit" => {"per_hour" => 60}
    }
    entry["compensation"] = compensation_map.fetch(type) if compensation_map.key?(type)
    entry
  end

  def initialize(data)
    @data = deep_freeze(data)
    @intent_catalog = @data.fetch("intent_types").map do |type, risk|
      DomainLoader.intent_entry(
        type:, risk:, compensation_map: @data.fetch("compensation_map", {}),
        watch_preset: @data.fetch("watch_preset", {}),
        watch_properties: @data.fetch("watch_properties", {})
      )
    end.freeze
    # Precomputed fixture responses (JCS strings) — order is load-bearing for
    # the fixture endpoint's index-based selection. Computed eagerly because
    # the instance is frozen (no ivar memoization after construction).
    @fixture_responses = @data.fetch("fixtures", []).map do |fixture|
      Tamoz::Core.jcs(document(selected: fixture.fetch("selected"), hypothesis: fixture.fetch("hypothesis")))
    end.freeze
  end

  attr_reader :intent_catalog

  def catalog = @data.fetch("catalog")
  def objective = @data.fetch("objective")
  def prompt = @data.fetch("prompt")
  def intent_types = @data.fetch("intent_types")
  def benchmark_family = @data.fetch("benchmark_family", {})

  def intent_catalog_digest
    Tamoz::Core.digest(:intent_catalog, @intent_catalog)
  end

  # Deterministic v2 document (gate 3: perturbed response → different
  # selected_code). Probabilities cover every catalog code exactly once and
  # sum to 1. The default intent comes from the domain's document template.
  def document(selected:, hypothesis:, intent: nil)
    template = @data.fetch("document_template")
    codes = catalog.map { |entry| entry.fetch("code") }
    total = codes.length.to_f
    probabilities = codes.map do |code|
      {
        "diagnosis_code" => code,
        "probability" => code == selected ? 0.8 : (0.2 / (total - 1)).round(4)
      }
    end
    probabilities.last["probability"] = (1.0 - probabilities[0..-2].sum { |p| p["probability"] }).round(4)
    document = {
      "protocol" => "tamoz.episode-diagnosis/v2",
      "primary_hypothesis" => hypothesis,
      "diagnosis_probabilities" => probabilities,
      "evidence_refs" => template.fetch("evidence_refs")
    }
    type = intent ? intent.fetch(:type) : template.fetch("default_intent_type")
    if intent || template.fetch("default_intent_type")
      document["recommended_intents"] = [
        {
          "type" => type,
          "parameters" => {"hypothesis" => String(intent&.fetch(:hypothesis, nil) || hypothesis)}
        }
      ]
    end
    document
  end

  def fixture_responses
    @fixture_responses
  end

  # A profile document (hash) whose `fast` role points at the given endpoint.
  # Pure machinery — not domain data.
  def profile_document(endpoint:, root:, model: "gemma4")
    {
      "profile" => {
        "schema_version" => 1,
        "profile_id" => "tamoz-worker-p1",
        "profile_version" => "1.0",
        "canonical_root" => root
      },
      "roots" => {"workspace" => root},
      "tools" => {"allowed" => %w[read_file list_directory], "approval_required" => []},
      "policy" => {
        "allow_changes" => false,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => "sha256:#{"0" * 64}"
      },
      "model_roles" => {
        "fast" => {
          "provider" => "ollama",
          "model" => model,
          "normalized_settings" => {"base_url" => endpoint}
        }
      }
    }
  end

  # A snapshot with the domain's situation metadata and fact template;
  # keyword overrides (translated through the domain's kwarg_map, e.g.
  # climate's temperature: → zone_temperature) replace the template
  # defaults. The entity id is the named fact (entity_id_fact), so a
  # metrics-only override (e.g. dissolved_oxygen:) keeps the default entity
  # id.
  def snapshot(**overrides)
    template = @data.fetch("snapshot")
    kwarg_map = template.fetch("kwarg_map", {})
    unknown = overrides.keys.map(&:to_s) - kwarg_map.keys
    unless unknown.empty?
      raise ArgumentError, "unknown snapshot overrides for #{@data.fetch("domain")}: #{unknown.join(", ")}"
    end
    remapped = overrides.to_h { |key, value| [kwarg_map.fetch(key.to_s, key.to_s), value] }
    facts = template.fetch("fact_defaults").merge(remapped)
    {
      "situation_id" => template.fetch("situation_id"),
      "situation_version" => template.fetch("situation_version"),
      "tenant_id" => template.fetch("tenant_id"),
      "situation_type" => template.fetch("situation_type"),
      "entity" => {"type" => template.fetch("entity_type"), "id" => facts.fetch(template.fetch("entity_id_fact"))},
      "facts" => facts,
      "event_horizon" => template.fetch("event_horizon")
    }
  end

  private

  def deep_freeze(value)
    case value
    when Hash
      value.each { |k, v| deep_freeze(v) }
      value.freeze
    when Array
      value.each { |v| deep_freeze(v) }
      value.freeze
    else
      value
    end
  end
end
