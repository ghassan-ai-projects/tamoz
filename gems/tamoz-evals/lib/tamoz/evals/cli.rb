# frozen_string_literal: true

require "json"

module Tamoz
  module Evals
    class CLI
      SUCCESS = 0
      GATE_FAILURE = 1
      INVALID_EVIDENCE = 2
      INFRASTRUCTURE_FAILURE = 3
      INSUFFICIENT_EVIDENCE = 4
      USAGE_ERROR = 64

      DECISION_CODES = {
        "verified" => SUCCESS,
        "pass" => SUCCESS,
        "fail" => GATE_FAILURE,
        "invalid" => INVALID_EVIDENCE,
        "infrastructure_failure" => INFRASTRUCTURE_FAILURE,
        "insufficient_evidence" => INSUFFICIENT_EVIDENCE
      }.freeze
      EXIT_PRECEDENCE = [
        INVALID_EVIDENCE,
        INFRASTRUCTURE_FAILURE,
        INSUFFICIENT_EVIDENCE,
        GATE_FAILURE,
        SUCCESS
      ].freeze

      def self.run(
        argv,
        out: $stdout,
        err: $stderr,
        scorecard_factory: -> { Harness::AgentSmokeScorecard.new },
        treatment_factory: nil
      )
        new(out:, err:, scorecard_factory:, treatment_factory:).run(argv)
      end

      def initialize(out:, err:, scorecard_factory:, treatment_factory: nil)
        @out = out
        @err = err
        @scorecard_factory = scorecard_factory
        @treatment_factory = treatment_factory
      end

      def run(argv)
        return help if argv == ["--help"] || argv == ["-h"]
        return version if argv == ["--version"]

        command, *paths = argv
        return scorecard(paths) if command == "scorecard"
        return treatment(paths) if command == "treatment"
        return usage("expected: tamoz-eval verify ARTIFACT...") unless command == "verify" && !paths.empty?

        codes = paths.map { |path| verify_path(path) }
        EXIT_PRECEDENCE.find { |code| codes.include?(code) } || SUCCESS
      end

      private

      # DR-3: the treatment profile evaluator. CI mode is the reproducible gate
      # (injection correctness). Live mode is an operator-run (`TAMOZ_MEMORY_LIVE`)
      # with a library-supplied adapter; the CLI refuses to fake it.
      def treatment(arguments)
        unless arguments == ["memory"] || arguments == ["memory", "--mode", "ci"]
          return usage(
            "expected: tamoz-eval treatment memory (live attribution is an " \
            "operator-run via MemoryTreatmentProfile with a live_adapter)"
          )
        end

        factory = @treatment_factory || -> { Harness::MemoryTreatmentProfile.new(mode: :ci) }
        run_gate("treatment memory") { factory.call.run }
      end

      def scorecard(arguments)
        return usage("expected: tamoz-eval scorecard agent-smoke") unless arguments == ["agent-smoke"]

        run_gate("agent-smoke") { @scorecard_factory.call.run }
      end

      def run_gate(label)
        report = yield
        @out.puts(report.to_json)
        report.passed? ? SUCCESS : GATE_FAILURE
      rescue InvalidArtifactError => error
        @err.puts("#{label}: invalid evidence: #{error.message}")
        INVALID_EVIDENCE
      rescue ExecutionError => error
        @err.puts("#{label}: infrastructure failure: #{error.message}")
        INFRASTRUCTURE_FAILURE
      end

      def verify_path(path)
        verification = Verifier.new.verify(path)
        @out.puts(
          JSON.generate(
            "artifact_type" => verification.artifact_type,
            "decision" => verification.decision,
            "digest" => verification.digest,
            "path" => verification.path
          )
        )
        DECISION_CODES.fetch(verification.decision)
      rescue InvalidArtifactError => error
        @err.puts("#{path}: invalid evidence: #{error.message}")
        INVALID_EVIDENCE
      rescue SystemCallError => error
        @err.puts("#{path}: infrastructure failure: #{error.message}")
        INFRASTRUCTURE_FAILURE
      end

      def help
        @out.puts("Usage: tamoz-eval verify ARTIFACT...")
        @out.puts("       tamoz-eval scorecard agent-smoke")
        @out.puts("       tamoz-eval treatment memory")
        @out.puts("       tamoz-eval --version")
        SUCCESS
      end

      def version
        @out.puts(Tamoz::Evals::VERSION)
        SUCCESS
      end

      def usage(message)
        @err.puts(message)
        USAGE_ERROR
      end
    end
  end
end
