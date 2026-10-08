# frozen_string_literal: true

require 'json'

module Tamoz
  module Agent
    # A research subagent's web tools: the model names a search result by its ref (S2-3), never a URL.
    # :reek:ControlParameter :reek:DataClump :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:TooManyStatements
    # :reek:UncommunicativeVariableName :reek:UtilityFunction -- each method reshapes one tool call against the
    # child's state that call names.
    class WorkWeb
      # Answered here without the approval gate: it only reads what this turn already recorded.
      FINISH = 'report_sources'

      READ_URL = 'read_url'
      # The source a succeeded web_search result is recorded under: the only tool output read_url trusts.
      SEARCHED = 'web_search'
      URL = %r{(?:https?://)?(?:[A-Za-z0-9-]+\.)+[A-Za-z]{2,}(?::\d+)?(?:/[^\s<>"'`]*)?}i
      UNSOURCED = 'is not a URL the user wrote in this conversation or a web_search in this turn returned; ' \
                  'search for it first'

      def initialize(work:, memory:)
        @work = work
        @memory = memory
        @backings = Harness::ResearchPack.web_backings
        freeze
      end

      def web?(name) = @backings.key?(name)

      # Only a research child's web calls spend a budget and record refs.
      def budgeted?(state, call) = !state[:research].nil? && web?(call['shown_name'])

      # The call as the capability takes it, or with an error when it names nothing it may read.
      def resolve(state, context, call)
        name = call.fetch('name')
        backing = @work.remote_tools[name]
        return remote(state, context, call, backing) if backing
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
        ["Error: #{e.message}", charged(state, shown_name)]
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

      def remote(state, context, call, backing)
        backed = call.merge('name' => backing, 'shown_name' => call.fetch('name'))
        return backed unless call.fetch('name') == READ_URL

        url = String(call.fetch('arguments')['url'])
        admitted = admitted_url(state, context, url)
        return call.merge('error' => "#{url.inspect} #{UNSOURCED}") unless admitted

        backed.merge('arguments' => { 'url' => admitted })
      end

      # A URL the model composed could carry the conversation out in its path or query, so read_url reads only a URL
      # the user wrote or a succeeded web_search returned, matched whole, and sends that URL rather than the model's.
      def admitted_url(state, context, url)
        wanted = key(url)
        (user_urls(state, context) + search_urls(state)).find { |candidate| key(candidate) == wanted }
      end

      def key(url) = url.strip.sub(%r{\Ahttps?://}i, '').chomp('/')

      def user_urls(state, context)
        @memory.user_messages(state, context).flat_map { |text| text.scan(URL) }.map do |url|
          url = url.sub(/[.,;:!?)\]}'"]+\z/, '')
          url.match?(%r{\Ahttps?://}i) ? url : "https://#{url}"
        end
      end

      def search_urls(state)
        state.fetch(:work_entries).flat_map do |entry|
          next [] unless entry['source'] == SEARCHED && entry['text_ref']

          results = Array(JSON.parse(@work.resolve.call(entry.fetch('text_ref')))['results'])
          results.filter_map { |result| result['url'] if result.is_a?(Hash) }.grep(String)
        rescue JSON::ParserError
          []
        end
      end

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
