# frozen_string_literal: true

require "json"
require "uri"

require "mcp"

require_relative "elicitation/fields"
require_relative "elicitation/answers"

module Tamoz
  module Mcp
    # 2026 MRTR elicitation (P10 §7): an `input_required` tool result becomes a
    # durable interrupt descriptor bound to the originating call — never a tool
    # error. The interrupt carries the configured server identity, the requested
    # field descriptors (schema-validated, bounded, control-stripped), an
    # egress-checked URL when one is offered, and the originating call's
    # deterministic `effect_key`. The opaque MRTR `request_state` rides along so
    # the answer can be schema-validated and the call re-issued with the input
    # merged, as MRTR requires. Headless runs deny with a typed value; consent
    # is never fabricated.
    module Elicitation
      KIND = "mcp_elicitation"
      DENIED_KIND = "mcp_elicitation_denied"
      MAX_INPUT_REQUESTS = 32
      MAX_MESSAGE_BYTES = 4096
      ELICITATION_METHOD = "elicitation/create"

      class << self
        # Builds the durable interrupt descriptor from the SDK's
        # `InputRequiredError` payload. Raises `ToolPolicyError` when the
        # `input_required` result is malformed, uses a non-elicitation request
        # shape, or asks for a credential-shaped field (never auto-filled).
        def build(descriptor:, effect_key:, input_requests:, request_state:, url_policy: nil)
          requests = validate_input_requests!(input_requests)
          fields = requests.map { |id, params| Fields.new.field_descriptor(id.to_s, params) }.freeze
          url = checked_url(requests, url_policy)

          {
            "kind" => KIND,
            "server_id" => descriptor.source_id,
            "capability" => descriptor.id,
            "definition_digest" => descriptor.definition_digest,
            "fields" => fields,
            "url" => url,
            "effect_key" => effect_key,
            "request_state" => request_state
          }.compact.freeze
        end

        # Typed denial value for headless/unattended runs. Consent is explicit
        # `false`; no answer is fabricated or implied.
        def denial(server_id:, capability:, reason:)
          {
            "kind" => DENIED_KIND,
            "server_id" => server_id,
            "capability" => capability,
            "consent" => false,
            "reason" => reason
          }.freeze
        end

        # Schema-validates the operator's answers against each requested schema
        # (unknown properties rejected unless the schema allows them) and returns
        # the MRTR re-issue merge: `inputResponses` (id ⇒ `{action: "accept",
        # content: <validated values>}`) plus the echoed opaque `requestState`.
        # An invalid answer is a repairable `ToolArgumentError`.
        def answer(interrupt, answers)
          fields = interrupt.fetch("fields")
          unless answers.is_a?(Hash)
            raise ToolArgumentError,
                  "the answer to an MCP elicitation must be a JSON object of field values"
          end

          responses = fields.to_h do |field|
            [field.fetch("id"), Answers.new.input_response(field, answers, single_field: fields.length == 1)]
          end

          merge = { "inputResponses" => responses.freeze }
          state = interrupt["request_state"]
          merge["requestState"] = state unless state.nil?
          merge
        end

        private

        def validate_input_requests!(input_requests)
          unless input_requests.is_a?(Hash) && !input_requests.empty?
            raise ToolPolicyError,
                  "an MCP server returned an input_required result without a valid inputRequests map"
          end
          if input_requests.length > MAX_INPUT_REQUESTS
            raise ToolPolicyError,
                  "an MCP server returned more than #{MAX_INPUT_REQUESTS} input requests"
          end

          input_requests
        end

        # Deep control-strip + byte-bound over every string in the requested
        # schema (keys included — a property name may not smuggle control
        # characters either).

        # The schema is validated with the SDK's JSON Schema 2020-12 validator,
        # and credential-shaped property names reject the whole interrupt: a
        # server asking for secrets never gets them auto-filled or surfaced.

        # Same default-deny rule as Invocation: unknown answer fields are
        # rejected unless the schema explicitly allows them.

        # v1 egress gate for an offered elicitation URL: absolute http(s) only,
        # with a host and no embedded credentials. Broader SSRF/redirect policy
        # is P10-D2; an offered URL that fails this gate is simply omitted.
        def checked_url(requests, url_policy)
          raw = offered_url(requests)
          return nil if raw.nil?

          url = raw.dup.force_encoding(Encoding::UTF_8)
          return nil unless url.valid_encoding? && egress_ok?(url)
          return nil if url_policy && !url_policy.call(url)

          url.freeze
        end

        def offered_url(requests)
          requests.filter_map do |_id, params|
            request = params.is_a?(Hash) ? params["params"] : nil
            request["url"] if request.is_a?(Hash) && request["url"].is_a?(String)
          end.first
        end

        def egress_ok?(url)
          uri = URI.parse(url)
          uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil?
        rescue URI::InvalidURIError
          false
        end

      end
    end
  end
end
