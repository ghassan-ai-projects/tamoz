# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # Durable memory for CLI sessions, and `tamoz memory` for the operator. Memory exists only
    # when the runtime directory enables the `memory` source; it lives in the runtime database, so
    # CLI sessions and every channel the worker serves share it.
    module CLIMemoryCommands
      MAX_CONSOLIDATION_GROUPS = 5
      NOT_FOUND = 'tamoz: no remembered item %s in this project'

      private

      # [engine, owner] or nil. The caller closes the engine.
      def open_memory(options)
        directory = memory_directory(options)
        return nil unless directory

        settings = directory.source_settings('memory')
        [Memory::Engine.open(path: directory.database_path, tenant: settings['tenant'] || 'default',
                             lease_ttl: @sessions.lease_ttl),
         settings['owner'] || 'operator']
      end

      def memory_directory(options)
        path = options[:runtime_dir] || @env['TAMOZ_RUNTIME_DIR']
        return nil unless path

        directory = RuntimeDirectory.resolve(path:, env: @env)
        directory.enabled_sources.include?('memory') ? directory : nil
      end

      def cmd_memory(options, argv)
        action = argv.shift
        require 'tamoz/sqlite'
        engine, owner = open_memory(options)
        unless engine
          @err.puts 'tamoz: sources.memory is not enabled in the runtime config (--runtime-dir)'
          return 1
        end

        run_memory_action(action, argv, engine.access(owner:, workspace: memory_root(options)), options)
      ensure
        engine&.close
      end

      # The same root the session's toolbox uses, so the project scope matches.
      def memory_root(options)
        return load_operator_profile(options).canonical_root if options[:profile]

        options[:root] || Dir.pwd
      end

      def run_memory_action(action, argv, access, options)
        case action
        when 'list' then list_memory(access, argv.join(' '))
        when 'show' then show_memory(access, argv.fetch(0))
        when 'forget' then forget_memory(access, argv.fetch(0))
        when 'consolidate' then consolidate_memory(access, options)
        else
          @err.puts 'usage: tamoz memory list [QUERY] | show ID | forget ID | consolidate'
          2
        end
      end

      def list_memory(access, query)
        records = access.list(query)
        records.each do |record|
          @out.puts "#{record.memory_id} v#{record.record_version} #{record.layer} #{record.klass}"
        end
        @out.puts '(no remembered items)' if records.empty?
        0
      end

      def show_memory(access, id)
        record = access.find(id)
        return 1.tap { @err.puts format(NOT_FOUND, id) } unless record

        0.tap { @out.puts JSON.pretty_generate(record.to_h) }
      end

      # The operator is the authority here; the user-quote rule is for the model's tools.
      def forget_memory(access, id)
        receipt = access.delete(id)
        return 1.tap { @err.puts format(NOT_FOUND, id) } unless receipt

        0.tap { @out.puts JSON.pretty_generate(receipt) }
      end

      def consolidate_memory(access, options)
        results = access.consolidate(model: @models.build(options), context: consolidation_context,
                                     limit: MAX_CONSOLIDATION_GROUPS)
        0.tap { @out.puts JSON.pretty_generate('groups' => results.length, 'results' => results) }
      end

      def consolidation_context
        id = SecureRandom.uuid
        Runtime::EffectContext.new(effects: Runtime::EffectsJournal.new, execution_id: "memory.consolidate.#{id}",
                                   task_id: 'memory.consolidate', request_id: id)
      end
    end
  end
end
