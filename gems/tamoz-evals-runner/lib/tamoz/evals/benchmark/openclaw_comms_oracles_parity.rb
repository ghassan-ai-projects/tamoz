# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # Cross-surface parity over ONE durable thread reachable from both
      # surfaces: the telegram leg and the durable-CLI leg are compared on
      # MEANING — the Lifecycle vocabulary each surface's internal state
      # translates to, whether each surface's reference resolves to its own
      # executed request row, the terminal reason, and history under the
      # confirmed-deliveries rule — never on rendered bytes.
      module OpenclawCommsOracles
        module_function

        CORE_PARITY_FACTS = %w[lifecycle_vocabulary reference_resolution
                               terminal_reason history_confirmed_deliveries].freeze

        def unavailable_edge(fact, reason)
          { 'fact' => fact, 'status' => 'unavailable', 'reason' => reason }
        end

        def paired_legs(facts)
          cli = facts.fetch('cli_legs', [])
          facts.fetch('telegram_legs', []).filter_map do |telegram|
            partner = cli.find { |leg| leg['conversation_id'] == telegram['conversation_id'] }
            next nil unless partner

            [telegram, partner]
          end
        end

        def lifecycle_vocabulary(facts)
          pairs = paired_legs(facts)
          return FAIL if pairs.empty?

          matched = task_words_match?(pairs)
          agreed = delivery_words_agree?(pairs)
          pass_if(matched && agreed)
        rescue Tamoz::Comms::ValidationError
          FAIL
        end

        def task_words_match?(pairs)
          pairs.all? do |telegram, cli|
            telegram_word = leg_task_word(telegram)
            !telegram_word.nil? && telegram_word == leg_task_word(cli)
          end
        end

        def delivery_words_agree?(pairs)
          deliveries = pairs.flat_map do |telegram, cli|
            [delivery_word(telegram['delivery_state']), delivery_word(cli['delivery_state'])]
          end
          deliveries.uniq.length == 1 && deliveries.first != 'none'
        end

        def leg_task_word(leg)
          state = leg['request_status']
          return nil if state.to_s.empty?

          task_word(state)
        end

        def reference_resolution(facts)
          pairs = paired_legs(facts)
          return FAIL if pairs.empty?

          resolved = pairs.all? do |telegram, cli|
            leg_reference_resolves?(facts, telegram) && leg_reference_resolves?(facts, cli)
          end
          pass_if(resolved)
        end

        def leg_reference_resolves?(_facts, leg)
          leg['request_row_present'] &&
            leg['reference'] == Tamoz::Comms::Lifecycle::RequestRef.for(leg['request_id'])
        end

        def terminal_reason(facts)
          pairs = paired_legs(facts)
          return FAIL if pairs.empty?

          agreed = pairs.all? do |telegram, cli|
            reason = telegram['terminal_reason'].to_s
            !reason.empty? && reason == cli['terminal_reason'].to_s
          end
          pass_if(agreed)
        end

        def history_confirmed_deliveries(facts)
          conversations = paired_legs(facts).map { |telegram, _| telegram['conversation_id'] }
          return FAIL if conversations.empty?

          conversations.all? { |conversation| context_inclusion(facts, conversation) == PASS } ? PASS : FAIL
        end

        def core_parity_compared(facts)
          {
            'lifecycle_vocabulary' => lifecycle_vocabulary(facts),
            'reference_resolution' => reference_resolution(facts),
            'terminal_reason' => terminal_reason(facts),
            'history_confirmed_deliveries' => history_confirmed_deliveries(facts)
          }
        end

        def core_parity_document(facts, extra_edges: [])
          compared = core_parity_compared(facts)
          edges = extra_edges + [cli_visibility_edge] + [
            unavailable_edge('conversation_scoped_cli_reference',
                             'a CLI-submitted request has no comms conversation scope, so ' \
                             'store.request_status cannot resolve it; thread-scoped resolution is compared instead')
          ]
          scored_parity(compared, edges)
        end

        def scored_parity(compared, edges)
          {
            'status' => 'scored',
            'compared' => compared,
            'score' => compared.value?(FAIL) ? FAIL : PASS,
            'edges' => edges
          }
        end

        # The conversation projection counts comms-admitted requests only, so
        # CLI-queued work has no /status or /cancel expression at the command
        # layer; parity therefore compares thread-scoped durable facts.
        def cli_visibility_edge
          unavailable_edge('cli_queued_work_conversation_visibility',
                           'the conversation projection sees comms-admitted requests only, so the ' \
                           '/status and /cancel command guards cannot express CLI-queued work')
        end
      end
    end
  end
end
