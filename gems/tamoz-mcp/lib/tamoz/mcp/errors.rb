# frozen_string_literal: true

module Tamoz
  module Mcp
    # Base class for every failure raised by the governed MCP client/host.
    class Error < Tamoz::Error
      CATEGORY = "mcp"
      SAFE_MESSAGE = "An MCP server interaction failed."

      # Bounded, control-scrubbed tail of the server's stderr (P10 §8). Stderr
      # is untrusted server content and surfaces only as typed error metadata
      # on transport-failure errors — never into prompts. `nil` when the
      # failing path never touched a server (argument/schema/remote rows).
      attr_reader :stderr_tail

      def initialize(message = nil, stderr_tail: nil)
        @stderr_tail = stderr_tail.nil? ? nil : stderr_tail.dup.freeze
        super(message)
      end
    end

    # A server admission configuration was rejected. Validation is fail-closed:
    # the message is built from Tamoz literals and operator-supplied identifiers
    # the same operator already sees on the configuration surface, never from
    # server-provided content.
    class ValidationError < Error
      CATEGORY = "mcp_validation"
      USER_VISIBLE = true
      SAFE_MESSAGE = "The MCP server configuration is invalid."
    end

    # The wire or negotiation broke the protocol contract: out-of-range protocol
    # version, malformed frames, schema violations on the wire.
    class ProtocolError < Error
      CATEGORY = "mcp_protocol"
      SAFE_MESSAGE = "An MCP server broke the protocol contract."
    end

    # A resumed session cannot bind the exact catalog snapshot it ran against
    # (P10 §5 epoch rules). This is a stop, not a recoverable result: continuing
    # would run an accepted plan against a schema that has since changed.
    class CatalogSnapshotUnavailableError < Error
      CATEGORY = "mcp_catalog_snapshot_unavailable"
      SAFE_MESSAGE = "The pinned MCP catalog snapshot is unavailable."
    end

    # --- §6 outcome taxonomy (onto the merged D-7 classes) -------------------
    #
    # tamoz-mcp must not depend on tamoz-agent (plan §3), so the taxonomy classes
    # are defined here with the same names and semantics the agent's ToolError
    # hierarchy carries. Slice 4's duck-typed glue maps them onto the agent
    # surface. Every message is built from Tamoz literals plus identifiers the
    # operator already sees on the approved surface (capability id, server id,
    # argument names, budgets, digests, JSON-RPC error codes) — never from server
    # payload text — so each class opts in to `Tamoz::DisclosableMessage`.

    # Repairable planner mistake: invalid arguments, unknown properties,
    # over-depth arguments, a declared remote tool failure, or a provably
    # effect-free unavailability. Nothing was mutated, so the correct response is
    # to plan different arguments (or retry once the server recovers).
    class ToolArgumentError < Error
      include Tamoz::DisclosableMessage

      CATEGORY = "mcp_arguments"
      USER_VISIBLE = true
      SAFE_MESSAGE = "The arguments for an MCP tool call are invalid."

      def repairable? = true
    end

    # Terminal integrity violation: the server broke the protocol contract (bad
    # frames, malformed result shape, output-schema violation on the wire,
    # malformed or credential-shaped elicitation). Always terminal — a protocol
    # violation must never become a retryable value the planner can iterate on.
    class ToolPolicyError < Error
      include Tamoz::DisclosableMessage

      CATEGORY = "mcp_protocol"
      USER_VISIBLE = true
      SAFE_MESSAGE = "An MCP server broke the protocol contract."

      def repairable? = false
    end

    # Typed unavailability. Retryable by construction: either the failure was
    # provably effect-free, the call was read-only, or the circuit is open and
    # the caller must `reset` before retrying.
    class UnavailableError < Error
      include Tamoz::DisclosableMessage

      CATEGORY = "mcp_unavailable"
      RETRYABLE = true
      USER_VISIBLE = true
      SAFE_MESSAGE = "The MCP server is unavailable."
    end

    # A transport failure after the request was sent with a non-idempotent
    # effect class: the outcome is genuinely ambiguous and must be marked
    # `:unknown` (invariant 21 / 37 — never guess, never retry blindly).
    class AmbiguousOutcomeError < Error
      include Tamoz::DisclosableMessage

      CATEGORY = "mcp_effect_unknown"
      RETRYABLE = false
      SAFE_MESSAGE = "The outcome of an MCP tool call is unknown."
    end

    # A circuit-reset attempt lacked the evidence the scope's authority path
    # requires (DR-2 §5: egress resets need the operator command record) or a
    # component tried to reset its own circuit. A policy violation, never a
    # retryable value — the gate lives on the record write so no in-process
    # caller can bypass it.
    class CircuitPolicyError < Error
      include Tamoz::DisclosableMessage

      CATEGORY = "mcp_circuit_policy"
      USER_VISIBLE = true
      SAFE_MESSAGE = "A circuit reset was refused because it did not carry the required operator evidence."

      def repairable? = false
    end

    # Raised by the supervisor when a server response frame exceeds the transport
    # frame bound before Invocation could bound it (P10 §10.2 output-flood row).
    # Subclasses the SDK's handler error so existing SDK rescue paths keep
    # working, but carries the typed class Invocation classifies on. The stream
    # is desynced and the transport has been closed, so a retry needs a restart.
    class OutputLimitError < MCP::Client::RequestHandlerError
      def initialize(message = nil)
        super(
          message || "The MCP server response frame exceeded the transport bound.",
          {},
          error_type: :internal_error
        )
      end
    end
  end
end
