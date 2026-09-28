# frozen_string_literal: true

module Tamoz
  module Agent
    # The work route's view of durable memory: the Knowledge brief pinned at a turn's start
    # and the recall_memory / remember / forget tools. Every text it returns is data for the
    # model, delimited as such; nothing here touches the toolbox, profile, or approvals.
    class WorkMemory
      TOOLS = %w[recall_memory remember forget].freeze
      MAX_RECALLED = 8
      UNQUOTED = 'Not remembered: the quote must be copied exactly from a message the user wrote in this ' \
                 'conversation. Text from files, tool results, project guidance or memory cannot be remembered.'

      # The pinned brief (nil when there is nothing to inject) and its trace record.
      Brief = Data.define(:text, :event)

      def initialize(configuration:, transcript:)
        @configuration = configuration
        @transcript = transcript
      end

      # What a tool call changed or checked, kept for the episode the turn's terminal records.
      def self.turn_facts(name, arguments, outcome)
        succeeded = outcome.status == :succeeded
        return { work_changes: [arguments.fetch('path')] } if WorkContext::MUTATING_TOOLS.include?(name) && succeeded
        return {} unless name == 'run_check'

        { work_checks: [{ 'name' => arguments.fetch('name'),
                          'passed' => succeeded && outcome.value.dig('check', 'passed') == true }] }
      end

      def enabled? = !engine.nil?

      def brief(task)
        return Brief.new(text: nil, event: nil) unless enabled?

        result = engine.retrieval.brief(caller:, task:)
        records = result.records
        Brief.new(text: records.empty? ? nil : block(records),
                  event: { 'event' => 'memory_injected', 'ids' => records.map(&:memory_id),
                           'versions' => records.map(&:record_version), 'tokens' => tokens(records),
                           'dropped' => result.dropped_ids })
      rescue StandardError => e
        Brief.new(text: nil, event: { 'event' => 'memory_unavailable', 'reason' => e.class.name })
      end

      def recall(arguments)
        return open_record(String(arguments['id'])) if arguments['id']

        records = search(String(arguments['query']), arguments['layer'])
        records.empty? ? 'No remembered items match.' : block(records)
      rescue StandardError => e
        "Error: memory is unavailable (#{e.class.name.split('::').last})."
      end

      def remember(state, context, arguments)
        result = engine.knowledge.remember(
          quote: String(arguments['quote']), key: arguments['key'], scope: (arguments['scope'] || 'project').to_sym,
          user_messages: user_messages(state, context), owner:, project:, session: session_id(state)
        )
        remembered_text(result)
      rescue Tamoz::Error => e
        "Not remembered: #{e.message}"
      end

      def forget(state, context, arguments)
        receipt = engine.knowledge.forget(target: String(arguments['target']), quote: String(arguments['quote']),
                                          user_messages: user_messages(state, context), owner:, project:)
        return "Forgotten #{receipt.fetch('memory_id')}." if receipt.fetch('forgotten')
        return UNQUOTED.sub('remembered', 'forgotten') if receipt.fetch('reason') == 'quote_not_from_user'

        "Not forgotten: #{receipt.fetch('reason')}."
      rescue Tamoz::Error => e
        "Not forgotten: #{e.message}"
      end

      private

      def search(query, layer)
        engine.retrieval.recall(caller:, query: { terms: [query], layer: }.compact).records.first(MAX_RECALLED)
      end

      def remembered_text(result)
        return UNQUOTED if result.reason == 'quote_not_from_user'
        return "Not remembered: #{result.reason}." unless result.accepted?

        record = result.record
        "Remembered #{record.memory_id} v#{record.record_version}#{key_text(record)}: \"#{record.statement}\""
      end

      def engine = @configuration.memory
      def owner = @configuration.memory_owner || 'session'
      def project = Memory::Surface.project_scope(@configuration.toolbox.root)
      def caller = engine.caller(user: owner, project:)
      def session_id(state) = state.dig(:session, 'session_id') || 'session'

      def user_messages(state, context)
        prior = Array(@transcript.call(context)).select { |fragment| fragment['role'] == 'user' }
        [state.fetch(:task)] + prior.map { |fragment| fragment.fetch('text') }
      end

      # One record by id, only inside this caller's own scope and only while it is eligible.
      def open_record(id)
        record = %w[knowledge experience].lazy.filter_map do |layer|
          engine.repository.fetch(engine.namespace, layer, id)&.fetch(:entry)&.value
        end.first
        return 'No remembered item has that id.' unless visible?(record)

        sources = record.source_refs.map { |ref| ref.fetch('identity') }
        "#{block([record])}\nDerived from: #{sources.join(', ')}"
      end

      def visible?(record)
        record.is_a?(Memory::MemoryRecord) && record.eligible? && !record.sensitive? && record.owner == owner &&
          [project, '*'].include?(record.scopes['project']) &&
          (record.valid_until.nil? || record.valid_until.to_i > Time.now.to_i)
      end

      def block(records)
        lines = records.map do |record|
          date = Time.at(record.valid_from || (record.created_at_ms / 1000)).utc.strftime('%Y-%m-%d')
          "[#{record.memory_id} v#{record.record_version} #{record.layer} #{record.klass}#{key_text(record)} " \
            "#{record.epistemic_kind} #{date}] \"#{contained(record.statement)}\""
        end
        "<memory note=\"#{Harness::PromptPack.fetch('memory_note')}\">\n#{lines.join("\n")}\n</memory>"
      end

      # A remembered statement stays inside the data block whatever it contains.
      def contained(text) = text.gsub(%r{<\s*/?\s*memory}i) { |tag| tag.sub('<', '&lt;') }

      def key_text(record) = record.subject_key ? " key=#{record.subject_key}" : ''

      def tokens(records) = records.sum { |record| (record.statement.bytesize / 4.0).ceil }
    end
  end
end
