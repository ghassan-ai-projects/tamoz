# frozen_string_literal: true

require "json"
require "uri"

require "mcp"

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
          fields = requests.map { |id, params| field_descriptor(id.to_s, params) }.freeze
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

          responses = {}
          fields.each do |field|
            id = field.fetch("id")
            content = if fields.length == 1
                        answers
                      else
                        answers[id] || raise(
                          ToolArgumentError,
                          "the answer to an MCP elicitation is missing the fields for request #{id}"
                        )
                      end
            validate_answer_content!(field, content)
            responses[id] = { "action" => "accept", "content" => content }
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

        def field_descriptor(id, params)
          unless params.is_a?(Hash) && params["method"] == ELICITATION_METHOD &&
                 params["params"].is_a?(Hash)
            raise ToolPolicyError,
                  "an MCP server returned an input request that is not a supported elicitation"
          end

          request = params["params"]
          schema = request["requestedSchema"]
          unless schema.is_a?(Hash)
            raise ToolPolicyError,
                  "an MCP server returned an elicitation request without a requested schema"
          end
          # Schema content is server-controlled text that rides into the durable
          # interrupt: every string in it (property names, descriptions, enum
          # values, defaults, ...) gets the same control-strip + byte-bound
          # treatment as `message`, so the interrupt can never carry raw control
          # characters or unbounded server content.
          schema = sanitize_schema(schema)
          validate_field_schema!(schema)

          {
            "id" => bounded_message(id.to_s),
            "message" => bounded_message(request["message"]),
            "schema" => deep_freeze(CanonicalJSON.normalize(schema))
          }.freeze
        end

        # Deep control-strip + byte-bound over every string in the requested
        # schema (keys included — a property name may not smuggle control
        # characters either).
        def sanitize_schema(node)
          case node
          when Hash
            node.each_with_object({}) do |(key, value), out|
              out[bounded_message(key.to_s)] = sanitize_schema(value)
            end
          when Array
            node.map { |entry| sanitize_schema(entry) }
          when String
            bounded_message(node)
          else
            node
          end
        end

        # The schema is validated with the SDK's JSON Schema 2020-12 validator,
        # and credential-shaped property names reject the whole interrupt: a
        # server asking for secrets never gets them auto-filled or surfaced.
        def validate_field_schema!(schema)
          properties = schema["properties"]
          if properties.is_a?(Hash)
            properties.each_key do |name|
              next unless ServerConfig.credential_env_name?(name.to_s)

              raise ToolPolicyError,
                    "an MCP server requested a credential-shaped field; the elicitation was rejected"
            end
          end

          begin
            MCP::Tool::InputSchema.new(schema)
          rescue ArgumentError
            raise ToolPolicyError,
                  "an MCP server returned an elicitation request with an invalid schema"
          end
        end

        def validate_answer_content!(field, content)
          unless content.is_a?(Hash)
            raise ToolArgumentError,
                  "the answer to an MCP elicitation must be a JSON object of field values"
          end

          schema = field.fetch("schema")
          begin
            MCP::Tool::InputSchema.new(strict_schema(schema)).validate_arguments(content)
          rescue MCP::Tool::InputSchema::ValidationError => error
            detail = Tamoz::Error.disclosable_message(
              error.message.sub(/\AInvalid arguments:\s*/, ""),
              fallback: "the answer does not match the requested schema"
            )
            raise ToolArgumentError,
                  "the answer to an MCP elicitation is invalid: #{detail}"
          rescue ArgumentError, JSON::NestingError
            raise ToolArgumentError,
                  "the answer to an MCP elicitation is malformed or too deeply nested"
          end
          content
        end

        # Same default-deny rule as Invocation: unknown answer fields are
        # rejected unless the schema explicitly allows them.
        def strict_schema(schema)
          candidate = schema.is_a?(Hash) ? schema : {}
          root = deep_strictify(candidate)
          root = root.merge("additionalProperties" => false) if strictable_object?(candidate)
          root
        end

        def deep_strictify(node)
          case node
          when Hash
            stricted = {}
            node.each { |key, value| stricted[key] = deep_strictify(value) }
            stricted["additionalProperties"] = false if strictable_object?(node)
            stricted
          when Array
            node.map { |value| deep_strictify(value) }
          else
            node
          end
        end

        def strictable_object?(node)
          return false unless node.is_a?(Hash) && node.key?("properties")
          return false if node.key?("additionalProperties") || node.key?("patternProperties")
          return false if node.key?("$ref") || node.key?("$dynamicRef")

          true
        end

        # v1 egress gate for an offered elicitation URL: absolute http(s) only,
        # with a host and no embedded credentials. Broader SSRF/redirect policy
        # is P10-D2; an offered URL that fails this gate is simply omitted.
        def checked_url(requests, url_policy)
          raw = requests.filter_map do |_id, params|
            request = params.is_a?(Hash) ? params["params"] : nil
            request["url"] if request.is_a?(Hash) && request["url"].is_a?(String)
          end.first
          return nil if raw.nil?

          url = raw.dup.force_encoding(Encoding::UTF_8)
          return nil unless url.valid_encoding? && egress_ok?(url)
          return nil if url_policy && !url_policy.call(url)

          url.freeze
        end

        def egress_ok?(url)
          uri = URI.parse(url)
          uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty? && uri.userinfo.nil?
        rescue URI::InvalidURIError
          false
        end

        def bounded_message(value)
          text = String(value || "").dup.force_encoding(Encoding::UTF_8)
          text = text.scrub("") unless text.valid_encoding?
          text = text.gsub(CONTROL_CHARACTER_PATTERN, " ").strip
          if text.bytesize > MAX_MESSAGE_BYTES
            text = text.byteslice(0, MAX_MESSAGE_BYTES).scrub("").rstrip
          end
          text.freeze
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each { |key, entry| deep_freeze(entry) }
          when Array
            value.each { |entry| deep_freeze(entry) }
          when String
            value.freeze
          end
          value.freeze
        end
      end
    end
  end
end
