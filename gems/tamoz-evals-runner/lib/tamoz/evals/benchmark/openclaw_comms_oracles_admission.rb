# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # C1 (admission) and C2 oracles of the comms scenario set.
      module OpenclawCommsOracles
        module_function

        # C1 ----------------------------------------------------------------

        def c1(facts, conversation:)
          replied = facts['outbox'].any? { |row| row['conversation_id'] == conversation }
          admitted = c1_admitted?(facts, conversation)
          parity = core_parity_document(facts)
          {
            'metrics' => c1_metrics(facts, conversation, admitted, parity),
            'hard_zero' => c1_hard_zero(facts, conversation, admitted, replied),
            'parity' => parity
          }
        end

        def c1_admitted?(facts, conversation)
          dispositions(facts, facts['driven_update_ids'].first) == [%w[request accepted]] &&
            !requests_for(facts, conversation).empty?
        end

        def c1_metrics(facts, conversation, admitted, parity)
          {
            'admitted' => pass_if(admitted),
            'reference_stability' => reference_stability(facts, conversation),
            'completion' => completion(facts, conversation),
            'delivery_axis' => delivery_axis(facts, conversation),
            'context_inclusion' => context_inclusion(facts, conversation),
            'parity' => parity.fetch('score')
          }
        end

        def c1_hard_zero(facts, conversation, admitted, replied)
          {
            'reply_without_admission' => failed_if(!admitted && replied),
            'unconfirmed_output_in_history' => failed_if(unconfirmed_output_in_history?(facts, conversation)),
            'identity_conflict_deduplicated' => failed_if(identity_conflict?(facts))
          }
        end

        def delivery_axis(facts, conversation)
          answers = rows_of_kind(facts, 'answer').select { |row| row['conversation_id'] == conversation }
          return FAIL unless !answers.empty? && answers.all? { |row| row['status'] == 'succeeded' }

          task = task_word(facts.fetch('session').dig(conversation, 'status'))
          task == 'completed' && delivery_word(answers.last['status']) == 'delivered' ? PASS : FAIL
        end

        # C2 ----------------------------------------------------------------

        def c2(facts, conversation:)
          {
            'metrics' => {
              'liveness' => unavailable('liveness_is_the_typing_indicator_sent_while_a_worker_runs'),
              'context_inclusion' => context_inclusion(facts, conversation),
              'completion' => completion(facts, conversation),
              'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture'),
              'latency_to_ack' => unavailable('wall_clock_latency_not_fixture_controlled'),
              'latency_to_terminal' => unavailable('worker_wall_clock_not_fixture_controlled'),
              'update_count' => rows_of_kind(facts, 'answer').length
            },
            'hard_zero' => {
              'unconfirmed_output_in_history' => failed_if(unconfirmed_output_in_history?(facts, conversation))
            }
          }
        end
      end
    end
  end
end
