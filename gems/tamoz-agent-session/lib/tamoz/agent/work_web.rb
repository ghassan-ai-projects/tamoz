# frozen_string_literal: true

module Tamoz
  module Agent
    # A research subagent's web tools: the model names a search result by its ref (S2-3), never a URL.
    # :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:TooManyStatements
    # :reek:UncommunicativeVariableName :reek:UtilityFunction
    class WorkWeb
      # Answered here without the approval gate: it only reads what this turn already recorded.
      FINISH = 'report_sources'

      def initialize(work:)
        @work = work
        @backings = Harness::ResearchPack.web_backings
        freeze
      end

      def web?(name) = @backings.key?(name)

      # The call as the capability takes it, or with an error when its ref names nothing this child searched.
      def resolve(state, call)
        name = call.fetch('name')
        return call unless web?(name)

        arguments = call.fetch('arguments')
        backed = call.merge('name' => @backings.fetch(name), 'shown_name' => name)
        return backed.merge('arguments' => arguments.slice('query', 'max_results')) if name == 'web_search'

        url = state.fetch(:research).fetch('hits')[arguments['ref']]
        return backed.merge('arguments' => { 'url' => url }) if url

        call.merge('error' => "#{arguments['ref'].inspect} is not a result of your searches; use a ref like S1-2")
      end

      # Why this call may not run: the wave's budget for it is spent.
      def refusal(state, call)
        research = state.fetch(:research)
        spent = call.fetch('shown_name') == 'web_search' ? %w[search_count searches] : %w[read_count page_reads]
        return nil if research.fetch(spent.first) < research.fetch(spent.last)

        "Error: your #{spent.last.tr('_', ' ')} budget is spent; finish with #{FINISH}."
      end

      # A failed search or read still spends the child's budget.
      def charged(state, shown_name)
        research = state.fetch(:research)
        key = shown_name == 'web_search' ? 'search_count' : 'read_count'
        research.merge(key => research.fetch(key) + 1)
      end

      # The rendered result the child reads, and the research state with its refs recorded.
      def observed(state, shown_name, output)
        research = state.fetch(:research)
        shown_name == 'web_search' ? searched(research, output) : read(research, output)
      rescue Tamoz::Research::Error => e
        ["Error: #{e.message}", research]
      end

      def report_sources(state, call)
        research = state.fetch(:research)
        pages = research.fetch('pages').to_h do |ref, stored|
          [ref, Tamoz::Research.page(@work.resolve.call(stored), ref:)]
        end
        sources = Tamoz::Research.sources(call.arguments, pages:, assigned: research.fetch('sub_questions'))
        verification = SessionRecords.build(
          'verification', answer: sources.render, satisfied: true, configured_check_passed: false,
                          evidence: ['every claim quotes a page this subagent read'], terminal_reason: 'reported',
                          report: sources.to_h
        )
        WorkTools::Outcome.new(text: 'Sources accepted.',
                               update: { verification:, terminal_reason: 'reported', next_node: 'terminal' })
      rescue Tamoz::Research::Error => e
        WorkTools::Outcome.new(text: e.message, update: {})
      end

      private

      def searched(research, output)
        ordinal = research.fetch('search_count') + 1
        hits = Tamoz::Research.search_hits(output, ordinal:)
        recorded = research.merge('search_count' => ordinal,
                                  'hits' => research.fetch('hits').merge(hits.to_h { |hit| [hit.ref, hit.url] }))
        [Tamoz::Research.render_hits(hits, ordinal:), recorded]
      end

      def read(research, output)
        ref = "P#{research.fetch('read_count') + 1}"
        page = Tamoz::Research.page(output, ref:)
        stored = ContextEngine::Surface.retain(@work.store, output)
        [Tamoz::Research.render_page(page),
         research.merge('read_count' => research.fetch('read_count') + 1,
                        'pages' => research.fetch('pages').merge(ref => stored))]
      end
    end
  end
end
