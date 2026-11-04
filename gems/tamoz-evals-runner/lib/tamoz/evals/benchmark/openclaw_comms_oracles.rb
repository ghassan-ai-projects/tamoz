# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # Deterministic, controller-owned oracles for the nine canonical comms
      # scenarios. Every oracle is a pure function of the durable-fact
      # snapshot the fixture recorded — request/outbox/inbound rows, status
      # projections, conversation history — never of
      # a self-report or a wall clock. The same snapshot always yields the
      # same scores.
      module OpenclawCommsOracles
        PASS = 1
        FAIL = 0

        module_function

        def pass_if(flag)
          flag ? PASS : FAIL
        end

        def passed_if(flag)
          flag ? 'passed' : 'failed'
        end

        def failed_if(flag)
          flag ? 'failed' : 'passed'
        end

        def unavailable(reason)
          { 'status' => 'unavailable', 'reason' => reason }
        end

        def rows_of_kind(facts, kind)
          kind ? facts['outbox'].select { |row| row['kind'] == kind } : facts['outbox']
        end

        def requests_for(facts, conversation_id)
          facts['requests'].select { |row| row['conversation_id'] == conversation_id }
        end

        def dispositions(facts, update_id)
          rows = facts['inbound'].select { |row| row['update_id'] == update_id }
          rows.map { |row| [row['disposition'], row['reason']] }
        end

        def task_word(internal_state)
          Tamoz::Comms::Lifecycle.task_state_for(internal_state || 'idle')
        rescue Tamoz::Comms::ValidationError
          internal_state.to_s
        end

        def delivery_word(outbox_status)
          return 'none' if outbox_status.nil?

          Tamoz::Comms::Lifecycle.delivery_state_for(outbox_status)
        end

        def assistant_entries(facts, conversation_id)
          facts.fetch('history').fetch(conversation_id, []).select { |entry| entry['role'] == 'assistant' }
        end

        TERMINAL_KINDS = %w[answer failed stopped blocked].freeze

        def confirmed_answer_texts(facts, conversation_id)
          confirmed = rows_of_kind(facts, nil).select do |row|
            row['conversation_id'] == conversation_id &&
              row['status'] == 'succeeded' && TERMINAL_KINDS.include?(row['kind'])
          end
          confirmed.map { |row| row['text'] }
        end

        # context_inclusion (invariant 11): only CONFIRMED successful terminal
        # deliveries entered history; progress/control never did.
        def context_inclusion(facts, conversation_id)
          assistants = assistant_entries(facts, conversation_id)
          confirmed = confirmed_answer_texts(facts, conversation_id)
          (assistants.map { |entry| entry['text'] } - confirmed).empty? ? PASS : FAIL
        end

        def completion(facts, conversation_id)
          session = facts.fetch('session').fetch(conversation_id, {})
          session['status'] == 'completed' && session['satisfied'] == true ? PASS : FAIL
        end

        def reference_stability(facts, conversation_id)
          requests = requests_for(facts, conversation_id)
          return FAIL unless requests.length == 1

          reference = requests.first.fetch('request_ref')
          projection = facts.fetch('request_projections')[reference]
          projection && projection['request_ref'] == reference ? PASS : FAIL
        end

        def identity_conflict?(facts)
          facts['inbound'].any? { |row| row['reason'] == 'integrity_conflict' }
        end

        def unconfirmed_output_in_history?(facts, conversation_id)
          assistants = assistant_entries(facts, conversation_id).map { |entry| entry['text'] }
          assistants != confirmed_answer_texts(facts, conversation_id)
        end
      end
    end
  end
end

require_relative 'openclaw_comms_oracles_admission'
require_relative 'openclaw_comms_oracles_durability'
require_relative 'openclaw_comms_oracles_commands'
require_relative 'openclaw_comms_oracles_boundaries'
require_relative 'openclaw_comms_oracles_parity'
require_relative 'openclaw_comms_oracles_cross_surface'
require_relative 'openclaw_comms_oracles_cancellation'
require_relative 'openclaw_comms_oracles_cancellation_timelines'
