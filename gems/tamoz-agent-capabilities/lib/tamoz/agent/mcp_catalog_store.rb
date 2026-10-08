# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # The last catalog each MCP server answered with, kept in the runtime directory so a server that is down
    # still has its tools planned; the call itself then reaches the server or fails as a tool error.
    class McpCatalogStore
      DIRECTORY = 'mcp-catalogs'
      DIGEST_PREFIX = "tamoz.agent.mcp.catalog-store.v1\n"

      def initialize(runtime_path)
        @path = File.join(runtime_path, DIRECTORY)
      end

      def fetch(config)
        document = JSON.parse(File.read(file(config), encoding: Encoding::UTF_8))
        return nil unless document.is_a?(Hash) && document['config_digest'] == config_digest(config)

        Tamoz::Mcp::Catalog.from_h(document['catalog'], config)
      rescue Errno::ENOENT
        nil
      rescue JSON::ParserError, Tamoz::Mcp::Error, SystemCallError => e
        warn "tamoz: ignoring the stored catalog of MCP server #{config.server_id} (#{e.class.name.split('::').last})"
        nil
      end

      def store(config, snapshot)
        Tamoz::Core::PrivateDirectory.secure(@path)
        document = { 'config_digest' => config_digest(config), 'catalog' => snapshot.to_h }
        Tamoz::Core::AtomicFile.replace(file(config), JSON.generate(document), mode: 0o600)
      rescue SystemCallError => e
        warn "tamoz: could not store the catalog of MCP server #{config.server_id} (#{e.class.name.split('::').last})"
      end

      private

      def file(config) = File.join(@path, "#{config.server_id}.json")

      def config_digest(config) = Tamoz::Core.digest(DIGEST_PREFIX, config.describe)
    end
  end
end
