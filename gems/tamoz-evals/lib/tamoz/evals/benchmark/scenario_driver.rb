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

        # Scores the contradiction from journaled tool and terminal evidence.
        class T3M1M2Oracle
          class << self
            def call(evidence:, post_contradiction_digest:, stale_value:, second_observation_ref: nil)
              evidence = {} unless evidence.is_a?(Hash)
              second_ref = second_observation_ref || Array(evidence['observation_refs']).last
              verification = evidence['verification']
              verification_refs = verification['evidence'] if verification.is_a?(Hash)
              expected_digest = normalize_digest(post_contradiction_digest)
              recovery = recovery_metric(evidence, expected_digest, second_ref, verification_refs)
              false_success = false_success_status(evidence, stale_value)
              {
                'metrics' => { 'recovery' => recovery },
                'hard_zero' => { 'false_success' => false_success },
                'hard_zero_reasons' => hard_zero_reasons(false_success)
              }
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
              explicit = receipt['content_digest'] || receipt['observation_digest'] || receipt['digest']
              return explicit if explicit

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
              case status
              when 'failed' then ['hard_zero_failed:false_success']
              when 'unknown' then ['hard_zero_unverifiable:false_success']
              else []
              end
            end

            def normalize_digest(value)
              digest = value.to_s.delete_prefix('sha256:').downcase
              digest if digest.match?(/\A[0-9a-f]{64}\z/)
            end
          end
        end

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
          unless adapter.respond_to?(:prepare!) && adapter.respond_to?(:result_for) &&
                 adapter.respond_to?(:evidence_for) && adapter.respond_to?(:thread_id_for) &&
                 adapter.respond_to?(:enqueue!) && adapter.respond_to?(:worker!)
            raise ArgumentError, 'scenario adapter does not expose the durable session seams'
          end
        end

        # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one executor transaction owns the two moments and final evidence join.
        def call(mission:, run_kind:, provider:, model:)
          return @adapter.call(mission:, run_kind:, provider:, model:) unless
            mission.fetch('id') == @scenario.fetch('mission_id')
          raise ArgumentError, 'scenario driver only supports real_provider runs' unless
            run_kind == 'real_provider'

          provider = String(provider)
          model = String(model)
          @adapter.prepare!(provider:, model:)
          materialize_fixture
          thread = @adapter.thread_id_for(mission.fetch('id'))
          drive(thread:, provider:, model:, goal: mission.fetch('goal'))
          evidence = @adapter.evidence_for(thread:, provider:, model:)
          oracle = self.class.oracle(
            scenario_id: @scenario.fetch('id'),
            evidence:,
            post_contradiction_digest: contradicted_digest,
            stale_value: INITIAL_STATUS
          )
          @adapter.result_for(
            mission:, provider:, model:, thread:, evidence:,
            hard_zero_overrides: oracle.fetch('hard_zero'),
            hard_zero_reasons: oracle.fetch('hard_zero_reasons'),
            metric_overrides: oracle.fetch('metrics')
          )
        rescue Tamoz::Evals::ExecutionError => e
          blocked_result(mission, e.message)
        end
        # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

        private

        def definition
          @scenario
        end

        def fixture_path
          File.join(@adapter.workspace, FIXTURE_PATH)
        end

        def materialize_fixture
          FileUtils.mkdir_p(File.dirname(fixture_path))
          write_fixture(definition.fetch('setup').fetch('fixture').fetch('status'))
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

        def enqueue_and_work(thread:, provider:, model:, task:)
          @adapter.enqueue!(thread, task, provider:, model:)
          @adapter.worker!(provider:, model:)
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
