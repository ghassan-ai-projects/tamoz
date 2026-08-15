# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent/errors"

module Tamoz
  module Agent
    # P0B/§5: the versioned diagnosis vocabulary a SituationSpec carries. It is
    # trusted control-plane config (the compiler binds its canonical bytes and
    # digest into the request, frame, manifest, and Decision; Agentic Stream
    # verifies the digest independently), so a malformed catalog fails closed
    # before any model call — it is never model output.
    #
    # Order is significant: it is the deterministic tie-break for the terminal
    # turn's argmax (§5), so the digest binds order. The catalog never contains a
    # sealed-truth id, scorer alias, fault filename, or simulator control name;
    # this type enforces the structural rules (format, `unknown` present,
    # uniqueness, bounds) that make such leakage detectable, while the benchmark
    # authoring scan (§9.2) enforces the semantic ones.
    class DiagnosisCatalog
      UNKNOWN = "unknown"
      DIGEST_DOMAIN = "tamoz.agent.diagnosis_catalog.v1\n"
      CODE_PATTERN = /\A[a-z][a-z0-9_]{0,63}\z/
      MAX_ENTRIES = 64
      MAX_DESCRIPTION_BYTES = 512

      Entry = Data.define(:code, :description)

      attr_reader :entries

      # list: an ordered Array of {code:, description:} (string or symbol keys).
      def self.from_list(list)
        raise DiagnosisCatalogError, "diagnosis_catalog/not_array" unless list.is_a?(Array)
        raise DiagnosisCatalogError, "diagnosis_catalog/empty" if list.empty?
        raise DiagnosisCatalogError, "diagnosis_catalog/too_many: #{list.length}" if list.length > MAX_ENTRIES

        entries = list.map { |raw| build_entry(raw) }
        new(entries)
      end

      def self.build_entry(raw)
        raise DiagnosisCatalogError, "diagnosis_catalog/entry_not_object" unless raw.is_a?(Hash)

        code = String(raw[:code] || raw["code"])
        description = String(raw[:description] || raw["description"] || "")
        unless CODE_PATTERN.match?(code)
          raise DiagnosisCatalogError, "diagnosis_catalog/bad_code: #{code.inspect}"
        end
        if description.bytesize > MAX_DESCRIPTION_BYTES
          raise DiagnosisCatalogError, "diagnosis_catalog/description_too_large: #{code}"
        end
        unless description.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          raise DiagnosisCatalogError, "diagnosis_catalog/description_invalid_utf8: #{code}"
        end

        Entry.new(code: code, description: description)
      end
      private_class_method :build_entry

      def initialize(entries)
        codes = entries.map(&:code)
        unless codes.uniq.length == codes.length
          raise DiagnosisCatalogError, "diagnosis_catalog/duplicate_code"
        end
        raise DiagnosisCatalogError, "diagnosis_catalog/missing_unknown" unless codes.include?(UNKNOWN)

        @entries = entries.freeze
        @by_code = entries.to_h { |e| [e.code, e] }.freeze
      end

      def codes = @entries.map(&:code)

      def include?(code) = @by_code.key?(code)

      def description(code) = @by_code.fetch(code).description

      # The ordered canonical form the digest binds. Arrays preserve order under
      # RFC 8785, so identical vocabularies in a different order digest differently.
      def canonical
        @entries.map { |e| {"code" => e.code, "description" => e.description} }
      end

      def canonical_bytes = Tamoz::Core.jcs(canonical)

      def digest = Tamoz::Core.digest(DIGEST_DOMAIN, canonical)
    end
  end
end
