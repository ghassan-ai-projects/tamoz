# frozen_string_literal: true

module Tamoz
  module Mcp
    # Base class for every failure raised by the governed MCP client/host.
    class Error < Tamoz::Error
      CATEGORY = "mcp"
      SAFE_MESSAGE = "An MCP server interaction failed."
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
  end
end
