# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # C3 (ambiguous delivery) and C4 (restart safety) oracles of the comms scenario set.
      module OpenclawCommsOracles
        module_function

        # C4 ----------------------------------------------------------------

        def c4(facts, conversation:)
          effects = facts['effects'].map { |row| row['effect_key'] }
          unique_effects = effects.uniq == effects
          answer_sends = facts['sends'].count { |send| send['kind'] == 'answer' }
          unique_terminal = c4_unique_terminal?(facts, answer_sends)
          restart_safety = pass_if(unique_effects && unique_terminal && facts['boundaries_executed'].length >= 3)
          {
            'metrics' => c4_metrics(facts, conversation, restart_safety, answer_sends),
            'hard_zero' => {
              'duplicate_effect' => passed_if(unique_effects),
              'duplicate_terminal_send' => passed_if(unique_terminal),
              'blind_retry_after_unknown' => passed_if(answer_sends <= 1)
            }
          }
        end

        def c4_unique_terminal?(facts, answer_sends)
          facts['outbox'].count { |row| row['kind'] == 'answer' } == answer_sends
        end

        def c4_metrics(facts, conversation, restart_safety, answer_sends)
          {
            'restart_safety' => restart_safety,
            'reference_stability' => requests_for(facts, conversation).length == 1 &&
              reference_stability(facts, conversation),
            'no_blind_retry' => pass_if(answer_sends <= 1),
            'completion' => completion(facts, conversation),
            'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture')
          }
        end

        # C3 ----------------------------------------------------------------

        def c3(facts)
          unknown_rows = facts['outbox'].select { |row| row['status'] == 'unknown' }
          unknown_preserved = facts['unknown_preserved_no_resend'] == true
          no_blind = c3_no_blind_retry?(facts)
          {
            'metrics' => c3_metrics(facts, unknown_rows, unknown_preserved, no_blind),
            'hard_zero' => c3_hard_zero(facts, unknown_rows, unknown_preserved, no_blind)
          }
        end

        def c3_no_blind_retry?(facts)
          answer_sends = facts['sends'].count { |send| send['kind'] == 'answer' }
          answer_sends <= facts['outbox'].count { |row| row['kind'] == 'answer' }
        end

        def c3_failed_auth_row(facts)
          facts['outbox'].find do |row|
            row['status'] == 'failed' && row['receipt'].to_s.include?('authentication_refused')
          end
        end

        def c3_metrics(facts, unknown_rows, unknown_preserved, no_blind)
          {
            'no_blind_retry' => pass_if(no_blind),
            'unknown_preservation' => pass_if(
              unknown_rows.length >= 1 && unknown_rows.first['receipt'].nil? && unknown_preserved
            ),
            'owner_fencing' => pass_if(facts['stale_owner_mark_refused'] == true),
            'delivery_axis' => pass_if(facts['throttle_then_delivered'] == true && c3_failed_auth_row(facts))
          }
        end

        def c3_hard_zero(facts, unknown_rows, unknown_preserved, no_blind)
          {
            'blind_retry_after_unknown' => passed_if(unknown_preserved && no_blind),
            'stale_owner_send' => passed_if(facts['stale_owner_mark_refused'] == true),
            # An ambiguous delivery is preserved as unknown with NO confirmation:
            # a receipt is the terminal proof, so an unknown row that carries one
            # has been reported as a settled outcome it never had.
            'unknown_reported_as_terminal' => failed_if(unknown_rows.any? { |row| !row['receipt'].nil? })
          }
        end
      end
    end
  end
end
