# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent/errors"

module Tamoz
  module Agent
    # P4/§B9-B10: the spec-bound INTENT catalog — the domain's action
    # vocabulary. It is trusted control-plane config (the compiler binds its
    # canonical bytes and digest into the request; Agentic Stream verifies the
    # digest and the DECLARED risks independently), so a malformed catalog
    # fails closed before any model call — it is never model output.
    #
    # Each entry declares the authority for one action type: the EXACT risk
    # class (never under- or over-stated), a JSON-Schema for its parameters,
    # optional operator-authored parameter presets, the fields the MODEL may
    # fill directly, plus policy/rate-limit/compensation metadata. The model
    # proposes a type; the decide node and Agentic Stream read the authority
    # from HERE, never from the model's claim.
    #
    # Order is significant: it is the deterministic tie-break for the decision
    # builder, so the digest binds order.
    class IntentCatalog
      DIGEST_DOMAIN = :intent_catalog
      TYPE_PATTERN = /\A[a-z][a-z0-9_.-]{0,127}\z/
      RISK_CLASSES = %w[R0 R1 R2 R3 R4].freeze
      WATCH_TYPE = "install_watch_condition"
      MAX_ENTRIES = 64
      MAX_PARAMETERS = 128
      MAX_PRESET_BYTES = 64 * 1024
      MAX_DESCRIPTION_BYTES = 512

      # The structural subset of an entry the catalog binds. Policy, rate
      # limit, and compensation metadata ride along (enforced by Agentic
      # Stream; compensation consumed in P6) and are bound by the digest like
      # everything else — a forged policy or rate limit must fail the
      # cross-boundary check too.
      Entry = Data.define(
        :type, :risk_class, :parameter_schema, :parameter_schema_digest,
        :presets, :model_writable_fields, :description, :policy, :rate_limit,
        :compensation
      )

      attr_reader :entries

      # list: an ordered Array of intent entries (string or symbol keys).
      def self.from_list(list)
        raise IntentCatalogError, "intent_catalog/not_array" unless list.is_a?(Array)
        raise IntentCatalogError, "intent_catalog/empty" if list.empty?
        raise IntentCatalogError, "intent_catalog/too_many: #{list.length}" if list.length > MAX_ENTRIES

        entries = list.map { |raw| build_entry(raw) }
        new(entries)
      end

      # Wire gate (mirrors DiagnosisCatalog.verify_wire): strict-parse the
      # delivered bytes, verify the compiler's cross-boundary digest, then
      # build the validated catalog. A forged, mismatched, or malformed
      # catalog fails closed here — before any model call.
      def self.verify_wire(intent_catalog_json, expected_digest)
        unless intent_catalog_json.is_a?(String) && !intent_catalog_json.empty?
          raise IntentCatalogError, "intent_catalog/wire_empty"
        end

        value = Tamoz::Core.parse_json_strict(intent_catalog_json)
        unless Tamoz::Core.verify_digest(DIGEST_DOMAIN, value, expected_digest)
          raise IntentCatalogError, "intent_catalog/digest_mismatch"
        end

        from_list(value)
      end

      def self.build_entry(raw)
        raise IntentCatalogError, "intent_catalog/entry_not_object" unless raw.is_a?(Hash)

        type = String(raw[:type] || raw["type"])
        risk_class = String(raw[:risk_class] || raw["risk_class"]).upcase
        unless TYPE_PATTERN.match?(type)
          raise IntentCatalogError, "intent_catalog/bad_type: #{type.inspect}"
        end
        unless RISK_CLASSES.include?(risk_class)
          raise IntentCatalogError, "intent_catalog/bad_risk: #{risk_class.inspect}"
        end

        schema = raw[:parameter_schema] || raw["parameter_schema"]
        schema_digest = raw[:parameter_schema_digest] || raw["parameter_schema_digest"]
        schema_bytes = Tamoz::Core.jcs(schema) if schema
        if schema.nil?
          raise IntentCatalogError, "intent_catalog/missing_schema: #{type}"
        end
        unless schema.is_a?(Hash) && schema["type"] == "object"
          raise IntentCatalogError, "intent_catalog/schema_not_object: #{type}"
        end
        if schema_digest &&
           Tamoz::Core.normalize_digest(schema_digest.to_s) !=
           "sha256:#{Digest::SHA256.hexdigest(schema_bytes)}"
          raise IntentCatalogError, "intent_catalog/schema_digest_mismatch: #{type}"
        end

        presets = raw[:presets] || raw["presets"] || {}
        model_writable = Array(raw[:model_writable_fields] || raw["model_writable_fields"])
        property_names = schema.fetch("properties", {}).keys
        unless (model_writable - property_names).empty?
          raise IntentCatalogError,
                "intent_catalog/non_writable_field_not_in_schema: #{type}"
        end
        validate_presets!(type, schema, presets)

        description = String(raw[:description] || raw["description"] || "")
        if description.bytesize > MAX_DESCRIPTION_BYTES
          raise IntentCatalogError, "intent_catalog/description_too_large: #{type}"
        end

        rate_limit = raw[:rate_limit] || raw["rate_limit"]
        unless rate_limit.nil?
          unless rate_limit.is_a?(Hash) &&
                 rate_limit["per_hour"].is_a?(Integer) && rate_limit["per_hour"].positive?
            raise IntentCatalogError,
                  "intent_catalog/bad_rate_limit: #{type} (per_hour must be a positive integer)"
          end
        end

        Entry.new(
          type:, risk_class:,
          parameter_schema: schema.freeze,
          parameter_schema_digest: schema_digest ? Tamoz::Core.normalize_digest(schema_digest.to_s) : nil,
          presets: deep_freeze(presets),
          model_writable_fields: model_writable.map(&:to_s).freeze,
          description: description.freeze,
          policy: (raw[:policy] || raw["policy"] || {}).freeze,
          rate_limit: rate_limit.freeze,
          compensation: (raw[:compensation] || raw["compensation"] || {}).freeze
        )
      end
      private_class_method :build_entry

      def self.validate_presets!(type, schema, presets)
        raise IntentCatalogError, "intent_catalog/presets_not_object: #{type}" unless presets.is_a?(Hash)

        presets.each do |name, parameters|
          unless name.is_a?(String) && TYPE_PATTERN.match?(name)
            raise IntentCatalogError, "intent_catalog/bad_preset_name: #{type}.#{name}"
          end
          unless parameters.is_a?(Hash)
            raise IntentCatalogError, "intent_catalog/preset_not_object: #{type}.#{name}"
          end
          if parameters.keys.length > MAX_PARAMETERS
            raise IntentCatalogError, "intent_catalog/preset_too_large: #{type}.#{name}"
          end
          unknown = parameters.keys.map(&:to_s) - schema.fetch("properties", {}).keys
          unless unknown.empty?
            raise IntentCatalogError,
                  "intent_catalog/preset_unknown_parameter: #{type}.#{name}:#{unknown.first}"
          end
          if Tamoz::Core.jcs(parameters).bytesize > MAX_PRESET_BYTES
            raise IntentCatalogError, "intent_catalog/preset_too_large: #{type}.#{name}"
          end
        end
      end
      private_class_method :validate_presets!

      def self.deep_freeze(value)
        case value
        when Hash
          value.to_h { |key, entry| [key, deep_freeze(entry)] }.freeze
        when Array
          value.map { |entry| deep_freeze(entry) }.freeze
        else
          value
        end
      end
      private_class_method :deep_freeze

      def initialize(entries)
        types = entries.map(&:type)
        unless types.uniq.length == types.length
          raise IntentCatalogError, "intent_catalog/duplicate_type"
        end
        unless types.include?(WATCH_TYPE)
          raise IntentCatalogError, "intent_catalog/missing_watch_type"
        end

        @entries = entries.freeze
        @by_type = entries.to_h { |entry| [entry.type, entry] }.freeze
      end

      def types = @entries.map(&:type)

      def include?(type) = @by_type.key?(type)

      def entry(type) = @by_type.fetch(type)

      # The EXACT declared risk — the model's claim is never read.
      def risk_for(type)
        raise IntentCatalogError, "intent_catalog/unknown_type: #{type}" unless include?(type)

        entry(type).risk_class
      end

      # The canonical form the digest binds — a FAITHFUL slice of each entry,
      # exactly the keys present in the wire document (empty optional sections
      # are omitted, so a wire document without a `policy` key digests
      # identically to one whose policy is empty). Arrays preserve order under
      # RFC 8785, so identical vocabularies in a different order digest
      # differently.
      def canonical
        @entries.map { |entry| canonical_entry(entry) }
      end

      def canonical_entry(entry)
        result = {
          "type" => entry.type,
          "risk_class" => entry.risk_class,
          "parameter_schema" => entry.parameter_schema,
          "model_writable_fields" => entry.model_writable_fields
        }
        result["parameter_schema_digest"] = entry.parameter_schema_digest if entry.parameter_schema_digest
        result["presets"] = entry.presets unless entry.presets.empty?
        result["description"] = entry.description unless entry.description.empty?
        result["policy"] = entry.policy unless entry.policy.nil? || entry.policy.empty?
        result["rate_limit"] = entry.rate_limit unless entry.rate_limit.nil? || entry.rate_limit.empty?
        result["compensation"] = entry.compensation unless entry.compensation.nil? || entry.compensation.empty?
        result
      end

      def digest = Tamoz::Core.digest(DIGEST_DOMAIN, canonical)
    end
  end
end
