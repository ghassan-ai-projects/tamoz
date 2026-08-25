# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # Deterministic, controller-owned oracles for the nine canonical comms
      # scenarios. Every oracle is a pure function of the durable-fact
      # snapshot the fixture recorded — request/outbox/inbound rows, the
      # milestone stream, status projections, conversation history — never of
      # a self-report or a wall clock. The same snapshot always yields the
      # same scores.
      module OpenclawCommsOracles
        PASS = 1
        FAIL = 0
        MILESTONE_KINDS = %w[request.claimed request.running request.waiting request.recovered].freeze

        module_function

        def unavailable(reason)
          { 'status' => 'unavailable', 'reason' => reason }
        end

        def milestone_rows(facts)
          facts['outbox'].select { |row| row['kind'] == 'control' && row['journaled'] == 0 && row['milestone_facts'] }
        end

        def rows_of_kind(facts, kind)
          kind ? facts['outbox'].select { |row| row['kind'] == kind } : facts['outbox']
        end

        def requests_for(facts, conversation_id)
          facts['requests'].select { |row| row['conversation_id'] == conversation_id }
        end

        def dispositions(facts, update_id)
          facts['inbound'].select { |row| row['update_id'] == update_id }.map { |row| [row['disposition'], row['reason']] }
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
          rows_of_kind(facts, nil)
            .select { |row| row['conversation_id'] == conversation_id &&
                             row['status'] == 'succeeded' && TERMINAL_KINDS.include?(row['kind']) }
            .map { |row| row['text'] }
        end

        # context_inclusion (invariant 11): only CONFIRMED successful terminal
        # deliveries entered history; progress/control never did.
        def context_inclusion(facts, conversation_id)
          assistants = assistant_entries(facts, conversation_id)
          confirmed = confirmed_answer_texts(facts, conversation_id)
          return FAIL unless assistants.map { |entry| entry['text'] } == confirmed

          leak = milestone_rows(facts).any? do |row|
            assistants.any? { |entry| entry['text'].to_s.include?(row['milestone_facts'].fetch('phase')) }
          end
          leak ? FAIL : PASS
        end

        def completion(facts, conversation_id)
          session = facts.fetch('session').fetch(conversation_id, {})
          session['status'] == 'completed' && session['satisfied'] == true ? PASS : FAIL
        end

        def reference_stability(facts, conversation_id)
          requests = requests_for(facts, conversation_id)
          return FAIL unless requests.length == 1

          reference = requests.first.fetch('request_ref')
          accepted = rows_of_kind(facts, 'accepted').find do |row|
            row['conversation_id'] == conversation_id
          end
          return FAIL unless accepted&.dig('text').to_s.include?(reference)

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

        # C1 ----------------------------------------------------------------

        def c1(facts, conversation:)
          ack_row = rows_of_kind(facts, 'accepted').find { |row| row['conversation_id'] == conversation }
          admitted = dispositions(facts, facts['driven_update_ids'].first) == [['request', 'accepted']] &&
                     !requests_for(facts, conversation).empty?
          parity = core_parity_document(facts)
          {
            'metrics' => {
              'admission_before_ack' => admitted && ack_row ? PASS : FAIL,
              'reference_stability' => reference_stability(facts, conversation),
              'completion' => completion(facts, conversation),
              'delivery_axis' => delivery_axis(facts, conversation),
              'context_inclusion' => context_inclusion(facts, conversation),
              'parity' => parity.fetch('score')
            },
            'hard_zero' => {
              'ack_before_admission' => (!admitted && ack_row) ? 'failed' : 'passed',
              'unconfirmed_output_in_history' =>
                unconfirmed_output_in_history?(facts, conversation) ? 'failed' : 'passed',
              'identity_conflict_deduplicated' => identity_conflict?(facts) ? 'failed' : 'passed'
            },
            'parity' => parity
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
          pushed = facts['pushed_milestones'].select { |event| event['request_id'] != '' }
          pushed_sequences = pushed.map { |event| event['sequence'] }.sort
          projected = milestone_rows(facts)
          sequences = projected.map { |row| row['milestone_facts'].fetch('sequence') }
          backed = projected.all? do |row|
            pushed.any? do |event|
              event['sequence'] == row['milestone_facts'].fetch('sequence') &&
                event['phase'] == row['milestone_facts'].fetch('phase')
            end
          end
          covered = pushed.length.positive? &&
                    sequences.all? { |sequence| pushed_sequences.include?(sequence) } &&
                    sequences.max == pushed_sequences.max
          live_pending = projected.count { |row| row['status'] == 'pending' }
          bound = Tamoz::SQLite::CommsOutbox::MILESTONE_BOUND
          {
            'metrics' => {
              'liveness' => covered && backed && live_pending <= 1 ? PASS : FAIL,
              'progress_bound' => projected.length <= bound ? PASS : FAIL,
              'context_inclusion' => context_inclusion(facts, conversation),
              'completion' => completion(facts, conversation),
              'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture'),
              'latency_to_ack' => unavailable('wall_clock_latency_not_fixture_controlled'),
              'latency_to_terminal' => unavailable('worker_wall_clock_not_fixture_controlled'),
              'update_count' => projected.length + rows_of_kind(facts, 'answer').length
            },
            'hard_zero' => {
              'fabricated_milestone' => backed ? 'passed' : 'failed',
              'unconfirmed_output_in_history' =>
                unconfirmed_output_in_history?(facts, conversation) ? 'failed' : 'passed',
              'token_stream' => token_stream?(facts) ? 'failed' : 'passed'
            }
          }
        end

        def token_stream?(facts)
          milestone_rows(facts).any? do |row|
            reference = row['milestone_facts'].fetch('request_ref')
            phase = row['milestone_facts'].fetch('phase')
            row['text'] != "#{reference}: #{phase}"
          end
        end

        # C5 ----------------------------------------------------------------

        COMMAND_SIGNATURES = {
          'help' => ['Commands: /help'],
          'status' => ['Work status:'],
          'new' => ['New conversation started'],
          'cancel' => ['No running request to cancel', 'Cancellation requested'],
          'redirect' => ['Redirecting', 'That request has already finished.', 'Usage: /redirect'],
          'whoami' => ['You are telegram:user:'],
          'start' => ['Usage: /start'],
          'reset' => ['Episode reset on generation '],
          'compact' => ['Transcript compacted; '],
          'usage' => ['Usage: requests '],
          'context' => ['Context: fragments visible '],
          'think' => ['Reasoning depth set to '],
          'verbose' => ['Answer verbosity set to ']
        }.freeze

        def c5(facts, conversation:)
          sweep = facts['command_sweep']
          executed = Tamoz::Comms::Commands::KNOWN.all? do |name|
            signatures = COMMAND_SIGNATURES.fetch(name)
            sweep.fetch(name, []).any? { |reply| signatures.any? { |signature| reply.start_with?(signature) } }
          end
          phantom = Tamoz::Comms::Commands::KNOWN.any? do |name|
            sweep.fetch(name, []).any? { |reply| reply.downcase.include?('not available') }
          end
          authority = authority_stable?(facts)
          targets = facts['outbox'].all? do |row|
            next true unless row['kind'] == 'control'

            expected = facts['message_id_by_update_id'][row['reply_to']]
            expected || row['reply_to'].nil? ? true : false
          end
          parity = controls_parity_document(facts)
          {
            'metrics' => {
              'command_parity' => executed && !phantom ? PASS : FAIL,
              'inbound_identity' => inbound_identity(facts),
              'authority_stability' => authority,
              'context_inclusion' => injection_inert(facts, conversation),
              'parity' => parity.fetch('score')
            },
            'hard_zero' => {
              'phantom_command' => phantom ? 'failed' : 'passed',
              'authority_from_content' => authority == PASS ? 'passed' : 'failed',
              'identity_conflict_deduplicated' => conflict_merged?(facts) ? 'failed' : 'passed'
            },
            'parity' => parity
          }
        end

        def inbound_identity(facts)
          conflicting = facts['inbound'].any? { |row| row['reason'] == 'integrity_conflict' }
          one_anchor_per_identity = facts['inbound']
                                    .group_by { |row| row['update_id'] }.values
                                    .all? { |rows| rows.length == 1 }
          one_request_per_turn = facts['requests'].length == facts['driven_text_turns'].to_i
          conflicting && facts['duplicate_observed'] == true &&
            one_anchor_per_identity && one_request_per_turn ? PASS : FAIL
        end

        def conflict_merged?(facts)
          conflicting = facts['inbound'].any? { |row| row['reason'] == 'integrity_conflict' }
          conflicting && facts['conflict_reply_absent'] == true
        end

        def authority_stable?(facts)
          effects = facts['effects']
          shaped = effects.any? { |row| row['operation'].start_with?('policy.', 'authority.') }
          prompts = rows_of_kind(facts, 'approval_request').length
          shaped || prompts > facts['expected_approval_prompts'].to_i ? FAIL : PASS
        end

        def injection_inert(facts, conversation)
          bait = facts['injection_text']
          echoed = assistant_entries(facts, conversation).any? { |entry| entry['text'].to_s.include?(bait) }
          context_inclusion(facts, conversation) == PASS && !echoed ? PASS : FAIL
        end

        # C7 ----------------------------------------------------------------

        def c7(facts, conversation:)
          waiting = milestone_rows(facts).any? { |row| row['milestone_facts'].fetch('phase') == 'waiting' }
          prompt = rows_of_kind(facts, 'approval_request').first
          named = prompt&.dig('text').to_s.include?('needs your approval')
          consumed = facts['prompt_consumed'] == true
          denied_terminal = rows_of_kind(facts, 'answer').any? { |row| row['text'].to_s.start_with?('Denied') } ||
                            rows_of_kind(facts, 'failed').length >= 1
          effect_ran = facts['effects'].any? { |row| row['operation'].include?('apply_patch') && row['status'] == 'succeeded' }
          authority = authority_stable?(facts)
          {
            'metrics' => {
              'authority_stability' => authority,
              'waiting_names_reason_and_next_action' => waiting && named ? PASS : FAIL,
              'deny_fail_safe' => consumed && denied_terminal && !effect_ran ? PASS : FAIL,
              'context_inclusion' => context_inclusion(facts, conversation),
              'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture')
            },
            'hard_zero' => {
              'authority_from_content' => authority == PASS && facts['content_approved'] == false ? 'passed' : 'failed',
              'effect_before_approval' => effect_ran ? 'failed' : 'passed',
              'unconfirmed_output_in_history' =>
                unconfirmed_output_in_history?(facts, conversation) ? 'failed' : 'passed'
            }
          }
        end

        def safe_facts(row)
          JSON.parse(row['markup'])
        rescue StandardError
          {}
        end

        # C9 ----------------------------------------------------------------

        def c9(facts, conversations:)
          refs = conversations.to_h do |conversation|
            [conversation, requests_for(facts, conversation).map { |row| row.fetch('request_ref') }]
          end
          cross_resolved = refs.flat_map { |_conversation, references| references }.any? do |reference|
            resolution = facts.fetch('cross_projections')[reference]
            resolution.is_a?(Hash) && resolution['request_ref'] == reference
          end
          sends_isolated = facts['sends'].group_by { |send| send['conversation_id'] }.keys.sort ==
                           conversations.sort
          own_references = refs.values.flatten +
                           facts.fetch('cli_legs', []).map { |leg| leg.fetch('reference') }
          history_isolated = conversations.all? do |conversation|
            own = requests_for(facts, conversation).map { |row| row.fetch('request_id') }
            assistant_entries(facts, conversation).length ==
              confirmed_answer_texts(facts, conversation).length &&
              facts.fetch('history').fetch(conversation, []).all? do |entry|
                entry['role'] != 'assistant' || own.any?
              end
          end
          milestone_isolated = milestone_rows(facts).all? do |row|
            reference = row['milestone_facts'].fetch('request_ref')
            own_references.include?(reference)
          end
          parity = core_parity_document(facts)
          {
            'metrics' => {
              'isolation' => !cross_resolved && sends_isolated && history_isolated &&
                             milestone_isolated ? PASS : FAIL,
              'context_inclusion' =>
                conversations.all? { |conversation| context_inclusion(facts, conversation) } ? PASS : FAIL,
              'reference_stability' =>
                conversations.all? { |conversation| reference_stability(facts, conversation) } ? PASS : FAIL,
              'parity' => parity.fetch('score')
            },
            'hard_zero' => {
              'cross_conversation_attribution' => sends_isolated && milestone_isolated ? 'passed' : 'failed',
              'status_cross_resolution' => cross_resolved ? 'failed' : 'passed',
              'wrong_conversation_history' => history_isolated ? 'passed' : 'failed'
            },
            'parity' => parity
          }
        end

        # C4 ----------------------------------------------------------------

        def c4(facts, conversation:)
          requests = requests_for(facts, conversation)
          effects = facts['effects'].map { |row| row['effect_key'] }
          unique_effects = effects.uniq == effects
          answer_sends = facts['sends'].count { |send| send['kind'] == 'answer' }
          unique_terminal = facts['outbox'].count { |row| row['kind'] == 'answer' } ==
                            answer_sends
          boundaries = facts['boundaries_executed']
          recovered_ladder = milestone_rows(facts).any? { |row| row['milestone_facts']['phase'] == 'recovered' }
          {
            'metrics' => {
              'restart_safety' => unique_effects && unique_terminal && boundaries.length >= 3 ? PASS : FAIL,
              'reference_stability' => requests.length == 1 && reference_stability(facts, conversation),
              'no_blind_retry' => answer_sends <= 1 ? PASS : FAIL,
              'completion' => completion(facts, conversation),
              'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture')
            },
            'hard_zero' => {
              'duplicate_effect' => unique_effects ? 'passed' : 'failed',
              'duplicate_terminal_send' => unique_terminal ? 'passed' : 'failed',
              'blind_retry_after_unknown' => answer_sends <= 1 && recovered_ladder ? 'passed' : 'failed'
            }
          }
        end

        # C3 ----------------------------------------------------------------

        def c3(facts)
          unknown_rows = facts['outbox'].select { |row| row['status'] == 'unknown' }
          failed_auth = facts['outbox'].find do |row|
            row['status'] == 'failed' && row['receipt'].to_s.include?('authentication_refused')
          end
          stale_refused = facts['stale_owner_mark_refused'] == true
          throttled_retried = facts['throttle_then_delivered'] == true
          unknown_preserved = facts['unknown_preserved_no_resend'] == true
          answer_sends = facts['sends'].count { |send| send['kind'] == 'answer' }
          journaled_answers = facts['outbox'].count { |row| row['kind'] == 'answer' }
          no_blind = answer_sends <= journaled_answers
          {
            'metrics' => {
              'no_blind_retry' => no_blind ? PASS : FAIL,
              'unknown_preservation' => unknown_rows.length >= 1 && unknown_rows.first['receipt'].nil? &&
                                        unknown_preserved ? PASS : FAIL,
              'owner_fencing' => stale_refused ? PASS : FAIL,
              'delivery_axis' => throttled_retried && failed_auth ? PASS : FAIL
            },
            'hard_zero' => {
              'blind_retry_after_unknown' => unknown_preserved && no_blind ? 'passed' : 'failed',
              'stale_owner_send' => stale_refused ? 'passed' : 'failed',
              'unknown_reported_as_terminal' =>
                unknown_rows.none? { |row| %w[succeeded failed].include?(row['status']) } ? 'passed' : 'failed'
            }
          }
        end

        # Reference stability for scenarios that drive further turns after the
        # first admitted request: the FIRST telegram reference must still
        # resolve to its own row through the conversation projection.
        def first_reference_stable(facts, conversation)
          reference = facts['requests'].select { |row| row['conversation_id'] == conversation }
                                       .filter_map { |row| row['request_ref'] }.first
          return FAIL unless reference

          accepted = rows_of_kind(facts, 'accepted').find { |row| row['conversation_id'] == conversation }
          projection = facts.fetch('request_projections')[reference]
          accepted&.dig('text').to_s.include?(reference) &&
            projection.is_a?(Hash) && projection['request_ref'] == reference ? PASS : FAIL
        end

        # C6 ----------------------------------------------------------------
        # Cross-surface parity over ONE durable thread reachable from both
        # surfaces: the telegram leg and the durable-CLI leg are compared on
        # MEANING — the Lifecycle vocabulary each surface's internal state
        # translates to, whether each surface's reference resolves to its own
        # executed request row, the terminal reason, and history under the
        # confirmed-deliveries rule — never on rendered bytes.

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

          matched = pairs.all? do |telegram, cli|
            telegram_word = leg_task_word(telegram)
            !telegram_word.nil? && telegram_word == leg_task_word(cli)
          end
          deliveries = pairs.flat_map do |telegram, cli|
            [delivery_word(telegram['delivery_state']), delivery_word(cli['delivery_state'])]
          end
          matched && deliveries.uniq.length == 1 && deliveries.first != 'none' ? PASS : FAIL
        rescue Tamoz::Comms::ValidationError
          FAIL
        end

        def leg_task_word(leg)
          state = leg['request_status']
          return nil if state.to_s.empty?

          task_word(state)
        end

        def milestone_references(facts)
          facts['outbox'].filter_map { |row| row.dig('milestone_facts', 'request_ref') }.uniq
        end

        def reference_resolution(facts)
          pairs = paired_legs(facts)
          return FAIL if pairs.empty?

          cards = milestone_references(facts)
          resolved = pairs.all? do |telegram, cli|
            leg_reference_resolves?(facts, telegram) && leg_reference_resolves?(facts, cli) &&
              cards.include?(telegram['reference']) && cards.include?(cli['reference'])
          end
          resolved ? PASS : FAIL
        end

        def leg_reference_resolves?(facts, leg)
          leg['request_row_present'] &&
            leg['reference'] == Tamoz::Comms::Lifecycle::RequestRef.for(leg['request_id'])
        end

        def terminal_reason(facts)
          pairs = paired_legs(facts)
          return FAIL if pairs.empty?

          pairs.all? do |telegram, cli|
            reason = telegram['terminal_reason'].to_s
            !reason.empty? && reason == cli['terminal_reason'].to_s
          end ? PASS : FAIL
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
          document = {
            'status' => 'scored',
            'compared' => compared,
            'score' => compared.value?(FAIL) ? FAIL : PASS,
            'edges' => edges
          }
          document
        end

        # The conversation projection counts comms-admitted requests only, so
        # CLI-queued work has no /status or /cancel expression at the command
        # layer; parity therefore compares thread-scoped durable facts.
        def cli_visibility_edge
          unavailable_edge('cli_queued_work_conversation_visibility',
                           'the conversation projection sees comms-admitted requests only, so the ' \
                           '/status and /cancel command guards cannot express CLI-queued work')
        end

        def c6(facts, conversation:)
          document = core_parity_document(facts)
          parity_score = document.fetch('score')
          authority = authority_stable?(facts)
          cancellation = cancellation_parity(facts)
          distinct_texts = facts['distinct_answer_texts'] == true
          {
            'metrics' => {
              'parity' => parity_score,
              'context_inclusion' => context_inclusion(facts, conversation),
              'reference_stability' => first_reference_stable(facts, conversation)
            },
            'hard_zero' => {
              'parity_by_text' => distinct_texts && parity_score == PASS ? 'passed' : 'failed',
              'surface_outcome_divergence' => parity_score == PASS ? 'passed' : 'failed',
              'one_sided_cancellation' => cancellation == PASS ? 'passed' : 'failed'
            },
            'parity' => document.merge(
              'cancellation' => { 'score' => cancellation,
                                  'observed' => facts.fetch('cancellations', []) },
              'distinct_answer_texts' => distinct_texts
            )
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

          events.all? do |event|
            event['terminal_reason'] == 'cancelled_by_user' &&
              event['payloads_match'] == true && event['terminal_delivered'] == true
          end ? PASS : FAIL
        end

        # C8 ----------------------------------------------------------------
        # Visible cancellation, scored ONLY over durable facts: the
        # requested/observed stamps and the projection state of each target,
        # the store's own terminal derivation (a settled request is NEVER
        # rendered as stopped — invariant 9), the wording class of the real
        # ref-addressed /status rendering, and the absence of cancellation
        # facts from conversation history.

        def c8(facts, conversation:)
          checked = %w[clean_stop raced_restart].map do |name|
            c8_run_check(name, facts.fetch(name), conversation)
          end
          failures = checked.flat_map { |check| check['failures'] }.uniq

          {
            'metrics' => {
              'cancellation_honesty' =>
                failures.empty? &&
                checked.all? { |check| check['wording_consistent'] && check['history_clean'] } &&
                checked.all? { |check| check['command_accepted'] } ? PASS : FAIL,
              'restart_safety' =>
                checked.all? { |check| check['restart_ok'] } ? PASS : FAIL,
              'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture')
            },
            'hard_zero' => {
              'false_stopped_claim' => c8_stopped_claimed_against_completion?(checked) ?
                                         'failed' : 'passed',
              'race_misresolved' => failures.include?('race_misresolved') ? 'failed' : 'passed',
              'cancellation_state_lost' =>
                (failures.include?('cancellation_state_lost') ||
                 checked.any? { |check| !check['command_accepted'] }) ? 'failed' : 'passed'
            },
            'timelines' => checked.flat_map { |check| check['timelines'] },
            'wordings' => checked.flat_map { |check| check['wordings'] },
            'edges' => [
              unavailable_edge('engine_observed_before_settle',
                               'the runner consumes cancel redirects only after the thread\'s open ' \
                               'occurrence settles, so an observed stamp that precedes settlement is ' \
                               'not expressible through the engine offline; the clean_stop leg stamps ' \
                               'observation through the same store method the worker calls'),
              cli_visibility_edge
            ]
          }
        end

        def c8_run_check(name, run, conversation)
          timelines = run.fetch('cancellation_timelines')
          wordings = run.fetch('terminal_wordings')
          pairs = c8_wording_pairs(timelines, wordings)
          failures = c8_timeline_failures(timelines)
          unless run['waiting_milestone_recorded'] == true || name != 'clean_stop'
            failures << 'cancellation_state_lost'
          end
          {
            'timelines' => timelines,
            'wordings' => wordings,
            'pairs' => pairs,
            'wording_consistent' => pairs.length == timelines.length &&
                                    pairs.all? { |timeline, wording| c8_wording_matches?(timeline, wording) },
            'history_clean' => c8_history_clean?(run, conversation),
            'restart_ok' => name != 'raced_restart' ||
                            run.fetch('restart_boundary').values.all?(true),
            'command_accepted' => run['cancel_command_accepted'] == true &&
                                  (name != 'clean_stop' || run['observation_stamp_accepted'] == true),
            'failures' => failures.uniq
          }
        end

        # The store's terminal derivation is the race verdict: a request whose
        # projection settled completed is completed_before_effect, everything
        # else observed is stopped — never the reverse.
        def c8_timeline_failures(timelines)
          timelines.flat_map do |timeline|
            expected = timeline['settled'] ? 'completed_before_effect' : 'stopped'
            failures = []
            failures << 'cancellation_state_lost' unless timeline['requested_present'] &&
                                                         timeline['observed_present'] &&
                                                         timeline['state'] == 'terminal'
            failures << 'race_misresolved' unless timeline['requested_le_observed'] == true
            failures << 'race_misresolved' unless timeline['terminal_word'] == expected
            if timeline['settled'] && !timeline['settle_le_observed'].nil?
              failures << 'race_misresolved' unless timeline['settle_le_observed'] == true
            end
            failures
          end
        end

        def c8_wording_pairs(timelines, wordings)
          wordings.filter_map do |wording|
            timeline = timelines.find { |candidate| candidate['reference'] == wording['reference'] }
            next nil unless timeline

            [timeline, wording]
          end
        end

        def c8_wording_matches?(timeline, wording)
          expected_stopped = timeline['terminal_word'] == 'stopped'
          wording['claims_stopped'] == expected_stopped &&
            wording['claims_completed_before_effect'] == !expected_stopped
        end

        def c8_stopped_claimed_against_completion?(checked)
          checked.any? do |check|
            check['pairs'].any? do |timeline, wording|
              timeline['settled'] &&
                (timeline['terminal_word'] == 'stopped' || wording['claims_stopped'])
            end
          end
        end

        # Invariant 11 plus the C8-specific rule: no cancellation fact — the
        # command reply, the timeline wording, the reason code — ever enters
        # conversation history.
        def c8_history_clean?(facts, conversation)
          entries = facts.fetch('history').fetch(conversation, [])
          entries.none? { |entry| entry['text'].to_s.match?(/cancel/i) } &&
            context_inclusion(facts, conversation) == PASS
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
          cancel = cancellation_parity(facts)
          compared = {
            'status_semantics' => status_semantics,
            'cancel_semantics' => cancel
          }
          edges = [
            unavailable_edge('command_sweep_breadth',
                             'help/new/redirect/whoami/start have no operator-CLI counterpart in this ' \
                             'harness seam; only /status and /cancel are compared'),
            unavailable_edge('pairing_and_admission',
                             'the operator CLI has no untrusted-sender admission concept to compare against'),
            cli_visibility_edge
          ]
          {
            'status' => 'scored',
            'compared' => compared,
            'score' => compared.value?(FAIL) ? FAIL : PASS,
            'edges' => edges
          }
        end
      end
    end
  end
end
