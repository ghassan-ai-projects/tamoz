# frozen_string_literal: true

require "json"
require "zeitwerk"
require_relative "core/version"

module Tamoz
  module Core
    ROOT = File.expand_path("../../..", __dir__).freeze

    # P16: pre-P9 sessions carry no skill catalog. "none" is the epoch of a session
    # that had no skills, which is exactly what a skill-free P9 session records
    # too, so an old session and a new skill-free session resume identically
    # (invariant 41). Homed here so the moved toolbox's empty-snapshot
    # `skill_epoch` resolves without any agent constant.
    LEGACY_SKILL_EPOCH = "none"

    # DR-5 RC3: the session-record sentinel for sessions that predate trusted
    # profiles. Homed in tamoz-core so the profile validator can reserve the id
    # (a real profile named "legacy" would silently destroy the sentinel
    # semantics) without a session dependency edge.
    LEGACY_PROFILE_ID = "legacy"

    # Audit F2: the intent-catalog watch type. Homed in tamoz-core so the
    # tamoz-stream decision builder (the injected-port boundary) resolves it
    # WITHOUT a tamoz-agent dependency edge; tamoz-agent's IntentCatalog
    # aliases it. The wire value is frozen — a change is a new intent catalog.
    INTENT_WATCH_TYPE = "install_watch_condition"

    # P16: the D-7 taxonomy classes moved into tamoz-core, but every durable and
    # model-visible serialization of them keeps the public `Tamoz::Agent::Tool*`
    # spellings. This is the single stable mapping applied at the three
    # serialization sites (effect journal, session record, model-visible failure
    # payload); the repair-loop dedup keys hash kind/tool/reason/arguments and
    # contain no class name, so the mapping cannot churn dedup.
    TOOL_ERROR_CLASS_NAMES = {
      "Tamoz::Core::ToolError" => "Tamoz::Agent::ToolError",
      "Tamoz::Core::ToolArgumentError" => "Tamoz::Agent::ToolArgumentError",
      "Tamoz::Core::ToolPolicyError" => "Tamoz::Agent::ToolPolicyError"
    }.freeze

    # Shapes that must never enter a prompt, transcript, journal, or index
    # (invariant 24): a PEM private key header, an sk/pk/xox-prefixed token,
    # an AWS access key id, or a Google API key. The one canonical set — reuse
    # it rather than re-deriving it, since a new provider's key pattern added
    # here should not require finding every independent copy.
    SECRET_VALUE_PATTERNS = [
      /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
      /\b(sk|pk|xox[baprs])-[A-Za-z0-9][A-Za-z0-9_-]{7,}/,
      /\bAKIA[0-9A-Z]{16}\b/,
      /\bAIza[0-9A-Za-z_-]{35}\b/
    ].freeze

    loader = Zeitwerk::Loader.new
    loader.tag = "tamoz-core"
    loader.inflector.inflect("jcs" => "JCS")
    loader.push_dir(File.expand_path("..", __dir__))
    loader.ignore(__FILE__)
    loader.ignore(File.expand_path("core/version.rb", __dir__))
    loader.setup
    loader.eager_load
    @loader = loader

    module_function

    # Serializes a class name through the tool-error mapping. Anything outside the
    # D-7 family passes through unchanged, so unrelated classes always emit their
    # true `.name` (never a forced or raw-core spelling).
    def serialized_tool_error_name(value)
      TOOL_ERROR_CLASS_NAMES.fetch(String(value), String(value))
    end

    # Pure canonical sorter (the deliberation canonical, homed in core so the
    # skills digests and the session-record digests share one implementation):
    # keys sorted, stringified, recursed; the input is never mutated.
    def canonical(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, entry), normalized|
          normalized[String(key)] = canonical(entry)
        end.sort.to_h
      when Array
        value.map { |entry| canonical(entry) }
      else
        value
      end
    end

    # RFC 8785 canonical bytes for a Ruby value. The digest rule for anything
    # that is hashed, persisted, compared, or replayed (CONTRACTS.md §2-3).
    def jcs(value)
      JCS.canonicalize(value)
    end

    # Strict-parse raw JSON (duplicate keys and unpaired surrogates refused)
    # then canonicalize. Use for received documents.
    def jcs_json(raw)
      JCS.canonicalize_json(raw)
    end

    # Strict-parse raw JSON and return the VALUE (no canonicalization). Use
    # when a verifier needs both the parsed document and its digest.
    def parse_json_strict(raw)
      JCS.parse(raw)
    end

    # Domain-separated digest: "sha256:" + hex(SHA256(domain || jcs)).
    def digest(domain, value)
      JCS.digest(domain, value)
    end

    def normalize_digest(expected)
      JCS.normalize_digest(expected)
    end

    def digest_bytes(expected)
      JCS.digest_bytes(expected)
    end

    # True for a well-formed "sha256:" + 64 hex chars digest string
    # (Tamoz::Core::JCS::DIGEST_PATTERN) — the one wire-format shape every
    # digest in this repo uses.
    def valid_digest?(value)
      JCS.valid_digest?(value)
    end

    # True when value is, or (recursively, through Hash/Array) contains, a
    # string matching SECRET_VALUE_PATTERNS.
    def secret_shaped?(value)
      case value
      when String
        SECRET_VALUE_PATTERNS.any? { |pattern| pattern.match?(value) }
      when Hash
        value.values.any? { |entry| secret_shaped?(entry) }
      when Array
        value.any? { |entry| secret_shaped?(entry) }
      else
        false
      end
    end

    # Constant-time verification; recomputes and compares, never prefers a
    # locally recomputed value on mismatch.
    def verify_digest(domain, value, expected)
      JCS.verify(domain, value, expected)
    end

    # Deep freezer for JSON-shaped values (the plan/session-records freezer, homed
    # in core so the skills compiler and the durable records share one
    # implementation). Scalars are returned as-is, containers are rebuilt with
    # frozen keys/values, and anything that cannot cross a durable boundary raises.
    def deep_freeze(value)
      case value
      when Hash
        value.to_h { |key, entry| [String(key).dup.freeze, deep_freeze(entry)] }.freeze
      when Array
        value.map { |entry| deep_freeze(entry) }.freeze
      when String
        value.dup.freeze
      when NilClass, TrueClass, FalseClass, Numeric
        value
      else
        raise Tamoz::Error, "unsupported plan argument #{value.class}"
      end
    end

    # Deep MUTABLE copy for JSON-shaped values — the counterpart of deep_freeze
    # for the paths that must go on mutating the result. Keys and strings are
    # duplicated so the copy shares no mutable state with the original, and key
    # types are preserved (unlike deep_freeze, which stringifies and freezes).
    # Homed here so the circuit record and the stream decision builder share one
    # implementation instead of hand-rolling a spelling each.
    def deep_dup(value)
      case value
      when Hash then value.to_h { |key, entry| [deep_dup(key), deep_dup(entry)] }
      when Array then value.map { |entry| deep_dup(entry) }
      when String then value.dup
      else value
      end
    end

    # Strict JSON-object parse for untrusted model documents: accepts an already
    # parsed Hash (symbol keys normalized to strings), strips a markdown fence,
    # and refuses non-object documents. Homed here so durable-memory
    # consolidation and the deliberation loop share one implementation.
    def parse_object(value)
      return value.transform_keys(&:to_s) if value.is_a?(Hash)

      text = String(value).strip
      text = text.delete_prefix("```json").delete_prefix("```").delete_suffix("```").strip
      document = JSON.parse(text)
      raise ProtocolError, "model response must be a JSON object" unless document.is_a?(Hash)

      document
    rescue JSON::ParserError => error
      raise ProtocolError, "model returned invalid JSON: #{error.message}"
    end

    # Typed string coercion for document fields: refuses non-strings under the
    # field's name and returns a frozen copy.
    def string(value, name:)
      raise ProtocolError, "#{name} must be a string" unless value.is_a?(String)

      value.dup.freeze
    end

    # Typed string-array coercion; every entry is validated through #string.
    def strings(value, name:)
      raise ProtocolError, "#{name} must be an array" unless value.is_a?(Array)

      value.map { |entry| string(entry, name: "#{name} entry") }.freeze
    end

    # P6: the RECONSIDER payload normalization — a Hash with the four
    # string-keyed members (prior_decision/commands/outcomes/correction). Homed
    # in core so both the stream module and the agent intake node consume ONE
    # contract (symbol- or string-keyed input, typed refusal on a half-shaped
    # payload).
    def normalize_reconsideration(hash)
      unless hash.is_a?(Hash)
        raise Tamoz::Error, "reconsideration payload is not an object"
      end

      normalized = hash.transform_keys(&:to_s)
      missing = %w[prior_decision commands outcomes correction].reject do |key|
        normalized.key?(key)
      end
      unless missing.empty?
        raise Tamoz::Error,
              "reconsideration payload is missing: #{missing.join(", ")}"
      end

      {
        "prior_decision" => normalized.fetch("prior_decision"),
        "commands" => Array(normalized["commands"]),
        "outcomes" => Array(normalized["outcomes"]),
        "correction" => normalized.fetch("correction")
      }
    end
  end
end
