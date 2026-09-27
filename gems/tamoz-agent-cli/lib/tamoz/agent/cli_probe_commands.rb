# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # `tamoz probes`: load and validate the operator's probe catalog and list it, without starting any server.
    module CLIProbeCommands
      private

      def cmd_probes(options, _argv)
        directory = RuntimeDirectory.resolve(path: options[:runtime_dir], env: @env)
        unless directory.enabled_sources.include?('probes')
          @err.puts 'tamoz: sources.probes is not enabled in the runtime config'
          return 1
        end

        catalog = ProbeCatalog.new(directory.source_settings('probes'), servers: probe_servers(directory))
        options[:json] ? @out.puts(JSON.generate(probe_document(catalog))) : render_probes(catalog)
        0
      end

      def probe_servers(directory)
        Array(directory.source_settings('mcp')['servers']).to_h { |settings| [settings['id'], settings] }
      end

      def probe_document(catalog)
        { 'digest' => catalog.digest, 'targets' => catalog.targets.keys,
          'probes' => catalog.probes.values.map { |probe| probe.to_h.transform_keys(&:to_s) } }
      end

      def render_probes(catalog)
        @out.puts "Probe catalog #{catalog.digest}"
        @out.puts "Targets: #{catalog.targets.keys.join(', ')}"
        catalog.probes.each_value do |probe|
          free = probe.free.map { |name, slot| "#{name} (#{slot.fetch('free')})" }
          @out.puts "#{probe.name}  reads #{probe.backing_id}  pinned: #{probe.pinned.keys.join(', ')}  " \
                    "free: #{free.empty? ? '-' : free.join(', ')}"
        end
      end
    end
  end
end
