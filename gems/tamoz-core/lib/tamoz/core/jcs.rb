# frozen_string_literal: true

require "digest"

module Tamoz
  module Core
    # RFC 8785 (JSON Canonicalization Scheme) plus the domain-separated digest
    # rule from CONTRACTS.md §2-3. Number serialization follows ECMAScript
    # Number::toString (the reference semantics the shared vectors were
    # generated with); keys sort by UTF-16 code unit; strings use the JCS
    # minimal escape table; producers reject NaN, ±Infinity, -0, duplicate
    # keys, unpaired surrogates, and integers that do not round-trip through
    # an IEEE-754 double.
    #
    # canonicalize(value) accepts a Ruby value. canonicalize_json(raw)
    # strict-parses raw JSON first (duplicate keys and unpaired surrogates are
    # refused at parse time). Both produce identical bytes for the same
    # document, so a received canonical JSON document verifies against a value
    # computed in code.
    module JCS
      Error = Class.new(Tamoz::Error)

      # CONTRACTS.md §3.2 — the shared domain table. Tamoz-internal seals that
      # never cross the product boundary use "tamoz/<type>/v<major>\n" domains.
      SHARED_DOMAINS = {
        snapshot: "situation-runtime/snapshot/v1\n",
        spec: "situation-runtime/spec/v1\n",
        decision: "situation-runtime/decision/v1\n",
        intent: "situation-runtime/intent/v1\n",
        command: "situation-runtime/command/v1\n",
        event: "situation-runtime/event/v1\n",
        diagnosis_catalog: "situation-runtime/diagnosis-catalog/v1\n",
        intent_catalog: "situation-runtime/intent-catalog/v1\n",
        skill_set: "situation-runtime/skill-set/v1\n",
        test: "situation-runtime/test/v1\n"
      }.freeze

      MAX_SAFE_INTEGER = 9_007_199_254_740_991 # 2**53 - 1

      # The one wire-format shape for a domain-separated digest (CONTRACTS.md
      # §2-3): "sha256:" plus 64 lowercase hex characters. The canonical home
      # for this check — reference it instead of re-deriving the regex.
      DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/

      module_function

      def canonicalize(value)
        Writer.emit(value, +"")
      end

      def canonicalize_json(raw)
        parse(raw).then { |value| Writer.emit(value, +"") }
      end

      # Strict-parse raw JSON and return the VALUE (no canonicalization).
      # Used by verifiers that need both the parsed document and its digest.
      def parse(raw)
        unless raw.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          raise Error, "document is not valid UTF-8"
        end

        scanner = Scanner.new(raw.b)
        value = scanner.parse_value
        scanner.eof!
        value
      end

      # "sha256:" + hex(SHA256(domain_bytes || jcs_bytes)). domain is either a
      # SHARED_DOMAINS key or a raw domain string that must end in "\n".
      def digest(domain, value)
        domain = SHARED_DOMAINS.fetch(domain) if domain.is_a?(Symbol)
        unless domain.is_a?(String) && domain.end_with?("\n")
          raise ArgumentError, "JCS digest domain must end with a newline"
        end

        "sha256:" + Digest::SHA256.hexdigest(domain + canonicalize(value))
      end

      def normalize_digest(expected)
        return expected unless expected.is_a?(String)
        return "sha256:#{expected.unpack1("H*")}" if expected.bytesize == 32

        expected
      end

      def digest_bytes(expected)
        normalized = normalize_digest(expected)
        return normalized unless valid_digest?(normalized)

        [normalized.delete_prefix("sha256:")].pack("H*")
      end

      # True for a well-formed "sha256:" + 64 hex chars digest string.
      def valid_digest?(value)
        value.is_a?(String) && DIGEST_PATTERN.match?(value)
      end

      # Constant-time comparison; verification is recomputation, never a
      # locally-preferred value on mismatch.
      def verify(domain, value, expected)
        expected = normalize_digest(expected)
        return false unless expected.is_a?(String) && expected.start_with?("sha256:")

        actual = digest(domain, value)
        return false unless actual.bytesize == expected.bytesize

        diff = 0
        actual.each_byte.zip(expected.each_byte) { |a, b| diff |= a ^ b }
        diff.zero?
      end

      private_constant :Writer, :NumberFormat, :Scanner
    end
  end
end
