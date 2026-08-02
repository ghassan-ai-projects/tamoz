# frozen_string_literal: true

require "digest"
require "json"
require "timeout"

require "mcp"

module Tamoz
  module Mcp
    # Executes one catalogued MCP capability through Tamoz's typed outcome
    # taxonomy (P10 §6). The pipeline is strict and ordered:
    #
    #   validate arguments against the snapshotted input schema (JSON Schema
    #     2020-12, unknown properties rejected unless the schema explicitly
    #     allows them; nesting bounded)
    #   → verify the descriptor's definition digest matches the session-pinned
    #     snapshot BEFORE any I/O
    #   → invoke through the supervised client under the request deadline
    #   → validate the protocol result shape and, when a schema is declared, the
    #     structured content against it
    #   → bound the output to budgets.max_output_bytes, strip control
    #     characters, and attribute every content block
    #   → translate the outcome into the exact §6 taxonomy table
    #
    # The caller drives the result through its own effect journal; tamoz-mcp
    # never retries automatically except for `:read_only` descriptors, and the
    # retry budget lives in the Supervisor.
    module Invocation
      MAX_ARGUMENT_DEPTH = 100
      EFFECT_KEY_DOMAIN = "tamoz.mcp.effect.v1\n"
      ATTRIBUTION_TEMPLATE = "remote content from server %s"
      REMOTE_ERROR_PREFIX = "mcp_remote_error"
      UNAVAILABLE_PREFIX = "mcp_unavailable"
      WIRE_PREFIX = "mcp_wire"
      MAX_STRUCTURED_FIELD_BYTES = 2048
      REQUIRED_DESCRIPTOR_METHODS = %i[id name source_id definition_digest input_schema effect_class].freeze

      # One §6 outcome. `status` is :succeeded, :interrupt (elicitation), or
      # :denied (headless/unattended). `observation` is the attributed result;
      # `interrupt` and `denial` are the §7 descriptors; `effect_key` is the
      # originating call's deterministic key.
      Outcome = Data.define(:status, :observation, :interrupt, :denial, :effect_key)

      # The bounded, attributed result of a successful call. Every
      # `content_blocks` hash carries
      # `"attribution" => "remote content from server <server_id>"`.
      Observation = Data.define(
        :server_id, :content_blocks, :text, :structured_content, :truncated
      ) do
        def attributed?
          content_blocks.all? do |block|
            block["attribution"] == format(ATTRIBUTION_TEMPLATE, server_id)
          end
        end

        def to_h
          {
            "server_id" => server_id,
            "content_blocks" => content_blocks,
            "text" => text,
            "structured_content" => structured_content,
            "truncated" => truncated
          }.freeze
        end
      end

      # The local, policy-bearing view of one catalogued capability that `call`
      # and `reissue` act on. `call` only requires the duck-type above; slice 4
      # supplies its own descriptor type. `descriptor_for` is the convenience
      # constructor for the catalog path.
      Descriptor = Data.define(
        :id, :name, :source_id, :definition_digest, :input_schema,
        :output_schema, :effect_class, :protocol_profile
      ) do
        def read_only?
          effect_class == :read_only
        end
      end

      class << self
        # One §6 round-trip. Returns an `Outcome` (:succeeded | :interrupt |
        # :denied); raises the taxonomy errors from the §6 table.
        def call(descriptor, arguments, snapshot:, supervisor:, client_factory: nil, headless: false, url_policy: nil)
          validate_descriptor!(descriptor)
          arguments = validate_arguments!(descriptor, arguments)
          verify_pinned_digest!(descriptor, snapshot)
          ensure_available!(descriptor, supervisor)

          client = build_client(supervisor, client_factory)
          ensure_connected!(descriptor, client, supervisor)
          effect_key = effect_key(descriptor, arguments)

          round_trip(
            descriptor: descriptor, arguments: arguments, client: client,
            supervisor: supervisor, effect_key: effect_key,
            headless: headless, url_policy: url_policy, input: nil
          )
        end

        # Re-issues an originating call after a §7 interrupt has been answered.
        # The answer is schema-validated by `Elicitation.answer` (typed
        # `ToolArgumentError` on an invalid answer) and merged per MRTR
        # (SEP-2322): `inputResponses` plus the echoed `requestState`, with the
        # original arguments untouched. May itself return :interrupt again if
        # the server asks for more input.
        def reissue(descriptor, arguments, snapshot:, supervisor:, interrupt:, answers:, client_factory: nil, headless: false, url_policy: nil)
          validate_descriptor!(descriptor)
          verify_pinned_digest!(descriptor, snapshot)
          ensure_available!(descriptor, supervisor)

          client = build_client(supervisor, client_factory)
          ensure_connected!(descriptor, client, supervisor)
          merge = Elicitation.answer(interrupt, answers)
          effect_key = effect_key(descriptor, arguments)

          round_trip(
            descriptor: descriptor, arguments: arguments, client: client,
            supervisor: supervisor, effect_key: effect_key,
            headless: headless, url_policy: url_policy, input: merge
          )
        end

        # Deterministic key of the originating call, used as the interrupt's
        # `effect_key` and stable across MRTR re-issues of the same call.
        def effect_key(descriptor, arguments)
          payload = EFFECT_KEY_DOMAIN + CanonicalJSON.dump(
            "id" => descriptor.id,
            "arguments" => CanonicalJSON.normalize(arguments || {})
          )
          "sha256:#{Digest::SHA256.hexdigest(payload)}"
        end

        # Convenience constructor for the catalog path: builds a frozen
        # `Descriptor` whose definition digest is the snapshot entry's pinned
        # digest. `effect_class` is local policy (default `:unknown_effects` →
        # non-idempotent); `output_schema` is the declared output schema when the
        # caller has one.
        def descriptor_for(entry, snapshot:, effect_class: :unknown_effects, output_schema: nil, trust: nil, protocol_profile: nil)
          unless entry.is_a?(Entry)
            raise ValidationError, "entry must be a Tamoz::Mcp::Entry"
          end

          Descriptor.new(
            id: "mcp:#{snapshot.server_id}/#{entry.name}",
            name: entry.name,
            source_id: snapshot.server_id,
            definition_digest: entry.definition_digest,
            input_schema: entry.schema,
            output_schema: output_schema.nil? ? nil : deep_freeze_json(output_schema),
            effect_class: effect_class.to_sym,
            protocol_profile: (protocol_profile || snapshot.protocol_version)
          )
        end

        private

        # --- argument validation (repairable) --------------------------------

        def validate_descriptor!(descriptor)
          missing = REQUIRED_DESCRIPTOR_METHODS.reject { |method| descriptor.respond_to?(method) }
          unless missing.empty?
            raise ValidationError, "descriptor must respond to #{missing.join(", ")}"
          end
          if descriptor.id.to_s.empty? || descriptor.name.to_s.empty? || descriptor.source_id.to_s.empty?
            raise ValidationError, "descriptor id, name, and source_id must be non-empty"
          end
          descriptor
        end

        # JSON Schema 2020-12 via the SDK's validator, with unknown properties
        # rejected unless the schema explicitly allows them, and nesting bounded
        # (schema-bomb / over-depth defenses, plan §10.2).
        def validate_arguments!(descriptor, arguments)
          arguments = {} if arguments.nil?
          unless arguments.is_a?(Hash)
            raise ToolArgumentError,
                  "the arguments for #{descriptor.id} must be a JSON object"
          end
          assert_depth!(descriptor, arguments, 0)

          begin
            MCP::Tool::InputSchema.new(strict_schema(descriptor.input_schema || {})).validate_arguments(arguments)
          rescue MCP::Tool::InputSchema::ValidationError => error
            detail = Tamoz::Error.disclosable_message(
              error.message.sub(/\AInvalid arguments:\s*/, ""),
              fallback: "the arguments do not match the snapshotted schema"
            )
            raise ToolArgumentError,
                  "the arguments for #{descriptor.id} are invalid: #{detail}"
          rescue ArgumentError, JSON::NestingError
            raise ToolArgumentError,
                  "the arguments for #{descriptor.id} are malformed or too deeply nested"
          end
          arguments
        end

        def assert_depth!(descriptor, value, depth)
          if depth > MAX_ARGUMENT_DEPTH
            raise ToolArgumentError,
                  "the arguments for #{descriptor.id} exceed the maximum nesting depth of #{MAX_ARGUMENT_DEPTH}"
          end

          case value
          when Hash
            value.each_value { |child| assert_depth!(descriptor, child, depth + 1) }
          when Array
            value.each { |child| assert_depth!(descriptor, child, depth + 1) }
          end
        end

        # Deep copy with `additionalProperties: false` injected at object
        # subschemas that declare `properties` but no explicit allowance — the
        # root always gets the default-deny unless it opts out. Never injects
        # into a subschema carrying `$ref`/`$dynamicRef` (2020-12 applies
        # sibling keywords, which would break the reference) and never into a
        # subschema that already declares `additionalProperties` or
        # `patternProperties`. A bare `{ "type": "object" }` subschema is left
        # open: JSON Schema treats it as an arbitrary map.
        def strict_schema(schema)
          candidate = schema.is_a?(Hash) ? schema : {}
          root = deep_strictify(candidate)
          if strictable_object?(candidate)
            root = root.merge("additionalProperties" => false)
          end
          root
        end

        def deep_strictify(node)
          case node
          when Hash
            stricted = {}
            node.each { |key, value| stricted[key] = deep_strictify(value) }
            if strictable_object?(node)
              stricted["additionalProperties"] = false
            end
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

        # --- pinned digest gate (stops before any I/O) ------------------------

        def verify_pinned_digest!(descriptor, snapshot)
          unless snapshot.respond_to?(:entries)
            raise ValidationError, "snapshot must be a Tamoz::Mcp::Catalog snapshot"
          end

          entry = snapshot.entries.find { |candidate| candidate.name == descriptor.name }
          unless entry && entry.definition_digest == descriptor.definition_digest
            raise CatalogSnapshotUnavailableError,
                  "the definition digest for #{descriptor.id} does not match the " \
                  "pinned catalog snapshot; no request was sent"
          end
          nil
        end

        # --- supervision gate -------------------------------------------------

        def ensure_available!(descriptor, supervisor)
          case supervisor.state
          when :open
            raise UnavailableError,
                  "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} circuit is " \
                  "open after #{supervisor.circuit_threshold} consecutive transport failures"
          when :retired
            raise UnavailableError,
                  "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} is retired"
          end
          nil
        end

        def build_client(supervisor, client_factory)
          factory = client_factory || ->(sup) { MCP::Client.new(transport: sup) }
          client = factory.call(supervisor)
          unless client.respond_to?(:call_tool)
            raise ValidationError, "client_factory must return an MCP client"
          end
          client
        end

        def ensure_connected!(descriptor, client, supervisor)
          return if supervisor.connected?

          supervisor.start unless supervisor.started?
          min, max = supervisor.config.protocol_range
          begin
            ::Timeout.timeout(supervisor.config.budgets.connect_timeout) do
              client.connect(client_info: CLIENT_INFO, protocol_version: max)
            end
          rescue ::Timeout::Error, MCP::Client::RequestHandlerError,
                 MCP::Client::ServerError, MCP::Client::ValidationError => error
            # §6's corruption row applies to the handshake too: a server that
            # answers initialize with malformed frames broke the protocol
            # contract and must never become a retryable value the planner can
            # iterate on. The corruption is detectable here exactly as in
            # `raise_classified_transport` (RequestHandlerError wrapping a
            # JSON::ParserError); the classification is the fix.
            if corruption?(error)
              supervisor.record_failure(kind: :corruption)
              raise ToolPolicyError.new(
                "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned " \
                "malformed frames during the protocol handshake; the protocol " \
                "contract was broken",
                **stderr_metadata(supervisor)
              )
            end

            supervisor.record_failure(kind: :connect)
            raise UnavailableError.new(
              "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} failed to connect",
              **stderr_metadata(supervisor)
            )
          end
          nil
        end

        # --- the wire round-trip ----------------------------------------------

        def round_trip(descriptor:, arguments:, client:, supervisor:, effect_key:, headless:, url_policy:, input:)
          max_attempts = 1 + (descriptor.read_only? ? supervisor.retry_budget : 0)
          attempts = 0
          begin
            response = call_with_deadline(client, descriptor, arguments, supervisor, input)
          rescue Timeout::Error, MCP::Client::RequestHandlerError => error
            attempts += 1
            sent = transport_failure(descriptor, supervisor, error)
            # Read-only calls may retry through the supervisor's restart budget;
            # corruption is terminal and never retried. The restart spawns a
            # fresh process, so the transport must be reconnected before retry.
            if attempts < max_attempts && descriptor.read_only? && !supervisor.open? &&
               !corruption?(error)
              supervisor.restart
              ensure_connected!(descriptor, client, supervisor)
              retry
            end
            raise_classified_transport(descriptor, supervisor, error, sent: sent)
          rescue MCP::Client::ServerError => error
            supervisor.record_success
            raise remote_tool_error(descriptor, error.code)
          rescue MCP::Client::ValidationError
            supervisor.record_failure(kind: :protocol)
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned a " \
                  "malformed response for #{descriptor.id}"
          rescue MCP::Client::InputRequiredError => error
            supervisor.record_success
            return interrupt_or_deny(
              descriptor, error,
              effect_key: effect_key, headless: headless, url_policy: url_policy
            )
          end

          classify_response(response, descriptor: descriptor, supervisor: supervisor, effect_key: effect_key)
        end

        def call_with_deadline(client, descriptor, arguments, supervisor, input)
          ::Timeout.timeout(supervisor.config.budgets.request_timeout) do
            if input.nil?
              client.call_tool(name: descriptor.name, arguments: arguments)
            else
              params = {
                name: descriptor.name,
                arguments: arguments,
                inputResponses: input.fetch("inputResponses")
              }
              state = input["requestState"]
              params[:requestState] = state unless state.nil?
              # The SDK's private `request` pipeline: JSON-RPC error raising,
              # `_meta` handling, and `input_required` detection all stay in the
              # official client (P10 §1: never reimplement the protocol).
              client.send(:request, method: "tools/call", params: params)
            end
          end
        end

        # Records the failure and returns whether the request was fully written
        # before the failure. `true` ⇒ the server may have acted (ambiguous for
        # non-idempotent); `false` ⇒ provably no effect. The typed context is
        # recorded with the failure so a caller-initiated reset carries a
        # meaningful conditions digest (DR-2).
        def transport_failure(descriptor, supervisor, error)
          sent = supervisor.request_sent?
          kind = if error.is_a?(OutputLimitError)
                   :output_limit
                 elsif corruption?(error)
                   :corruption
                 elsif error.is_a?(Timeout::Error)
                   :timeout
                 else
                   :transport
                 end
          context = {
            "tool_name" => descriptor.name,
            "failure_class" => error.class.name
          }
          supervisor.record_failure(kind: kind, context: context)
          sent
        end

        def corruption?(error)
          error.is_a?(MCP::Client::RequestHandlerError) &&
            error.original_error.is_a?(JSON::ParserError)
        end

        # §8: stderr is untrusted server content; the supervisor's ring bounds
        # and control-scrubs it, and it surfaces only as typed error metadata.
        def stderr_metadata(supervisor)
          { stderr_tail: supervisor.stderr_tail }
        end

        # The exact §6 taxonomy rows for transport outcomes.
        def raise_classified_transport(descriptor, supervisor, error, sent:)
          if corruption?(error)
            raise ToolPolicyError.new(
              "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned " \
              "malformed frames for #{descriptor.id}; the protocol contract was broken",
              **stderr_metadata(supervisor)
            )
          end
          if sent
            if descriptor.read_only?
              raise UnavailableError.new(
                "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} failed " \
                "after the request to #{descriptor.id} was sent; the call is read-only " \
                "and may be retried by the caller",
                **stderr_metadata(supervisor)
              )
            end

            raise AmbiguousOutcomeError.new(
              "the MCP server #{descriptor.source_id} failed after the request to " \
              "#{descriptor.id} was sent; the effect is unknown and must not be guessed",
              **stderr_metadata(supervisor)
            )
          end

          raise ToolArgumentError.new(
            "#{UNAVAILABLE_PREFIX}: the MCP server #{descriptor.source_id} failed " \
            "before the request to #{descriptor.id} was sent; no effect occurred",
            **stderr_metadata(supervisor)
          )
        end

        def remote_tool_error(descriptor, code)
          if code.nil?
            ToolArgumentError.new(
              "#{REMOTE_ERROR_PREFIX}: the MCP server #{descriptor.source_id} declared a " \
              "failure for #{descriptor.id}"
            )
          else
            ToolArgumentError.new(
              "#{REMOTE_ERROR_PREFIX}: the MCP server #{descriptor.source_id} rejected the " \
              "call to #{descriptor.id} with error code #{code}"
            )
          end
        end

        # --- elicitation (never a tool error) ----------------------------------

        def interrupt_or_deny(descriptor, error, effect_key:, headless:, url_policy:)
          if headless
            denial = Elicitation.denial(
              server_id: descriptor.source_id,
              capability: descriptor.id,
              reason: "unattended runs cannot answer an MCP elicitation"
            )
            return Outcome.new(
              status: :denied, observation: nil, interrupt: nil,
              denial: denial, effect_key: effect_key
            )
          end

          interrupt = Elicitation.build(
            descriptor: descriptor,
            effect_key: effect_key,
            input_requests: error.input_requests,
            request_state: error.request_state,
            url_policy: url_policy
          )
          Outcome.new(
            status: :interrupt, observation: nil, interrupt: interrupt,
            denial: nil, effect_key: effect_key
          )
        end

        # --- result shape validation (protocol contract) ----------------------

        def classify_response(response, descriptor:, supervisor:, effect_key:)
          result = validate_result_shape!(response, descriptor)
          if result["isError"] == true
            supervisor.record_success
            raise remote_tool_error(descriptor, nil)
          end
          validate_structured_content!(result, descriptor)

          # The transport demonstrably worked: a successful round-trip breaks
          # the consecutive-failure streak that feeds the circuit.
          supervisor.record_success

          observation = build_observation(result, descriptor, supervisor)
          Outcome.new(
            status: :succeeded, observation: observation,
            interrupt: nil, denial: nil, effect_key: effect_key
          )
        end

        def validate_result_shape!(response, descriptor)
          unless response.is_a?(Hash) && response["result"].is_a?(Hash)
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned a " \
                  "response that is not a JSON-RPC success result"
          end

          result = response["result"]
          unless result["content"].is_a?(Array)
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned a " \
                  "tool result without a content array"
          end
          result
        end

        def validate_structured_content!(result, descriptor)
          schema = descriptor.output_schema
          return if schema.nil?
          return if result["structuredContent"].nil?

          begin
            MCP::Tool::OutputSchema.new(schema).validate_result(result["structuredContent"])
          rescue MCP::Tool::OutputSchema::ValidationError, ArgumentError
            raise ToolPolicyError,
                  "#{WIRE_PREFIX}: the MCP server #{descriptor.source_id} returned " \
                  "structured content for #{descriptor.id} that violates the declared " \
                  "output schema"
          end
        end

        # --- output bounding / stripping / attribution -------------------------

        def build_observation(result, descriptor, supervisor)
          budget = supervisor.config.budgets.max_output_bytes
          blocks, blocks_truncated = attribute_blocks(result["content"], descriptor.source_id, budget)
          structured, structured_truncated = sanitize_structured(result["structuredContent"], budget)
          text = attributed_text(blocks, descriptor.source_id)

          Observation.new(
            server_id: descriptor.source_id,
            content_blocks: blocks,
            text: text,
            structured_content: structured,
            truncated: blocks_truncated || structured_truncated
          )
        end

        # Caller-facing convenience join over the attributed blocks. A single
        # text block is self-attributing (the observation's `content_blocks`
        # carry the provenance), so its content stays bare; a multi-block join
        # would lose which block came from where, so every block in it is
        # prefixed with the same attribution line the blocks carry.
        def attributed_text(blocks, source_id)
          texts = blocks.filter_map { |block| block["text"] if block["type"] == "text" }
          return "" if texts.empty?
          return texts.first if texts.length == 1

          attribution = format(ATTRIBUTION_TEMPLATE, source_id)
          texts.map { |text| "#{attribution}: #{text}" }.join("\n")
        end

        def attribute_blocks(content, source_id, budget)
          attribution = format(ATTRIBUTION_TEMPLATE, source_id)
          blocks = []
          truncated = false
          remaining = budget

          content.each do |block|
            break if remaining <= 0

            unless block.is_a?(Hash)
              raise ToolPolicyError,
                    "#{WIRE_PREFIX}: the MCP server #{source_id} returned a content " \
                    "block that is not an object"
            end

            type = block["type"]
            attributed = { "attribution" => attribution, "type" => type }
            case type
            when "text"
              text = scrub_text(block["text"].to_s)
              if text.bytesize > remaining
                text = truncate_bytes(text, remaining)
                truncated = true
              end
              attributed["text"] = text
              remaining -= text.bytesize
            when "image"
              data = block["data"].to_s
              if data.bytesize > remaining
                data = truncate_bytes(data, remaining)
                truncated = true
              end
              attributed["data"] = data
              attributed["mimeType"] = scrub_text(block["mimeType"].to_s)[0, 128]
              remaining -= data.bytesize
            when "resource"
              resource = block["resource"]
              unless resource.is_a?(Hash)
                raise ToolPolicyError,
                      "#{WIRE_PREFIX}: the MCP server #{source_id} returned a resource " \
                      "content block without a resource object"
              end
              uri = scrub_text(resource["uri"].to_s)[0, MAX_STRUCTURED_FIELD_BYTES]
              text = scrub_text(resource["text"].to_s)
              if text.bytesize > remaining
                text = truncate_bytes(text, remaining)
                truncated = true
              end
              attributed["resource"] = { "uri" => uri, "text" => text }
              remaining -= text.bytesize
            else
              raise ToolPolicyError,
                    "#{WIRE_PREFIX}: the MCP server #{source_id} returned a content " \
                    "block with an unknown type"
            end
            blocks << attributed.freeze
          end

          truncated = true if content.length > blocks.length
          [blocks.freeze, truncated]
        end

        # Structured content is data, not prompt text, but it is still output:
        # strings are control-stripped and the canonical serialization is bounded
        # to the budget (oversized or over-deep content is bounded away and the
        # observation is marked truncated — never passed through verbatim).
        def sanitize_structured(structured, budget)
          return [nil, false] if structured.nil?

          copied = strip_controls_deep(structured)
          bytes = CanonicalJSON.dump(copied).bytesize
          return [deep_freeze_json(copied), false] if bytes <= budget

          [nil, true]
        rescue ValidationError
          [nil, true]
        end

        def strip_controls_deep(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, entry), out| out[key.to_s] = strip_controls_deep(entry) }
          when Array
            value.map { |entry| strip_controls_deep(entry) }
          when String
            scrub_text(value)
          else
            value
          end
        end

        def scrub_text(value)
          text = String(value).dup.force_encoding(Encoding::UTF_8)
          text = text.scrub("") unless text.valid_encoding?
          text.gsub(CONTROL_CHARACTER_PATTERN, " ")
        end

        def truncate_bytes(text, bytes)
          text.byteslice(0, bytes).scrub("").rstrip
        end

        def deep_freeze_json(value)
          case value
          when Hash
            value.each { |key, entry| deep_freeze_json(entry) }
          when Array
            value.each { |entry| deep_freeze_json(entry) }
          when String
            value.freeze
          end
          value.freeze
        end
      end
    end
  end
end
