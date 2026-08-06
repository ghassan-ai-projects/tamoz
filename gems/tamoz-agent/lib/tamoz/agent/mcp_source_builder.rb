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
        configs = server_configs
        return nil if configs.empty?

        require "tamoz/mcp"

        catalogs = {}
        descriptors = []
        supervisors = {}

        configs.each do |config, settings|
          snapshot = Tamoz::Mcp::Catalog.compile(config)
          catalogs[snapshot.server_id] = snapshot
          supervisors[snapshot.server_id] = Tamoz::Mcp::Supervisor.new(config)
          read_only = Array(settings["read_only_tools"])
          snapshot.entries.each do |entry|
            descriptors << Tamoz::Mcp::Invocation.descriptor_for(
              entry,
              snapshot:,
              # Fail closed: only a tool the OPERATOR named is read-only.
              effect_class: read_only.include?(entry.name) ? :read_only : :unknown_effects
            )
          end
        end

        McpCapabilitySource.new(
          catalogs:,
          descriptors:,
          executor: build_executor(catalogs, supervisors)
        )
      end

      private

      # The executor dispatches a descriptor to the supervisor that owns its
      # server. It resolves the snapshot by the descriptor's OWN source id, so a
      # descriptor can never be executed against a different server's transport.
      def build_executor(catalogs, supervisors)
        lambda do |descriptor, arguments, _context|
          server_id = descriptor.source_id
          snapshot = catalogs.fetch(server_id) do
            raise Error, "no pinned catalog for MCP server #{server_id.inspect}"
          end
          supervisor = supervisors.fetch(server_id) do
            raise Error, "no supervisor for MCP server #{server_id.inspect}"
          end
          Tamoz::Mcp::Invocation.call(descriptor, arguments, snapshot:, supervisor:)
        end
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
        missing = REQUIRED_KEYS.reject { |key| settings[key].is_a?(String) && !settings[key].empty? }
        unless missing.empty?
          raise Error, "MCP server #{server_id.inspect} is missing #{missing.join(", ")}"
        end

        Tamoz::Mcp::ServerConfig.new(
          server_id:,
          transport: :stdio,
          command: settings.fetch("command"),
          arguments: Array(settings["arguments"]),
          # The subprocess sees only what the operator listed. An empty allowlist
          # means an empty environment, which is the right default for something
          # that will be handed a network capability.
          env_allowlist: Array(settings["env_allowlist"]),
          # Two different directories, and the MCP gem refuses to let them be the
          # same one. `workspace_root` is the tree the AGENT edits; the server
          # runs somewhere else — the runtime directory by default — so a server
          # process never has the tree under repair as its cwd.
          working_directory: settings["working_directory"] || @directory.path,
          workspace_root: @directory.workspace_root
        )
      rescue Tamoz::Mcp::ValidationError => error
        raise Error, "MCP server #{server_id.inspect} is misconfigured: #{error.message}"
      end
    end
  end
end
