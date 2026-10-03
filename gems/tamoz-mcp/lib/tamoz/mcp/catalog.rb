# frozen_string_literal: true

require "digest"
require "json"
require "timeout"

require "mcp"

require_relative "catalog_entries"

module Tamoz
  module Mcp
    # Compiles a locally governed, immutable catalog snapshot from one MCP
    # server (P10 §5). The compile spawns a supervised stdio client, runs the
    # initialize handshake inside the configured protocol range (fail-closed
    # with `ProtocolError` outside it), lists the admitted primitives, bounds
    # and strips every server-supplied string, and computes deterministic
    # SHA-256 digests over canonical JSON with a domain separator.
    #
    # The snapshot is deeply frozen: a session pins `snapshot_digest` and a
    # changed server can only ever produce a *candidate* catalog.
    Catalog = Data.define(:server_id, :protocol_version, :entries, :snapshot_digest) do
      DIGEST_DOMAIN = "tamoz.mcp.catalog.v1\n"
      ENTRY_DIGEST_DOMAIN = "tamoz.mcp.catalog.entry.v1\n"
      TOOL_NAME_PATTERN = /\A[A-Za-z\d_\-.]{1,128}\z/

      # One catalogued capability. `annotations` (when present) are parsed but
      # are always author-claimed server metadata — never local policy.
      Entry = Data.define(:name, :kind, :description, :schema, :annotations, :definition_digest)

      class << self
        # `client_factory:` receives the Supervisor and returns the MCP client
        # (tests inject fakes; the default uses the official SDK client).
        def compile(config, client_factory: nil)
          unless config.is_a?(ServerConfig)
            raise ValidationError, "config must be a Tamoz::Mcp::ServerConfig"
          end

          supervisor = build_supervisor(config)
          begin
            client = build_client(supervisor, client_factory)
            protocol_version = negotiate_protocol_version(client, config)
            entries = collect_entries(client, config)
            enforce_entry_budget!(entries, config)

            snapshot_digest = digest_snapshot(config.server_id, protocol_version, entries)
            new(
              server_id: config.server_id,
              protocol_version: protocol_version,
              entries: entries.freeze,
              snapshot_digest: snapshot_digest
            ).freeze
          ensure
            supervisor.close
          end
        end

        private

        def build_supervisor(config)
          config.transport == :http ? HttpSupervisor.new(config) : Supervisor.new(config)
        end

        def build_client(supervisor, client_factory)
          factory = client_factory || ->(sup) { MCP::Client.new(transport: sup) }
          factory.call(supervisor)
        end

        def negotiate_protocol_version(client, config)
          min, max = config.protocol_range
          result = ::Timeout.timeout(config.budgets.connect_timeout) do
            client.connect(client_info: CLIENT_INFO, protocol_version: max)
          end
          negotiated = result.is_a?(Hash) ? result["protocolVersion"] : nil
          validate_protocol_version_shape!(negotiated)
          validate_protocol_version_in_range!(negotiated, min, max)

          negotiated.freeze
        rescue ::Timeout::Error
          raise Tamoz::TimeoutError, "The MCP server handshake timed out."
        rescue MCP::Client::RequestHandlerError, MCP::Client::ServerError, MCP::Client::ValidationError
          raise ProtocolError, "The MCP server handshake failed."
        end

        def validate_protocol_version_shape!(negotiated)
          return if negotiated.is_a?(String) && PROTOCOL_VERSION_PATTERN.match?(negotiated)

          raise ProtocolError, "The MCP server returned an invalid protocol version."
        end

        def validate_protocol_version_in_range!(negotiated, min, max)
          return unless negotiated < min || negotiated > max

          raise ProtocolError,
                "The MCP server negotiated protocol version #{negotiated}, " \
                "outside the configured range #{min}..#{max}."
        end

        def collect_entries(client, config)
          admission = CatalogEntries.new
          entries = []
          entries.concat(admission.tool_entries(client, config)) if config.primitives.include?(:tools)
          entries.concat(admission.resource_entries(client, config)) if config.primitives.include?(:resources)
          entries.concat(admission.prompt_entries(client, config)) if config.primitives.include?(:prompts)
          entries
        rescue MCP::Client::RequestHandlerError, MCP::Client::ServerError, MCP::Client::ValidationError
          raise ProtocolError, "The MCP server failed while listing its catalog."
        end

        def enforce_entry_budget!(entries, config)
          return if entries.length <= config.budgets.max_catalog_entries

          raise ProtocolError,
                "The MCP server catalog has #{entries.length} entries, exceeding " \
                "the configured budget of #{config.budgets.max_catalog_entries}."
        end

        # --- tools ---------------------------------------------------------

        # --- resources / prompts (catalogued only; never readable in v1) ----

        # --- entry hygiene -------------------------------------------------

        # Names qualify every downstream identifier; a server name outside the
        # MCP tool-name charset fails the snapshot before it can reach a
        # message, a path, or a descriptor id.

        # Descriptions are untrusted display text: control characters are
        # stripped and the result is byte-bounded without splitting a UTF-8
        # sequence. Locale-independent: the encoding is named explicitly.

        # --- digests -------------------------------------------------------

        def digest_snapshot(server_id, protocol_version, entries)
          payload = DIGEST_DOMAIN + CanonicalJSON.dump(
            "server_id" => server_id,
            "protocol_version" => protocol_version,
            "entries" => entries.map(&:definition_digest)
          )
          "sha256:#{Digest::SHA256.hexdigest(payload)}"
        end

      end
    end
  end
end
