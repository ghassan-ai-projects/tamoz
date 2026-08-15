# frozen_string_literal: true

require "json"
require "tamoz/agent/errors"

module Tamoz
  module Agent
    # P0B/§5: the strict parser for the model's per-turn reasoning output. A turn
    # is untrusted judgment (trust table §3): the parser proves the bytes are a
    # well-formed v2 document and nothing more — it never resolves evidence against
    # the frame, grants authority, or trusts a model-asserted confidence.
    #
    # A turn is EITHER terminal (diagnosis + recommendations) or a tool request,
    # never both. On a tool turn the terminal fields are absent, not empty
    # defaults. A terminal turn must cover every catalog code exactly once with
    # finite probabilities in [0,1] summing to one; Tamoz derives the selected code
    # (argmax, catalog order breaks ties) and raw confidence — the model asserts
    # neither.
    #
    # Every rejection raises ProtocolError with a stable `reasoning_document/<code>`
    # prefix so conformance fixtures can assert the exact failure.
    module ReasoningDocument
      PROTOCOL = "tamoz.episode-diagnosis/v2"

      MAX_BYTES = 64 * 1024
      MAX_HYPOTHESIS_BYTES = 4096
      MAX_CODE_BYTES = 256
      MAX_REF_BYTES = 512
      MAX_EVIDENCE_REFS = 128
      MAX_RECOMMENDED_INTENTS = 8
      MAX_TOOL_REQUESTS = 8
      MAX_PRESET_BYTES = 128
      PROBABILITY_TOLERANCE = 1e-6
      REF_PREFIXES = %w[fact evidence memory tool].freeze

      TOP_LEVEL_KEYS = %w[
        protocol primary_hypothesis diagnosis_probabilities evidence_refs
        tool_requests recommended_intents
      ].freeze
      TERMINAL_KEYS = %w[primary_hypothesis diagnosis_probabilities evidence_refs recommended_intents].freeze

      Probability = Data.define(:code, :probability)
      RecommendedIntent = Data.define(:type, :parameter_preset, :parameters)
      ToolRequest = Data.define(:name, :arguments)

      # A parsed turn. `kind` is :terminal or :tool; the other branch's fields are
      # nil. selected_code/raw_confidence are Tamoz-derived, not model-asserted.
      Document = Data.define(
        :kind, :primary_hypothesis, :probabilities, :selected_code,
        :raw_confidence, :evidence_refs, :recommended_intents, :tool_requests
      ) do
        def terminal? = kind == :terminal
        def tool_turn? = kind == :tool
      end

      class << self
        # bytes: the raw provider response String. catalog: the ordered diagnosis
        # codes for this spec (must include "unknown"). Returns a Document or
        # raises ProtocolError.
        def parse(bytes, catalog:)
          raise ProtocolError, "reasoning_document/not_string" unless bytes.is_a?(String)
          reject_oversize(bytes.bytesize, "document", MAX_BYTES)
          reject_bad_utf8(bytes)

          codes = validate_catalog(catalog)
          root = strict_parse(bytes)
          raise ProtocolError, "reasoning_document/not_object" unless root.is_a?(Hash)

          reject_unknown_keys(root, TOP_LEVEL_KEYS, "top_level")
          unless root["protocol"] == PROTOCOL
            raise ProtocolError, "reasoning_document/protocol: #{root["protocol"].inspect}"
          end

          if root.key?("tool_requests")
            parse_tool_turn(root)
          else
            parse_terminal_turn(root, codes)
          end
        end

        private

        def strict_parse(bytes)
          # allow_duplicate_key:false raises on `{"a":1,"a":2}` at any depth
          # instead of silently keeping the last value (json 3.0 default).
          JSON.parse(bytes, allow_duplicate_key: false)
        rescue JSON::ParserError => e
          # ProtocolError deliberately quotes provider text (errors.rb) — a prose
          # wrapper around the JSON also lands here.
          code = e.message.include?("duplicate key") ? "duplicate_key" : "malformed_json"
          raise ProtocolError, "reasoning_document/#{code}: #{e.message}"
        end

        def parse_tool_turn(root)
          TERMINAL_KEYS.each do |key|
            raise ProtocolError, "reasoning_document/tool_turn_has_terminal_field: #{key}" if root.key?(key)
          end
          requests = fetch_array(root, "tool_requests", MAX_TOOL_REQUESTS)
          raise ProtocolError, "reasoning_document/empty_tool_requests" if requests.empty?

          Document.new(
            kind: :tool, primary_hypothesis: nil, probabilities: nil,
            selected_code: nil, raw_confidence: nil, evidence_refs: nil,
            recommended_intents: nil, tool_requests: requests.map { |r| parse_tool_request(r) }
          )
        end

        def parse_terminal_turn(root, codes)
          hypothesis = fetch_bounded_string(root, "primary_hypothesis", MAX_HYPOTHESIS_BYTES)
          probabilities = parse_probabilities(root, codes)
          selected = select_argmax(probabilities, codes)

          Document.new(
            kind: :terminal, primary_hypothesis: hypothesis, probabilities: probabilities,
            selected_code: selected.code, raw_confidence: selected.probability,
            evidence_refs: parse_evidence_refs(root),
            recommended_intents: parse_recommended_intents(root),
            tool_requests: nil
          )
        end

        def parse_probabilities(root, codes)
          entries = fetch_array(root, "diagnosis_probabilities", codes.length)
          seen = {}
          probabilities = entries.map do |entry|
            raise ProtocolError, "reasoning_document/probability_not_object" unless entry.is_a?(Hash)

            reject_unknown_keys(entry, %w[diagnosis_code probability], "probability")
            code = fetch_bounded_string(entry, "diagnosis_code", MAX_CODE_BYTES)
            raise ProtocolError, "reasoning_document/unknown_diagnosis_code: #{code}" unless codes.include?(code)
            raise ProtocolError, "reasoning_document/duplicate_diagnosis_code: #{code}" if seen[code]

            seen[code] = true
            Probability.new(code: code, probability: fetch_probability(entry))
          end

          missing = codes - seen.keys
          raise ProtocolError, "reasoning_document/missing_diagnosis_codes: #{missing.join(",")}" unless missing.empty?

          total = probabilities.sum(&:probability)
          unless (total - 1.0).abs <= PROBABILITY_TOLERANCE
            raise ProtocolError, "reasoning_document/probabilities_sum: #{total}"
          end

          probabilities
        end

        # Argmax with catalog order as the deterministic tie-break, so identical
        # top probabilities always select the same code.
        def select_argmax(probabilities, codes)
          order = codes.each_with_index.to_h
          probabilities.max_by { |p| [p.probability, -order.fetch(p.code)] }
        end

        def parse_evidence_refs(root)
          return [] unless root.key?("evidence_refs")

          refs = fetch_array(root, "evidence_refs", MAX_EVIDENCE_REFS)
          refs.map do |ref|
            raise ProtocolError, "reasoning_document/evidence_ref_not_string" unless ref.is_a?(String)
            reject_oversize(ref.bytesize, "evidence_ref", MAX_REF_BYTES)
            prefix = ref.split(":", 2).first
            raise ProtocolError, "reasoning_document/evidence_ref_format: #{ref}" unless REF_PREFIXES.include?(prefix)

            ref
          end
        end

        def parse_recommended_intents(root)
          return [] unless root.key?("recommended_intents")

          intents = fetch_array(root, "recommended_intents", MAX_RECOMMENDED_INTENTS)
          intents.map do |intent|
            raise ProtocolError, "reasoning_document/intent_not_object" unless intent.is_a?(Hash)

            reject_unknown_keys(intent, %w[type parameter_preset parameters], "recommended_intent")
            type = fetch_bounded_string(intent, "type", MAX_CODE_BYTES)
            preset = optional_bounded_string(intent, "parameter_preset", MAX_PRESET_BYTES)
            parameters = intent["parameters"]
            if preset && parameters
              raise ProtocolError, "reasoning_document/intent_preset_and_parameters: #{type}"
            end
            if parameters && !parameters.is_a?(Hash)
              raise ProtocolError, "reasoning_document/intent_parameters_not_object: #{type}"
            end

            RecommendedIntent.new(type: type, parameter_preset: preset, parameters: parameters)
          end
        end

        def parse_tool_request(request)
          raise ProtocolError, "reasoning_document/tool_request_not_object" unless request.is_a?(Hash)

          reject_unknown_keys(request, %w[name arguments], "tool_request")
          name = fetch_bounded_string(request, "name", MAX_CODE_BYTES)
          arguments = request.fetch("arguments", {})
          raise ProtocolError, "reasoning_document/tool_arguments_not_object: #{name}" unless arguments.is_a?(Hash)

          ToolRequest.new(name: name, arguments: arguments)
        end

        def fetch_probability(entry)
          value = entry["probability"]
          raise ProtocolError, "reasoning_document/probability_not_number" unless value.is_a?(Numeric)

          float = value.to_f
          raise ProtocolError, "reasoning_document/probability_not_finite" unless float.finite?
          raise ProtocolError, "reasoning_document/probability_range: #{float}" unless float >= 0.0 && float <= 1.0

          float
        end

        def fetch_array(root, key, max)
          value = root[key]
          raise ProtocolError, "reasoning_document/#{key}_not_array" unless value.is_a?(Array)
          raise ProtocolError, "reasoning_document/#{key}_too_many: #{value.length}" if value.length > max

          value
        end

        def fetch_bounded_string(hash, key, max)
          value = hash[key]
          raise ProtocolError, "reasoning_document/#{key}_missing" unless hash.key?(key)
          raise ProtocolError, "reasoning_document/#{key}_not_string" unless value.is_a?(String)
          reject_bad_utf8(value)
          reject_oversize(value.bytesize, key, max)

          value
        end

        def optional_bounded_string(hash, key, max)
          return nil unless hash.key?(key)

          fetch_bounded_string(hash, key, max)
        end

        def reject_unknown_keys(hash, allowed, context)
          unknown = hash.keys - allowed
          raise ProtocolError, "reasoning_document/unknown_key: #{context}.#{unknown.first}" unless unknown.empty?
        end

        def reject_oversize(bytesize, what, max)
          raise ProtocolError, "reasoning_document/#{what}_too_large: #{bytesize}" if bytesize > max
        end

        def reject_bad_utf8(string)
          # Validate the bytes, not the label: a provider may hand back valid
          # UTF-8 tagged ASCII-8BIT. Only genuinely invalid byte sequences fail.
          valid = if string.encoding == Encoding::UTF_8
                    string.valid_encoding?
                  else
                    string.dup.force_encoding(Encoding::UTF_8).valid_encoding?
                  end
          raise ProtocolError, "reasoning_document/invalid_utf8" unless valid
        end

        def validate_catalog(catalog)
          # Accept a DiagnosisCatalog or a bare ordered code list.
          list = catalog.respond_to?(:codes) ? catalog.codes : catalog
          raise ProtocolError, "reasoning_document/catalog_not_array" unless list.is_a?(Array)
          raise ProtocolError, "reasoning_document/catalog_empty" if list.empty?

          codes = list.map(&:to_s)
          raise ProtocolError, "reasoning_document/catalog_duplicate" unless codes.uniq.length == codes.length

          codes
        end
      end
    end
  end
end
