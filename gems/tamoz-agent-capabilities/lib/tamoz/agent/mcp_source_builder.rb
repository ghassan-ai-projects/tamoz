# frozen_string_literal: true

module Tamoz
  module Agent
    # Builds the governed MCP capability source from OPERATOR configuration.
    #
    # Websearch is not a separate mechanism: it is an MCP server whose id is the
    # reserved `websearch`, which is what makes it one of the four closed-world
    # capability sources rather than a fifth. One builder therefore serves both,
    # and `sources.websearch` is sugar for "an MCP server called websearch".
    #
    # Three rules hold throughout, and they are the reason this file exists at all
    # rather than the worker calling the MCP gem directly:
    #
    #   1. The catalog is PINNED. `Catalog.compile` produces a content-addressed
    #      snapshot at construction and the session records its digest. A server
    #      that changes its tool list afterwards does not silently change what the
    #      agent may do — the resume guard fails closed.
    #
    #   2. Risk classification is OPERATOR POLICY, never server metadata. A server
    #      describes its tools; it does not get to say how dangerous they are. Any
    #      tool the operator has not explicitly listed as read-only is treated as
    #      `:unknown_effects`, which is the fail-closed direction.
    #
    #   3. Nothing here reads the workspace. The server list, the commands, the
    #      environment allowlist and the risk classification all come from the
    #      runtime directory.
    class McpSourceBuilder
      class Error < Tamoz::Agent::Error; end

      WEBSEARCH_SERVER_ID = "websearch"

      SOURCE_DIGEST_PREFIX = "tamoz.agent.mcp.source.v1\n"
      PEEK_DIGEST_PREFIX = "tamoz.agent.mcp.peek.v1\n"
      PEEK_REVISION_PREFIX = "tamoz.agent.mcp.peek.revision.v1\n"

      # An MCP server is a subprocess. That is a bigger step than enabling a
      # local capability, so the configuration is explicit about every part of it
      # and nothing is inferred from the environment.
      REQUIRED_KEYS = %w[command].freeze

      def initialize(directory)
        @directory = directory
      end

      # The composed source, or nil when the operator configured no servers.
      #
      # Returns nil rather than an empty source so `Session.new(mcp: nil)` keeps
      # its exact pre-existing behaviour when MCP is off.
      def build
        require "tamoz/mcp"

        state = {
          catalogs: {}, descriptors: [], supervisors: {}, source_digests: {}, database_policies: {}
        }
        configs = server_configs
        return nil if configs.empty?

        begin
          configs.each do |config, settings|
            build_server(config, settings, state)
          end

          compose_source(state)
        rescue StandardError
          state.fetch(:supervisors).each_value(&:close)
          raise
        end
      end

      def build_server(config, settings, state)
        record_source_digest!(config, state)
        snapshot = Tamoz::Mcp::Catalog.compile(config)
        state.fetch(:catalogs)[snapshot.server_id] = snapshot
        state.fetch(:supervisors)[snapshot.server_id] = Tamoz::Mcp::Supervisor.build(config)
        record_database_policy!(config.server_id, settings, state)
        append_descriptors(state.fetch(:descriptors), snapshot, settings)
      end

      def append_descriptors(descriptors, snapshot, settings)
        read_only = Array(settings["read_only_tools"])
        snapshot.entries.each do |entry|
          descriptors << Tamoz::Mcp::Invocation.descriptor_for(
            entry,
            snapshot:,
            effect_class: effect_class_for(entry, read_only)
          )
        end
      end

      # Read-only configuration inspection. This validates the operator-owned
      # server declarations but never compiles a catalog or starts a supervisor.
      def peek
        require "tamoz/mcp"

        rows = server_configs.map { |config, settings| peek_row(config, settings) }.freeze
        {
          "revision" => Tamoz::Core.digest(PEEK_REVISION_PREFIX, rows),
          "sources" => rows
        }.freeze
      end

      private

      # The executor dispatches a descriptor to the supervisor that owns its
      # server. It resolves the snapshot by the descriptor's OWN source id, so a
      # descriptor can never be executed against a different server's transport.
      def build_executor(catalogs, supervisors, database_policies)
        lambda do |_context, descriptor, arguments|
          server_id = descriptor.source_id
          snapshot = catalogs.fetch(server_id) do
            raise Error, "no pinned catalog for MCP server #{server_id.inspect}"
          end
          supervisor = supervisors.fetch(server_id) do
            raise Error, "no supervisor for MCP server #{server_id.inspect}"
          end
          with_mcp_error_mapping do
            policy = database_policies.fetch(descriptor.source_id, nil)
            validated_arguments = policy ? policy.validate(arguments) : arguments
            Tamoz::Mcp::Invocation.call(descriptor, validated_arguments, snapshot:, supervisor:)
          end
        end
      end

      def database_policy(server_id, settings)
        raw = settings["database"]
        return nil unless raw

        options = raw == true ? {} : raw
        unless options.is_a?(Hash)
          raise Error, "MCP database settings for #{server_id.inspect} must be a mapping"
        end

        GovernedDatabaseSource.policy(
          server_id:,
          max_rows: options.fetch("max_rows", GovernedDatabaseSource::MAX_ROWS)
        )
      end

      def with_mcp_error_mapping
        yield
      rescue Tamoz::Mcp::Error => error
        mapped = map_mcp_error(error)
        raise mapped if mapped

        raise
      end

      def map_mcp_error(error)
        case error
        when Tamoz::Mcp::ToolArgumentError
          Tamoz::Agent::ToolArgumentError.new(error.message)
        when Tamoz::Mcp::ToolPolicyError, Tamoz::Mcp::CircuitPolicyError,
             Tamoz::Mcp::ProtocolError, Tamoz::Mcp::ValidationError
          Tamoz::Agent::ToolPolicyError.new(error.message)
        when Tamoz::Mcp::UnavailableError
          Tamoz::Agent::ToolError.new(error.message)
        when Tamoz::Mcp::CatalogSnapshotUnavailableError
          Tamoz::Agent::McpCatalogSnapshotUnavailableError.new(error.message)
        when Tamoz::Mcp::AmbiguousOutcomeError
          Tamoz::EffectUnknownError.new(error.message)
        end
      end

      def compose_source(state)
        McpCapabilitySource.new(
          catalogs: state.fetch(:catalogs),
          descriptors: state.fetch(:descriptors),
          source_digests: state.fetch(:source_digests),
          validator: build_validator(state.fetch(:database_policies)),
          executor: build_executor(
            state.fetch(:catalogs), state.fetch(:supervisors), state.fetch(:database_policies)
          ),
          closer: -> { state.fetch(:supervisors).each_value(&:close) }
        )
      end

      def build_validator(database_policies)
        lambda do |descriptor, arguments|
          with_mcp_error_mapping do
            database_policies.fetch(descriptor.source_id, nil)&.validate(arguments)
            Tamoz::Mcp::Invocation.validate_arguments(descriptor, arguments)
          end
        end
      end

      def record_source_digest!(config, state)
        state.fetch(:source_digests)[config.server_id] = Tamoz::Core.digest(
          SOURCE_DIGEST_PREFIX, config.describe
        )
      end

      def record_database_policy!(server_id, settings, state)
        policy = database_policy(server_id, settings)
        state.fetch(:database_policies)[server_id] = policy if policy
      end

      def effect_class_for(entry, read_only_tools)
        read_only_tools.include?(entry.name) ? :read_only : :unknown_effects
      end

      def peek_row(config, settings)
        {
          "source_id" => peek_source_id(config),
          "server_id" => config.server_id,
          "transport" => config.transport.to_s,
          "configured" => true,
          "catalogued" => false,
          "materialized" => false,
          "reachable" => false,
          "verified" => false,
          "effective" => false,
          "reason" => "unmaterialized",
          "read_only_tools" => Array(settings["read_only_tools"]).map(&:to_s).sort.freeze,
          "config_digest" => Tamoz::Core.digest(PEEK_DIGEST_PREFIX, config.describe)
        }.freeze
      end

      def peek_source_id(config)
        if config.server_id == WEBSEARCH_SERVER_ID
          "websearch:#{config.server_id}"
        else
          "mcp:#{config.server_id}"
        end
      end

      def validate_server_settings!(server_id, settings, transport)
        required = transport == :http ? %w[endpoint] : REQUIRED_KEYS
        missing = required.reject { |key| settings[key].is_a?(String) && !settings[key].empty? }
        return if missing.empty?

        raise Error, "MCP server #{server_id.inspect} is missing #{missing.join(", ")}"
      end

      def config_arguments_for(server_id, settings, transport)
        {
          server_id:,
          transport:,
          command: settings["command"],
          arguments: Array(settings["arguments"]),
          env_allowlist: Array(settings["env_allowlist"]),
          credential_refs: Array(settings["credential_refs"]),
          endpoint: settings["endpoint"],
          allow_insecure_http: settings.fetch("allow_insecure_http", false),
          headers: settings["headers"] || {},
          credential_headers: settings["credential_headers"] || {},
          working_directory: transport == :stdio ? (settings["working_directory"] || @directory.path) : nil,
          workspace_root: @directory.workspace_root
        }
      end

      # [[ServerConfig, settings], ...] for every server the operator enabled.
      def server_configs
        entries = []
        entries.concat(mcp_servers)
        websearch = websearch_server
        entries << websearch if websearch
        entries
      end

      def mcp_servers
        return [] unless @directory.enabled_sources.include?("mcp")

        Array(@directory.source_settings("mcp")["servers"]).map do |settings|
          unless settings.is_a?(Hash)
            raise Error, "sources.mcp.servers entries must be mappings"
          end

          server_id = settings["id"]
          if server_id == WEBSEARCH_SERVER_ID
            raise Error, "#{WEBSEARCH_SERVER_ID.inspect} is reserved; configure it under sources.websearch"
          end

          [config_for(server_id, settings), settings]
        end
      end

      def websearch_server
        return nil unless @directory.enabled_sources.include?("websearch")

        settings = @directory.source_settings("websearch")
        [config_for(WEBSEARCH_SERVER_ID, settings), settings]
      end

      def config_for(server_id, settings)
        transport = (settings["transport"] || "stdio").to_sym
        validate_server_settings!(server_id, settings, transport)

        Tamoz::Mcp::ServerConfig.new(**config_arguments_for(server_id, settings, transport))
      rescue Tamoz::Mcp::ValidationError => error
        raise Error, "MCP server #{server_id.inspect} is misconfigured: #{error.message}"
      end
    end
  end
end
