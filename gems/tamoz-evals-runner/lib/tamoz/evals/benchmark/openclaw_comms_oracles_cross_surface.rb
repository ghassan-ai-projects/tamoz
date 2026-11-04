# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # C6 (cross-surface parity) oracle and the C5 controls parity of the comms scenario set.
      module OpenclawCommsOracles
        module_function

        # Reference stability for scenarios that drive further turns after the
        # first admitted request: the FIRST telegram reference must still
        # resolve to its own row through the conversation projection.
        def first_reference_stable(facts, conversation)
          reference = facts['requests'].select { |row| row['conversation_id'] == conversation }
                                       .filter_map { |row| row['request_ref'] }.first
          return FAIL unless reference

          projection = facts.fetch('request_projections')[reference]
          projection.is_a?(Hash) && projection['request_ref'] == reference ? PASS : FAIL
        end

        # C6 ----------------------------------------------------------------

        def c6(facts, conversation:)
          document = core_parity_document(facts)
          parity_score = document.fetch('score')
          cancellation = cancellation_parity(facts)
          distinct_texts = facts['distinct_answer_texts'] == true
          {
            'metrics' => {
              'parity' => parity_score,
              'context_inclusion' => context_inclusion(facts, conversation),
              'reference_stability' => first_reference_stable(facts, conversation)
            },
            'hard_zero' => c6_hard_zero(parity_score, distinct_texts, cancellation),
            'parity' => document.merge(
              'cancellation' => { 'score' => cancellation,
                                  'observed' => facts.fetch('cancellations', []) },
              'distinct_answer_texts' => distinct_texts
            )
          }
        end

        def c6_hard_zero(parity_score, distinct_texts, cancellation)
          {
            'parity_by_text' => passed_if(distinct_texts && parity_score == PASS),
            'surface_outcome_divergence' => passed_if(parity_score == PASS),
            'one_sided_cancellation' => passed_if(cancellation == PASS)
          }
        end

        # A cancellation is one-sided when only the issuing surface can express
        # the outcome. The fixture cancels CLI-submitted work from the telegram
        # control path and CLI-side work from the CLI redirect path; both must
        # land the same durable payload and the same terminal reason, visible
        # as a delivered terminal row on the shared conversation.
        def cancellation_parity(facts)
          events = facts.fetch('cancellations', [])
          return FAIL if events.empty?

          consistent = events.all? do |event|
            event['terminal_reason'] == 'cancelled_by_user' &&
              event['payloads_match'] == true && event['terminal_delivered'] == true
          end
          pass_if(consistent)
        end

        # C5 controls subset that exists on BOTH surfaces: /status word agreement
        # and /cancel semantics (same durable payload contract, same terminal
        # reason). The remaining sweep commands have no operator-CLI counterpart
        # inside this harness seam and stay typed-unavailable edges.
        def controls_parity_document(facts)
          status_reply = facts['cli_status_probe']
          swept = status_reply.is_a?(Hash) ? status_reply['reply_word'] : nil
          viewed = status_reply.is_a?(Hash) ? status_reply['view_word'] : nil
          status_semantics = !swept.nil? && swept == viewed ? PASS : FAIL
          compared = {
            'status_semantics' => status_semantics,
            'cancel_semantics' => cancellation_parity(facts)
          }
          scored_parity(compared, controls_parity_edges)
        end

        def controls_parity_edges
          [
            unavailable_edge('command_sweep_breadth',
                             'help/new/redirect/whoami/start have no operator-CLI counterpart in this ' \
                             'harness seam; only /status and /cancel are compared'),
            unavailable_edge('pairing_and_admission',
                             'the operator CLI has no untrusted-sender admission concept to compare against'),
            cli_visibility_edge
          ]
        end
      end
    end
  end
end
