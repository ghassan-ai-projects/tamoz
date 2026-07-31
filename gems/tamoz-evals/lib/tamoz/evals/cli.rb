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
        scorecard_factory: -> { Harness::AgentSmokeScorecard.new }
      )
        new(out:, err:, scorecard_factory:).run(argv)
      end

      def initialize(out:, err:, scorecard_factory:)
        @out = out
        @err = err
        @scorecard_factory = scorecard_factory
      end

      def run(argv)
        return help if argv == ["--help"] || argv == ["-h"]
        return version if argv == ["--version"]

        command, *paths = argv
        return scorecard(paths) if command == "scorecard"
        return usage("expected: tamoz-eval verify ARTIFACT...") unless command == "verify" && !paths.empty?

        codes = paths.map { |path| verify_path(path) }
        EXIT_PRECEDENCE.find { |code| codes.include?(code) } || SUCCESS
      end

      private

      def scorecard(arguments)
        return usage("expected: tamoz-eval scorecard agent-smoke") unless arguments == ["agent-smoke"]

        report = @scorecard_factory.call.run
        @out.puts(report.to_json)
        report.passed? ? SUCCESS : GATE_FAILURE
      rescue InvalidArtifactError => error
        @err.puts("agent-smoke: invalid evidence: #{error.message}")
        INVALID_EVIDENCE
      rescue ExecutionError => error
        @err.puts("agent-smoke: infrastructure failure: #{error.message}")
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
