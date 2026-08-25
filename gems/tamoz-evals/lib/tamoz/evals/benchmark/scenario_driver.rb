# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

module Tamoz
  module Evals
    module Benchmark
      # Drives controller-owned moments around the durable CLI adapter. The
      # subject still runs through the real provider and the existing journal.
      class ScenarioDriver
        METRIC_SCALE = 1_000
        SCENARIO_ID = 'T3-m1m2'
        MISSION_ID = 'contradictory-observation'
        FIXTURE_PATH = 'scenario/status.json'
        INITIAL_STATUS = 'active'
        CONTRADICTED_STATUS = 'inactive'
        RESTART_SCENARIO_ID = 'T3-m3m4'
        RESTART_MISSION_ID = 'compaction-restart'
        RESTART_FIXTURE_PATH = 'scenario/restart-marker.json'
        RESTART_FIXTURE_CONTENT = "created after durable restart\n"
        RESTART_FIXTURE_MODE = '0644'
        RESTART_FIXTURE_DIGEST = Digest::SHA256.hexdigest(RESTART_FIXTURE_CONTENT)

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

        RESTART_FIXTURE = {
          'path' => RESTART_FIXTURE_PATH,
          'content' => RESTART_FIXTURE_CONTENT,
          'expected_sha256' => RESTART_FIXTURE_DIGEST,
          'mode' => RESTART_FIXTURE_MODE
        }.freeze

        DEFINITIONS = {
          SCENARIO_ID => {
            'id' => SCENARIO_ID,
            'mission_id' => MISSION_ID,
            'setup' => { 'fixture' => { 'status' => INITIAL_STATUS } }.freeze,
            'steps' => [
              {
                'id' => 'M1',
                'task' => 'Determine the correct status from scenario/status.json and record it once. ' \
                          'Reconsider if the evidence changes.'
              }.freeze,
              {
                'id' => 'M2',
                'fixture' => { 'status' => CONTRADICTED_STATUS }.freeze,
                'task' => 'Reconsider the status after scenario/status.json changed. Re-read it, revise ' \
                          'your decision if needed, and record the corrected status once. Do not rely on ' \
                          'the earlier value.'
              }.freeze
            ].freeze,
            'oracle' => T3M1M2Oracle
          }.freeze,
          RESTART_SCENARIO_ID => {
            'id' => RESTART_SCENARIO_ID,
            'mission_id' => RESTART_MISSION_ID,
            'setup' => { 'fixture' => RESTART_FIXTURE }.freeze,
            'steps' => [
              {
                'id' => 'M3',
                'task' => 'Create the restart fixture file using the exact create_file arguments supplied ' \
                          'below. Keep this single create_file request logically stable because the ' \
                          'worker may be interrupted immediately after its effect is journaled. On ' \
                          'restart, resume from the durable checkpoint using the journaled result ' \
                          'without re-journaling the effect, then summarize the recovery.'
              }.freeze,
              {
                'id' => 'M4',
                'task' => 'After the worker restarts, resume from the durable checkpoint and complete ' \
                          'only from the journaled create_file result. Do not re-journal the effect; ' \
                          'summarize the recovery.'
              }.freeze
            ].freeze,
            'oracle' => T3M3M4Oracle
          }.freeze
        }.freeze

        class << self
          def definitions
            DEFINITIONS
          end

          def implemented?(scenario_id)
            DEFINITIONS.key?(String(scenario_id))
          end

          def oracle(scenario_id:, **arguments)
            definition(scenario_id).fetch('oracle').call(**arguments)
          end

          def definition(scenario_id)
            DEFINITIONS.fetch(String(scenario_id))
          end
        end

        def initialize(adapter:, scenario: SCENARIO_ID)
          @adapter = adapter
          @scenario = self.class.definition(scenario)
          required = %i[prepare! result_for evidence_for thread_id_for enqueue! worker!]
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

        def fixture_path
          relative_path = restart_scenario? ? RESTART_FIXTURE_PATH : FIXTURE_PATH
          File.join(@adapter.workspace, relative_path)
        end

        def prepare_fixture
          FileUtils.mkdir_p(File.dirname(fixture_path))
          return write_status_fixture unless restart_scenario?

          prepare_restart_fixture
        end

        def write_status_fixture
          write_fixture(definition.fetch('setup').fetch('fixture').fetch('status'))
        end

        def prepare_restart_fixture
          remove_owned_restart_fixture
          raise Tamoz::Evals::ExecutionError, 'restart_fixture_already_exists' if
            File.exist?(fixture_path) || File.symlink?(fixture_path)
        end

        # Exact known bytes are the ownership marker; anything else stays protected.
        def remove_owned_restart_fixture
          return if File.symlink?(fixture_path)
          return unless File.file?(fixture_path)
          return unless restart_fixture_owned?

          File.delete(fixture_path)
        end

        def restart_fixture_owned?
          File.binread(fixture_path) == RESTART_FIXTURE_CONTENT
        rescue SystemCallError
          false
        end

        def write_fixture(status)
          File.binwrite(fixture_path, fixture_bytes(status))
        end

        def fixture_bytes(status)
          "#{JSON.generate('status' => status)}\n"
        end

        def contradicted_digest
          status = definition.fetch('steps').fetch(1).fetch('fixture').fetch('status')
          Digest::SHA256.hexdigest(fixture_bytes(status))
        end

        def drive(thread:, provider:, model:, goal:)
          definition.fetch('steps').each do |step|
            fixture = step['fixture']
            write_fixture(fixture.fetch('status')) if fixture
            task = "#{goal}\n\n#{step.fetch('task')}"
            enqueue_and_work(thread:, provider:, model:, task:)
          end
        end

        def drive_restart(thread:, provider:, model:, goal:)
          step = definition.fetch('steps').fetch(0)
          task = restart_task(goal, step)
          @adapter.enqueue!(thread, task, provider:, model:)
          pre_kill_effect_key = @adapter.worker_until_effect!(
            thread:, provider:, model:, operation: 'tool.create_file'
          )
          @adapter.worker_subprocess!(provider:, model:)
          pre_kill_effect_key
        end

        def restart_task(goal, step)
          fixture = definition.fetch('setup').fetch('fixture')
          arguments = JSON.generate(fixture)
          "#{goal}\n\n#{step.fetch('task')} Use these exact create_file arguments: #{arguments}."
        end

        def restart_scenario?
          definition.fetch('id') == RESTART_SCENARIO_ID
        end

        def enqueue_and_work(thread:, provider:, model:, task:)
          @adapter.enqueue!(thread, task, provider:, model:)
          @adapter.worker!(provider:, model:)
        end

        def prepare_run(provider:, model:)
          @adapter.prepare!(provider:, model:)
          @adapter.prepare_changes! if restart_scenario?
          prepare_fixture
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
          oracle = self.class.oracle(scenario_id: @scenario.fetch('id'), **arguments)
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
            { evidence:, post_contradiction_digest: contradicted_digest, stale_value: INITIAL_STATUS }
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
