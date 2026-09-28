# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # Durable memory for CLI sessions, and `tamoz memory` for the operator. Memory exists only
    # when the runtime directory enables the `memory` source; it lives in one file per session
    # directory, so every thread there shares it.
    module CLIMemoryCommands
      MEMORY_FILE = 'memory.sqlite3'
      MAX_CONSOLIDATION_GROUPS = 5

      # Whose memory, in which project: the operator's view is scoped like a session's.
      MemoryTarget = Data.define(:engine, :owner, :project) do
        def caller = engine.caller(user: owner, project:)

        def record(layer, id)
          found = engine.repository.fetch(engine.namespace, layer, id)&.fetch(:entry)&.value
          found if found && found.owner == owner && [project, '*'].include?(found.scopes['project'])
        end
      end

      private

      # [engine, owner, adapter] or nil. The caller closes the adapter.
      def open_memory(options, session_dir)
        directory = memory_directory(options)
        return nil unless directory

        settings = directory.source_settings('memory')
        adapter = Tamoz::SQLite::Adapter.new(path: File.join(session_dir, MEMORY_FILE),
                                             state_codec: Memory::Surface.codec,
                                             limits: Tamoz::SQLite::Limits.new(lease_ttl:))
        [Memory::Engine.new(tenant: settings['tenant'] || 'default', adapter:), settings['owner'] || 'operator',
         adapter]
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
        engine, owner, adapter = open_memory(options, provision_private_session_dir!(options))
        unless engine
          @err.puts 'tamoz: sources.memory is not enabled in the runtime config (--runtime-dir)'
          return 1
        end

        target = MemoryTarget.new(engine:, owner:, project: Memory::Surface.project_scope(memory_root(options)))
        run_memory_action(action, argv, target, options)
      ensure
        adapter&.close
      end

      # The same root the session's toolbox uses, so the project scope matches.
      def memory_root(options)
        return load_operator_profile(options).canonical_root if options[:profile]

        options[:root] || Dir.pwd
      end

      def run_memory_action(action, argv, target, options)
        case action
        when 'list' then list_memory(target, argv.join(' '))
        when 'show' then show_memory(target, argv.fetch(0))
        when 'forget' then forget_memory(target, argv.fetch(0))
        when 'consolidate' then consolidate_memory(target, options)
        else
          @err.puts 'usage: tamoz memory list [QUERY] | show ID | forget ID | consolidate'
          2
        end
      end

      def list_memory(target, query)
        rows = target.engine.repository.search(caller: target.caller,
                                               query: { terms: query.empty? ? [] : [query] }).candidates
        rows.each do |row|
          @out.puts "#{row.fetch('memory_id')} v#{row.fetch('record_version')} #{row.fetch('layer')} " \
                    "#{row.fetch('class')}"
        end
        @out.puts '(no remembered items)' if rows.empty?
        0
      end

      def show_memory(target, id)
        record = %w[knowledge experience].filter_map { |layer| target.record(layer, id) }.first
        return 1.tap { @err.puts "tamoz: no remembered item #{id} in this project" } unless record

        @out.puts JSON.pretty_generate(record.to_h)
        0
      end

      # The operator is the authority here; the user-quote rule is for the model's tools.
      def forget_memory(target, id)
        return 1.tap { @err.puts "tamoz: no remembered item #{id} in this project" } unless
          %w[knowledge experience].any? { |layer| target.record(layer, id) }

        receipt = target.engine.lifecycle.delete(memory_id: id, actor: 'operator', reason: 'operator forget')
        0.tap { @out.puts JSON.pretty_generate(receipt) }
      end

      # W3: groups of related Experience (at least two distinct sessions) become Knowledge
      # through the gated, journaled consolidation. A group already consumed is skipped.
      def consolidate_memory(target, options)
        groups = Memory::ExperienceGroups.for(target.engine, caller: target.caller, limit: MAX_CONSOLIDATION_GROUPS)
        model = build_model(options)
        results = groups.map { |group| consolidate_group(target, group, model) }
        @out.puts JSON.pretty_generate('groups' => groups.length, 'results' => results)
        0
      end

      def consolidate_group(target, group, model)
        owner = target.owner
        scopes = { 'tenant' => target.engine.tenant, 'user' => owner, 'project' => target.project,
                   'session' => 'consolidation' }
        consolidation = target.engine.consolidation
        candidate = consolidation.candidate_from(experiences: group, owner:, scopes:)
        result = consolidation.consolidate(candidates: [candidate], model:, owner:, scopes:,
                                           context: consolidation_context)
        { 'sources' => group.map(&:memory_id), 'knowledge' => result.record.memory_id }
      rescue Memory::MemoryConsolidationError => e
        { 'sources' => group.map(&:memory_id), 'skipped' => e.message }
      end

      def consolidation_context
        id = SecureRandom.uuid
        Runtime::EffectContext.new(effects: Runtime::EffectsJournal.new, execution_id: "memory.consolidate.#{id}",
                                   task_id: 'memory.consolidate', request_id: id)
      end
    end
  end
end
