# frozen_string_literal: true

require "digest"
require "json"
require "timeout"

require "mcp"

require_relative "invocation/observation"
require_relative "invocation/arguments"
require_relative "invocation/channel"
require_relative "invocation/exchange"
require_relative "invocation/transport_errors"
require_relative "invocation/result"

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
          Arguments.new.validate_descriptor!(descriptor)
          arguments = Arguments.new.validate_arguments!(descriptor, arguments)
          supervisor.exclusively do
            client = Channel.new.open_pinned_channel(
              descriptor,
              snapshot: snapshot,
              supervisor: supervisor,
              client_factory: client_factory
            )
            Exchange.new.round_trip(
              descriptor: descriptor, arguments: arguments, client: client,
              supervisor: supervisor, effect_key: effect_key(descriptor, arguments),
              headless: headless, url_policy: url_policy, input: nil
            )
          end
        end

        # Re-issues an originating call after a §7 interrupt has been answered.
        # The answer is schema-validated by `Elicitation.answer` (typed
        # `ToolArgumentError` on an invalid answer) and merged per MRTR
        # (SEP-2322): `inputResponses` plus the echoed `requestState`, with the
        # original arguments untouched. May itself return :interrupt again if
        # the server asks for more input.
        def reissue(descriptor, arguments, snapshot:, supervisor:, interrupt:, answers:, client_factory: nil, headless: false, url_policy: nil)
          Arguments.new.validate_descriptor!(descriptor)
          merge = Elicitation.answer(interrupt, answers)
          supervisor.exclusively do
            client = Channel.new.open_pinned_channel(
              descriptor,
              snapshot: snapshot,
              supervisor: supervisor,
              client_factory: client_factory
            )
            Exchange.new.round_trip(
              descriptor: descriptor, arguments: arguments, client: client,
              supervisor: supervisor, effect_key: effect_key(descriptor, arguments),
              headless: headless, url_policy: url_policy, input: merge
            )
          end
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

        # Validates arguments against the already pinned descriptor schema without
        # connecting to or querying the remote server. Agent plan review uses this
        # same path as execution so schema errors become repairable before an
        # effect is journaled.
        def validate_arguments(descriptor, arguments)
          Arguments.new.validate_descriptor!(descriptor)
          Arguments.new.validate_arguments!(descriptor, arguments)
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
            output_schema: output_schema.nil? ? nil : CanonicalJSON.deep_freeze(output_schema),
            effect_class: effect_class.to_sym,
            protocol_profile: (protocol_profile || snapshot.protocol_version)
          )
        end

      end
    end
  end
end
