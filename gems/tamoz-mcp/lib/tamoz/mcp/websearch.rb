# frozen_string_literal: true

# The governed websearch capability (P17). NOT required by `tamoz/mcp.rb`: the
# dialer and HTTP stack live here, and only the operator-side server
# (`script/websearch_adapter`) and the test suite load this file — Tamoz's own
# core load path never pulls in a socket-capable dependency.
require "tamoz/mcp"
require_relative "websearch/egress_policy"
require_relative "websearch/egress_client"
require_relative "websearch/egress_circuit"

module Tamoz
  module Mcp
    # The websearch capability: an MCP server capability (`websearch` server
    # admitted via ServerConfig) whose server owns the HTTP stack. Tamoz itself
    # never makes an outbound call; the network-capable process is
    # operator-supplied and its egress is enforced outside Tamoz (P17 §2,
    # correction 2 — the honest enforcement-point claim).
    module Websearch
      DEFAULT_SERVER_ID = "websearch"

      # P17-06 (correction 8) — ONE budget vocabulary, no drift: the egress
      # declaration's budgets map onto `ServerConfig::Budgets`, the single MCP
      # budget vocabulary. `connect_timeout_s` → `budgets.connect_timeout`;
      # `max_response_bytes` → `budgets.max_output_bytes`; every other budget
      # keeps the `Budgets` default, so a fixture run and a real run agree on
      # timeouts by construction.
      def self.egress_budgets(egress)
        unless egress.is_a?(Hash) && egress["connect_timeout_s"].is_a?(Numeric) &&
               egress["max_response_bytes"].is_a?(Integer)
          raise ValidationError, "egress declaration must carry connect_timeout_s and max_response_bytes"
        end

        ServerConfig::Budgets.new(
          connect_timeout: egress.fetch("connect_timeout_s").to_f,
          max_output_bytes: egress.fetch("max_response_bytes")
        )
      end

      # --- credential hygiene (invariant 24 / P17 §5, W6, P17-A3) ----------

      # A query argument VALUE is credential-shaped when it is an env-style
      # assignment to a credential name, or a bare secret-shaped token. Such a
      # query is rejected at invocation (fail closed, no call is issued) — the
      # plan never sends a credential-looking string toward a remote provider.
      def self.credential_shaped_query?(value)
        text = String(value)
        text.match?(/\A[A-Z][A-Z0-9_]*[ \t]*[:=][ \t]*\S/) ||
          text.match?(/\b(?:sk|pk)-[A-Za-z0-9][A-Za-z0-9_-]{7,}\b/) ||
          text.match?(/\bAKIA[0-9A-Z]{16}\b/) ||
          text.match?(/\bAIza[0-9A-Za-z_-]{35}\b/)
      end

      # Search RESULT content is adversarial by construction (unlike
      # operator-vetted skill content): a credential-shaped assignment or a
      # secret-shaped token is stripped before it can become a
      # fillable/executable field or reach state, the journal, or a prompt
      # (P17-A3). The caller applies this to the observation text before it
      # enters the effect journal; the raw provider payload never renders
      # credential-shaped values as evidence. The scrub is segment-level, not
      # line-level, because the invocation pipeline control-strips newlines to
      # spaces before the caller sees the text — a line-level scrub would
      # discard the legitimate answer alongside the leak.
      def self.sanitize_result(text)
        body = String(text || "").dup.force_encoding(Encoding::UTF_8)
        body = body.scrub("") unless body.valid_encoding?
        body = body.gsub(CREDENTIAL_ASSIGNMENT_PATTERN) do
          "[#{$1} stripped]"
        end
        body = body.gsub(SECRET_TOKEN_PATTERN, "[credential-shaped content stripped]")
        body.freeze
      end

      CREDENTIAL_NAME_SEGMENT = %r{
        [A-Za-z0-9_.]*?(?:api_?keys?|access_?keys?|secret_?keys?|private_?keys?|
        session_?keys?|tokens?|secrets?|passwords?|credentials?|passphrase)[A-Za-z0-9_.]*?
      }ix
      CREDENTIAL_ASSIGNMENT_PATTERN = /(?<![A-Za-z0-9_.])(#{CREDENTIAL_NAME_SEGMENT})[ \t]*[:=][ \t]*[^\s]+/x
      SECRET_TOKEN_PATTERN = /
        \b(?:sk|pk)-[A-Za-z0-9][A-Za-z0-9_-]{7,}\b |
        \bAKIA[0-9A-Z]{16}\b |
        \bAIza[0-9A-Za-z_-]{35}\b |
        -----BEGIN[ A-Z]*PRIVATE\s+KEY-----
      /x
    end
  end
end
