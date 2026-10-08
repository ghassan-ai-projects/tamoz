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

      def enabled? = !access.nil?

      def brief(task)
        return Brief.new(text: nil, event: nil) unless enabled?

        result = access.brief(task)
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

        records = access.recall(String(arguments['query']), layer: arguments['layer'], limit: MAX_RECALLED)
        records.empty? ? 'No remembered items match.' : block(records)
      rescue StandardError => e
        "Error: memory is unavailable (#{e.class.name.split('::').last})."
      end

      def remember(state, context, arguments)
        result = access.remember(quote: String(arguments['quote']), key: arguments['key'],
                                 scope: (arguments['scope'] || 'project').to_sym,
                                 user_messages: user_messages(state, context), session: session_id(state))
        remembered_text(result)
      rescue Tamoz::Error => e
        "Not remembered: #{e.message}"
      end

      def forget(state, context, arguments)
        receipt = access.forget(target: String(arguments['target']), quote: String(arguments['quote']),
                                user_messages: user_messages(state, context))
        return "Forgotten #{receipt.fetch('memory_id')}." if receipt.fetch('forgotten')
        return UNQUOTED.sub('remembered', 'forgotten') if receipt.fetch('reason') == 'quote_not_from_user'

        "Not forgotten: #{receipt.fetch('reason')}."
      rescue Tamoz::Error => e
        "Not forgotten: #{e.message}"
      end

      # What the user wrote in this conversation: the turn's task and every earlier user message.
      def user_messages(state, context)
        prior = Array(@transcript.call(context)).select { |fragment| fragment['role'] == 'user' }
        [state.fetch(:task)] + prior.map { |fragment| fragment.fetch('text') }
      end

      private

      def remembered_text(result)
        return UNQUOTED if result.reason == 'quote_not_from_user'
        return "Not remembered: #{result.reason}." unless result.accepted?

        record = result.record
        "Remembered #{record.memory_id} v#{record.record_version}#{key_text(record)}: \"#{record.statement}\""
      end

      def access = @configuration.memory_access
      def session_id(state) = state.dig(:session, 'session_id') || 'session'

      def open_record(id)
        record = access.find(id)
        return 'No remembered item has that id.' unless record

        sources = record.source_refs.map { |ref| ref.fetch('identity') }
        "#{block([record])}\nDerived from: #{sources.join(', ')}"
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
