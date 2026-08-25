# frozen_string_literal: true

require "digest"
require "json"
require "timeout"

require "mcp"

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
          entries = []
          entries.concat(tool_entries(client, config)) if config.primitives.include?(:tools)
          entries.concat(resource_entries(client, config)) if config.primitives.include?(:resources)
          entries.concat(prompt_entries(client, config)) if config.primitives.include?(:prompts)
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

        def tool_entries(client, config)
          tools = client.tools
          seen = {}
          tools.map do |tool|
            name = validate_entry_name!(tool.name)
            record_unique_entry_name!(name, seen)

            description = bounded_description(tool.description, config)
            schema = canonicalize_schema(name, tool.input_schema)
            annotations = canonicalize_annotations(tool.annotations)
            build_entry(name, :tool, description, schema, annotations)
          end
        end

        def canonicalize_schema(name, schema)
          canonicalize(validated_schema_candidate(name, schema))
        end

        def validated_schema_candidate(name, schema)
          candidate = schema.nil? ? {} : schema
          unless candidate.is_a?(Hash)
            raise ValidationError,
                  "The MCP server entry #{name.inspect} has an invalid input schema."
          end

          begin
            MCP::Tool::InputSchema.new(candidate)
          rescue StandardError
            # Fail closed: an entry that fails schema validation fails the
            # whole snapshot (v1 simplification of the §5 quarantine rule).
            raise ValidationError,
                  "The MCP server entry #{name.inspect} has an invalid input schema."
          end

          candidate
        end

        # --- resources / prompts (catalogued only; never readable in v1) ----

        def resource_entries(client, config)
          client.resources.map do |resource|
            name = validate_entry_name!(resource["name"] || resource["uri"])
            description = bounded_description(resource["description"], config)
            schema = canonicalize(
              "uri" => resource["uri"].to_s, "mimeType" => resource["mimeType"].to_s
            )
            build_entry(name, :resource, description, schema, nil)
          end
        end

        def prompt_entries(client, config)
          client.prompts.map do |prompt|
            name = validate_entry_name!(prompt["name"])
            description = bounded_description(prompt["description"], config)
            schema = canonicalize("arguments" => prompt["arguments"] || [])
            build_entry(name, :prompt, description, schema, nil)
          end
        end

        # --- entry hygiene -------------------------------------------------

        # Names qualify every downstream identifier; a server name outside the
        # MCP tool-name charset fails the snapshot before it can reach a
        # message, a path, or a descriptor id.
        def validate_entry_name!(value)
          unless value.is_a?(String) && TOOL_NAME_PATTERN.match?(value)
            raise ValidationError, "The MCP server lists an entry with an invalid name."
          end

          value.dup.freeze
        end

        def record_unique_entry_name!(name, seen)
          if seen.key?(name)
            raise ValidationError, "The MCP server lists a duplicate entry name #{name.inspect}."
          end

          seen[name] = true
        end

        # Descriptions are untrusted display text: control characters are
        # stripped and the result is byte-bounded without splitting a UTF-8
        # sequence. Locale-independent: the encoding is named explicitly.
        def bounded_description(value, config)
          BoundedText.bound(value, config.budgets.max_description_bytes)
        end

        def canonicalize(object)
          CanonicalJSON.deep_freeze(CanonicalJSON.normalize(object))
        end

        def canonicalize_annotations(annotations)
          return nil if annotations.nil?

          canonicalize(annotations)
        end

        def build_entry(name, kind, description, schema, annotations)
          definition_digest = digest_entry(name, kind, description, schema, annotations)
          Entry.new(
            name: name,
            kind: kind,
            description: description,
            schema: schema,
            annotations: annotations,
            definition_digest: definition_digest
          ).freeze
        end

        # --- digests -------------------------------------------------------

        def digest_entry(name, kind, description, schema, annotations)
          payload = ENTRY_DIGEST_DOMAIN + CanonicalJSON.dump(
            "name" => name,
            "kind" => kind.to_s,
            "description" => description,
            "schema" => schema,
            "annotations" => annotations
          )
          "sha256:#{Digest::SHA256.hexdigest(payload)}"
        end

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
