# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # Drives controller-owned moments around the durable CLI adapter. The
      # subject still runs through the real provider and the existing journal.
      class ScenarioDriver
        METRIC_SCALE = 1_000

        # Envelope shared by every oracle result: metrics, hard-zero flags, reasons.
        module OracleResult
          private

          def result(metrics:, hard_zero:, reasons:)
            { 'metrics' => metrics, 'hard_zero' => hard_zero, 'hard_zero_reasons' => reasons }
          end

          def hard_zero_reason(name, status)
            case status
            when 'failed' then "hard_zero_failed:#{name}"
            when 'unknown' then "hard_zero_unverifiable:#{name}"
            end
          end
        end

        # Scores the contradiction from journaled tool and terminal evidence.
        class T3M1M2Oracle
          class << self
            include OracleResult

            def call(evidence:, post_contradiction_digest:, stale_value:, second_observation_ref: nil)
              evidence = {} unless evidence.is_a?(Hash)
              second_ref = second_observation_ref || Array(evidence['observation_refs']).last
              verification = evidence['verification']
              verification_refs = verification['evidence'] if verification.is_a?(Hash)
              expected_digest = normalize_digest(post_contradiction_digest)
              recovery = recovery_metric(evidence, expected_digest, second_ref, verification_refs)
              false_success = false_success_status(evidence, stale_value)
              result(
                metrics: { 'recovery' => recovery },
                hard_zero: { 'false_success' => false_success },
                reasons: hard_zero_reasons(false_success)
              )
            end

            private

            def recovery_metric(evidence, expected_digest, second_ref, verification_refs)
              return 0 unless expected_digest
              return 0 unless read_file_receipts(evidence).any? do |receipt|
                normalize_digest(receipt_digest(receipt)) == expected_digest
              end
              return 0 unless second_ref && Array(verification_refs).include?(second_ref)

              METRIC_SCALE
            end

            def read_file_receipts(evidence)
              Array(evidence['effect_receipts']).select do |receipt|
                receipt.is_a?(Hash) && receipt['operation'] == 'tool.local:read_file' &&
                  receipt['status'] == 'succeeded'
              end
            end

            def receipt_digest(receipt)
              receipt['content_digest'] || receipt['observation_digest'] || receipt['digest'] ||
                output_digest(receipt)
            end

            def output_digest(receipt)
              result = receipt['result']
              output = result.is_a?(Hash) ? result['output'] : receipt['output']
              return unless output.is_a?(String)

              match = output.match(/(?:\A|\n)sha256:\s*([0-9a-f]{64})(?:\n|\z)/i)
              match && match[1].downcase
            end

            def false_success_status(evidence, stale_value)
              text = terminal_answer(evidence)
              stale_value = String(stale_value)
              return 'unknown' if text.nil? || stale_value.empty?

              text.match?(/\b#{Regexp.escape(stale_value.downcase)}\b/) ? 'failed' : 'passed'
            end

            def terminal_answer(evidence)
              terminal = evidence['terminal']
              verification = evidence['verification']
              answers = [terminal, verification].filter_map do |record|
                record['answer'] if record.is_a?(Hash) && record['answer'].is_a?(String)
              end
              answers.join("\n").then { |value| value.empty? ? nil : value }
            end

            def hard_zero_reasons(status)
              [hard_zero_reason('false_success', status)].compact
            end

            def normalize_digest(value)
              digest = value.to_s.delete_prefix('sha256:').downcase
              digest if digest.match?(/\A[0-9a-f]{64}\z/)
            end
          end
        end

        # Scores restart recovery from the final journal and receipt history.
        class T3M3M4Oracle
          class << self
            include OracleResult

            def call(evidence:, pre_kill_effect_key:, restarted:)
              evidence = {} unless evidence.is_a?(Hash)
              history = effect_history(evidence)
              keys = history.filter_map { |receipt| logical_key(receipt) }
              duplicate_effect = duplicate_status(evidence, history, keys)
              recovery = recovery_metric(
                evidence, pre_kill_effect_key, keys, restarted
              )
              false_success = false_success_status(evidence)
              result(
                metrics: {
                  'recovery' => recovery,
                  'duplicate_effect_rate' => duplicate_effect_rate(keys)
                },
                hard_zero: {
                  'duplicate_effect' => duplicate_effect,
                  'false_success' => false_success
                },
                reasons: hard_zero_reasons(duplicate_effect, false_success)
              )
            end

            private

            def effect_history(evidence)
              history = evidence['effect_receipt_history']
              history.is_a?(Array) ? history : Array(evidence['effect_receipts'])
            end

            def logical_key(receipt)
              return unless receipt.is_a?(Hash)

              key = receipt['logical_key'] || receipt['effect_key']
              key if key.is_a?(String) && !key.empty?
            end

            def duplicate_status(evidence, history, keys)
              return 'unknown' unless evidence['effect_receipts_complete'] == true
              return 'unknown' unless history.is_a?(Array) && !history.empty?
              return 'unknown' unless keys.length == history.length

              keys.uniq == keys ? 'passed' : 'failed'
            end

            def recovery_metric(evidence, pre_kill_effect_key, keys, restarted)
              return 0 unless restarted == true
              return 0 unless terminal_completed?(evidence)
              return 0 unless pre_kill_effect_key.is_a?(String)
              return 0 unless keys.count(pre_kill_effect_key) == 1

              METRIC_SCALE
            end

            def terminal_completed?(evidence)
              terminal = evidence['terminal']
              verification = evidence['verification']
              evidence['status'].to_s == 'completed' && terminal.is_a?(Hash) &&
                terminal['satisfied'] == true && verification_passed?(verification)
            end

            def verification_passed?(verification)
              return true if verification.is_a?(Hash) && verification['configured_check_passed'] == true
              return false unless verification.is_a?(Hash)

              verification['terminal_reason'] == 'adaptive_final' &&
                verification['satisfied'] == true &&
                verification['evidence'].is_a?(Array) && !verification['evidence'].empty?
            end

            def false_success_status(evidence)
              return 'unknown' unless terminal_completed?(evidence)

              receipt = Array(evidence['effect_receipts']).find do |entry|
                entry.is_a?(Hash) && entry['operation'] == 'tool.create_file'
              end
              return 'unknown' unless receipt

              receipt['status'] == 'succeeded' ? 'passed' : 'failed'
            end

            def duplicate_effect_rate(keys)
              return unavailable_metric('effect_keys_unavailable') if keys.empty?

              duplicate_occurrences = keys.tally.values.sum { |count| [count - 1, 0].max }
              (duplicate_occurrences * METRIC_SCALE) / keys.length
            end

            def unavailable_metric(reason)
              { 'status' => 'unavailable', 'reason' => reason }
            end

            def hard_zero_reasons(duplicate_effect, false_success)
              [
                hard_zero_reason('duplicate_effect', duplicate_effect),
                hard_zero_reason('false_success', false_success)
              ].compact
            end
          end
        end

        class << self
          def definitions(scenario_definitions:)
            validate_definitions!(scenario_definitions)
          end

          def implemented?(scenario_id, scenario_definitions:)
            definitions(scenario_definitions:).key?(String(scenario_id))
          end

          def oracle(scenario_id:, scenario_definitions:, **arguments)
            definition(scenario_id, scenario_definitions:).fetch('oracle').call(**arguments)
          end

          def definition(scenario_id, scenario_definitions:)
            definitions(scenario_definitions:).fetch(String(scenario_id))
          end

          private

          def validate_definitions!(value)
            valid = value.is_a?(Hash) && !value.empty? && value.all? do |id, definition|
              id.is_a?(String) && definition.is_a?(Hash) &&
                definition.fetch('id') == id &&
                definition.fetch('mission_id').is_a?(String) &&
                definition.fetch('setup').is_a?(Hash) &&
                definition.fetch('steps').is_a?(Array) &&
                definition.fetch('oracle').respond_to?(:call)
            end
            raise ArgumentError, 'scenario definitions are invalid' unless valid

            value
          rescue KeyError, TypeError
            raise ArgumentError, 'scenario definitions are invalid'
          end
        end

        def initialize(adapter:, scenario:, scenario_definitions:)
          @adapter = adapter
          @scenario_definitions = self.class.definitions(scenario_definitions:)
          @scenario = self.class.definition(
            scenario,
            scenario_definitions: @scenario_definitions
          )
          required = %i[
            prepare! prepare_scenario! prepare_step! result_for evidence_for thread_id_for
            enqueue! worker! post_contradiction_digest stale_value restart_task
          ]
          required.push(:worker_until_effect!, :worker_subprocess!, :prepare_changes!) if restart_scenario?
          return if required.all? { |method| adapter.respond_to?(method) }

          raise ArgumentError, 'scenario adapter does not expose the durable session seams'
        end

        def call(mission:, run_kind:, provider:, model:)
          return @adapter.call(mission:, run_kind:, provider:, model:) unless
            mission.fetch('id') == @scenario.fetch('mission_id')
          raise ArgumentError, 'scenario driver only supports real_provider runs' unless
            run_kind == 'real_provider'

          provider = String(provider)
          model = String(model)
          prepare_run(provider:, model:)
          thread = @adapter.thread_id_for(mission.fetch('id'))
          pre_kill_effect_key =
            drive_scenario(thread:, provider:, model:, goal: mission.fetch('goal'))
          scored_result(mission:, provider:, model:, thread:, pre_kill_effect_key:)
        rescue Tamoz::Evals::ExecutionError => e
          blocked_result(mission, e.message)
        end

        private

        def definition
          @scenario
        end

        def drive(thread:, provider:, model:, goal:)
          definition.fetch('steps').each do |step|
            @adapter.prepare_step!(step:)
            task = "#{goal}\n\n#{step.fetch('task')}"
            enqueue_and_work(thread:, provider:, model:, task:)
          end
        end

        def drive_restart(thread:, provider:, model:, goal:)
          step = definition.fetch('steps').fetch(0)
          task = @adapter.restart_task(scenario: definition, step:, goal:)
          @adapter.enqueue!(thread, task, provider:, model:)
          pre_kill_effect_key = @adapter.worker_until_effect!(
            thread:, provider:, model:, operation: 'tool.create_file'
          )
          @adapter.worker_subprocess!(provider:, model:)
          pre_kill_effect_key
        end

        def restart_scenario?
          definition.fetch('driver_mode') == 'restart'
        end

        def enqueue_and_work(thread:, provider:, model:, task:)
          @adapter.enqueue!(thread, task, provider:, model:)
          @adapter.worker!(provider:, model:)
        end

        def prepare_run(provider:, model:)
          @adapter.prepare!(provider:, model:)
          @adapter.prepare_changes! if restart_scenario?
          @adapter.prepare_scenario!(scenario: definition, restart: restart_scenario?)
        end

        def drive_scenario(thread:, provider:, model:, goal:)
          if restart_scenario?
            drive_restart(thread:, provider:, model:, goal:)
          else
            drive(thread:, provider:, model:, goal:)
          end
        end

        def scored_result(mission:, provider:, model:, thread:, pre_kill_effect_key:)
          evidence = @adapter.evidence_for(thread:, provider:, model:)
          arguments = oracle_arguments(evidence:, pre_kill_effect_key:)
          oracle = self.class.oracle(
            scenario_id: @scenario.fetch('id'),
            scenario_definitions: @scenario_definitions,
            **arguments
          )
          @adapter.result_for(
            mission:, provider:, model:, thread:, evidence:,
            hard_zero_overrides: oracle.fetch('hard_zero'),
            hard_zero_reasons: oracle.fetch('hard_zero_reasons'),
            metric_overrides: oracle.fetch('metrics')
          )
        end

        def oracle_arguments(evidence:, pre_kill_effect_key:)
          if restart_scenario?
            { evidence:, pre_kill_effect_key:, restarted: true }
          else
            {
              evidence:,
              post_contradiction_digest: @adapter.post_contradiction_digest(scenario: definition),
              stale_value: @adapter.stale_value(scenario: definition)
            }
          end
        end

        def blocked_result(mission, reason)
          {
            'status' => 'blocked',
            'reason' => String(reason).byteslice(0, 256).to_s,
            'hard_zero' => mission.fetch('hard_zero', []).to_h { |name| [name, 'unknown'] },
            'effect_outcomes' => []
          }
        end
      end
    end
  end
end
