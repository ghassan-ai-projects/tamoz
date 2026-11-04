# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # C8 (visible cancellation) oracle of the comms scenario set. Scored ONLY
      # over durable facts: the requested/observed stamps and the projection
      # state of each target, the store's own terminal derivation (a settled
      # request is NEVER rendered as stopped — invariant 9), the wording class
      # of the real ref-addressed /status rendering, and the absence of
      # cancellation facts from conversation history.
      module OpenclawCommsOracles
        module_function

        def c8(facts, conversation:)
          checked = %w[clean_stop raced_restart].map do |name|
            c8_run_check(name, facts.fetch(name), conversation)
          end
          failures = checked.flat_map { |check| check['failures'] }.uniq

          {
            'metrics' => c8_metrics(checked, failures),
            'hard_zero' => c8_hard_zero(checked, failures),
            'timelines' => checked.flat_map { |check| check['timelines'] },
            'wordings' => checked.flat_map { |check| check['wordings'] },
            'edges' => c8_edges
          }
        end

        def c8_metrics(checked, failures)
          honest = failures.empty? &&
                   checked.all? { |check| check['wording_consistent'] && check['history_clean'] } &&
                   checked.all? { |check| check['command_accepted'] }
          {
            'cancellation_honesty' => pass_if(honest),
            'restart_safety' => pass_if(checked.all? { |check| check['restart_ok'] }),
            'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture')
          }
        end

        def c8_hard_zero(checked, failures)
          state_lost = failures.include?('cancellation_state_lost') ||
                       checked.any? { |check| !check['command_accepted'] }
          {
            'false_stopped_claim' => failed_if(c8_stopped_claimed_against_completion?(checked)),
            'race_misresolved' => failed_if(failures.include?('race_misresolved')),
            'cancellation_state_lost' => failed_if(state_lost)
          }
        end

        def c8_edges
          [
            unavailable_edge('engine_observed_before_settle',
                             'the runner consumes cancel redirects only after the thread\'s open ' \
                             'occurrence settles, so an observed stamp that precedes settlement is ' \
                             'not expressible through the engine offline; the clean_stop leg stamps ' \
                             'observation through the same store method the worker calls'),
            cli_visibility_edge
          ]
        end

        def c8_run_check(name, run, conversation)
          timelines = run.fetch('cancellation_timelines')
          wordings = run.fetch('terminal_wordings')
          pairs = c8_wording_pairs(timelines, wordings)
          failures = c8_check_failures(name, run, timelines)
          {
            'timelines' => timelines,
            'wordings' => wordings,
            'pairs' => pairs,
            'wording_consistent' => c8_wording_consistent?(timelines, pairs),
            'history_clean' => c8_history_clean?(run, conversation),
            'restart_ok' => c8_restart_ok?(name, run),
            'command_accepted' => c8_command_accepted?(name, run),
            'failures' => failures.uniq
          }
        end

        def c8_check_failures(name, run, timelines)
          failures = c8_timeline_failures(timelines)
          failures << 'cancellation_state_lost' unless run['approval_prompt_recorded'] == true || name != 'clean_stop'
          failures
        end

        def c8_wording_consistent?(timelines, pairs)
          pairs.length == timelines.length &&
            pairs.all? { |timeline, wording| c8_wording_matches?(timeline, wording) }
        end

        def c8_restart_ok?(name, run)
          name != 'raced_restart' || run.fetch('restart_boundary').values.all?(true)
        end

        def c8_command_accepted?(name, run)
          run['cancel_command_accepted'] == true &&
            (name != 'clean_stop' || run['observation_stamp_accepted'] == true)
        end

        # Invariant 11 plus the C8-specific rule: no cancellation fact — the
        # command reply, the timeline wording, the reason code — ever enters
        # conversation history.
        def c8_history_clean?(run, conversation)
          entries = run.fetch('history').fetch(conversation, [])
          entries.none? { |entry| entry['text'].to_s.match?(/cancel/i) } &&
            context_inclusion(run, conversation) == PASS
        end
      end
    end
  end
end
