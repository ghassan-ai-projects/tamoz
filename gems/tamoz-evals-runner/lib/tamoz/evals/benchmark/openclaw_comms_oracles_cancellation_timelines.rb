# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # Per-timeline cancellation checks behind the C8 oracle.
      module OpenclawCommsOracles
        module_function

        # The store's terminal derivation is the race verdict, keyed to the
        # SAME settle kind the store records at complete_request: an answer
        # settles completed_before_effect, failed and blocked say so, and
        # only an observed-but-unsettled request is stopped — never the
        # reverse.
        SETTLE_WORDS = {
          'answer' => 'completed_before_effect',
          'failed' => 'failed_before_effect',
          'stopped' => 'stopped',
          'blocked' => 'blocked'
        }.freeze

        def c8_expected_terminal_word(timeline)
          kind = timeline['settle_kind']
          return SETTLE_WORDS.fetch(kind, nil) if kind && kind != 'admitted'

          'stopped' if timeline['observed_present']
        end

        def c8_timeline_failures(timelines)
          timelines.flat_map { |timeline| c8_single_timeline_failures(timeline) }
        end

        def c8_single_timeline_failures(timeline)
          expected = c8_expected_terminal_word(timeline)
          failures = []
          failures << 'cancellation_state_lost' unless c8_state_kept?(timeline)
          failures << 'race_misresolved' unless timeline['requested_le_observed'] == true
          failures << 'race_misresolved' unless timeline['terminal_word'] == expected
          failures << 'race_misresolved' if c8_settled_after_observed?(timeline)
          failures
        end

        def c8_state_kept?(timeline)
          timeline['requested_present'] && timeline['observed_present'] && timeline['state'] == 'terminal'
        end

        def c8_settled_after_observed?(timeline)
          timeline['settled'] && !timeline['settle_le_observed'].nil? && timeline['settle_le_observed'] != true
        end

        def c8_wording_pairs(timelines, wordings)
          wordings.filter_map do |wording|
            timeline = timelines.find { |candidate| candidate['reference'] == wording['reference'] }
            next nil unless timeline

            [timeline, wording]
          end
        end

        def c8_wording_matches?(timeline, wording)
          word = timeline['terminal_word']
          {
            'stopped' => wording['claims_stopped'],
            'completed_before_effect' => wording['claims_completed_before_effect'],
            'failed_before_effect' => wording['claims_failed_before_effect'],
            'blocked' => wording['claims_blocked']
          }.all? { |expected, claimed| claimed == (word == expected) }
        end

        def c8_stopped_claimed_against_completion?(checked)
          checked.any? do |check|
            check['pairs'].any? do |timeline, wording|
              timeline['settled'] &&
                (timeline['terminal_word'] == 'stopped' || wording['claims_stopped'])
            end
          end
        end
      end
    end
  end
end
