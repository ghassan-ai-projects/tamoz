# frozen_string_literal: true

require 'json'

module Tamoz
  module Evals
    module Runner
      # P13-P (plan §8) — the one safe recurring product task: a READ-ONLY
      # scorecard summary. The consumer reruns the deterministic agent-smoke
      # scorecard and emits a summary through the ordinary delivery policy.
      #
      # Pinned surface (C8): the grant for this consumer contains ONLY the
      # scorecard-run capability (the `tamoz-eval-runner scorecard agent-smoke`
      # subprocess invocation), NO mutation tools; risk class is read-only; the
      # approval policy is deterministic and read-only-only; delivery is ordinary
      # and never reported as execution success (the occurrence's enqueued state
      # is delivery, not execution).
      #
      # The consumer is deliberately tiny and dependency-light: it runs one
      # subprocess, validates the JSON report shape, and returns a summary
      # hash. Everything else (durability, dedup, grant intersection) is the
      # ScheduleStore's job.
      class ScorecardSummaryConsumer
        READ_ONLY_GRANT = {
          'scopes' => ['read'],
          'capabilities' => ['eval.scorecard-agent-smoke']
        }.freeze

        def initialize(input_manifest: nil, executor: nil)
          @input_manifest = input_manifest || ENV.fetch('TAMOZ_RUNNER_INPUT_MANIFEST', nil)
          @executor = executor
        end

        # The only approved operation: run the deterministic scorecard, read the
        # report, return a summary. `allowlist` is asserted by the consumer
        # grant-allowlist test — this surface has NO mutation tool.
        # :reek:UncommunicativeVariableName -- `e` is the rescue-variable name the
        # linter enforces repository-wide.
        def run(input_manifest: nil)
          command = default_command(input_manifest || @input_manifest)
          return ScorecardResult.failed('runner input manifest is required') unless command

          successful, stdout, stderr, result = execute(command)
          return ScorecardResult.failed(stderr, result:) unless successful

          report = JSON.parse(stdout)
          ScorecardResult.new(report).summary
        rescue JSON::ParserError
          ScorecardResult.invalid_json
        rescue SystemCallError, Tamoz::Evals::ExecutionError => e
          ScorecardResult.unavailable(e)
        end

        def self.grant = READ_ONLY_GRANT

        private

        def execute(command)
          return @executor.call(command) if @executor

          executable = Harness::SubprocessRunner.resolve_executable(
            command.fetch(0), path: ENV.fetch('PATH', '')
          )
          environment = %w[GEM_HOME GEM_PATH LANG LC_ALL PATH TMPDIR TZ].each_with_object({}) do |key, result|
            result[key] = ENV.fetch(key) if ENV.key?(key)
          end
          result = Harness::SubprocessRunner.new(
            root: Dir.pwd,
            environment: environment,
            output_limit_bytes: 1_048_576
          ).capture(
            [executable, *command.drop(1)],
            timeout_ms: 120_000,
            command: 'scheduler.scorecard'
          )
          [result.success?, result.stdout.text, result.stderr.text, result]
        end

        def default_command(input_manifest)
          return unless input_manifest.is_a?(String) && !input_manifest.empty?

          ['tamoz-eval-runner', 'scorecard', 'agent-smoke',
           '--input-manifest', input_manifest]
        end
      end
    end
  end
end
