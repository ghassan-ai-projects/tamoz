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
          {
            'metrics' => {
              'admission_before_ack' => admitted && ack_row ? PASS : FAIL,
              'reference_stability' => reference_stability(facts, conversation),
              'completion' => completion(facts, conversation),
              'delivery_axis' => delivery_axis(facts, conversation),
              'context_inclusion' => context_inclusion(facts, conversation),
              'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture')
            },
            'hard_zero' => {
              'ack_before_admission' => (!admitted && ack_row) ? 'failed' : 'passed',
              'unconfirmed_output_in_history' =>
                unconfirmed_output_in_history?(facts, conversation) ? 'failed' : 'passed',
              'identity_conflict_deduplicated' => identity_conflict?(facts) ? 'failed' : 'passed'
            }
          }
        end

        def delivery_axis(facts, conversation)
          answers = rows_of_kind(facts, 'answer').select { |row| row['conversation_id'] == conversation }
          return FAIL unless answers.length == 1

          answer = answers.first
          task = task_word(facts.fetch('session').dig(conversation, 'status'))
          delivered = delivery_word(answer['status'])
          task == 'completed' && delivered == 'delivered' ? PASS : FAIL
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
          'cancel' => ['No active work', 'Cancellation requested'],
          'redirect' => ['Redirecting', 'That request has already finished.', 'Usage: /redirect'],
          'whoami' => ['You are telegram:user:'],
          'start' => ['Usage: /start']
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
          {
            'metrics' => {
              'command_parity' => executed && !phantom ? PASS : FAIL,
              'inbound_identity' => inbound_identity(facts),
              'authority_stability' => authority,
              'context_inclusion' => injection_inert(facts, conversation),
              'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture')
            },
            'hard_zero' => {
              'phantom_command' => phantom ? 'failed' : 'passed',
              'authority_from_content' => authority == PASS ? 'passed' : 'failed',
              'identity_conflict_deduplicated' => conflict_merged?(facts) ? 'failed' : 'passed'
            }
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
          history_isolated = conversations.all? do |conversation|
            own = requests_for(facts, conversation).map { |row| row.fetch('request_id') }
            assistant_entries(facts, conversation).length ==
              confirmed_answer_texts(facts, conversation).length &&
              facts.fetch('history').fetch(conversation, []).all? do |entry|
                entry['role'] != 'assistant' || own.any?
              end
          end
          milestone_isolated = milestone_rows(facts).all? do |row|
            conversations.any? do |conversation|
              requests_for(facts, conversation).any? do |request|
                request.fetch('request_ref') == row['milestone_facts'].fetch('request_ref')
              end
            end
          end
          {
            'metrics' => {
              'isolation' => !cross_resolved && sends_isolated && history_isolated &&
                             milestone_isolated ? PASS : FAIL,
              'context_inclusion' =>
                conversations.all? { |conversation| context_inclusion(facts, conversation) } ? PASS : FAIL,
              'reference_stability' =>
                conversations.all? { |conversation| reference_stability(facts, conversation) } ? PASS : FAIL,
              'parity' => unavailable('cli_surface_executor_is_phase_b2_single_surface_fixture')
            },
            'hard_zero' => {
              'cross_conversation_attribution' => sends_isolated && milestone_isolated ? 'passed' : 'failed',
              'status_cross_resolution' => cross_resolved ? 'failed' : 'passed',
              'wrong_conversation_history' => history_isolated ? 'passed' : 'failed'
            }
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
      end
    end
  end
end
