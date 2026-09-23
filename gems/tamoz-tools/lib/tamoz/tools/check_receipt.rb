# frozen_string_literal: true

require 'digest'
require 'json'

module Tamoz
  module Tools
    # Immutable result of one configured check, including its stable failure
    # signature and operator-facing rendering.
    # :reek:UtilityFunction — output normalization defines this receipt's digest.
    CheckReceipt = Data.define(:name, :outcome, :stdout, :stderr) do
      def initialize(name:, outcome:, stdout:, stderr:)
        super(
          name: String(name).dup.freeze,
          outcome: String(outcome).dup.freeze,
          stdout: String(stdout).dup.freeze,
          stderr: String(stderr).dup.freeze
        )
      end

      def passed? = outcome == 'exit_0'
      def failed? = !passed?

      def failure_signature
        return nil if passed?

        Digest::SHA256.hexdigest(
          JSON.generate(
            'name' => name,
            'outcome' => outcome,
            'stdout' => normalized_output(stdout),
            'stderr' => normalized_output(stderr)
          )
        )
      end

      def to_s
        <<~TEXT.chomp
          Check #{name}: #{outcome}
          stdout:
          #{stdout}
          stderr:
          #{stderr}
        TEXT
      end

      # The model-facing rendering: a pass is its name and the output's last lines; a
      # failure keeps everything (large output is spilled by the caller, never cut here).
      def shaped(tail_lines: 5)
        return to_s if failed?

        tail = normalized_output(stdout).lines.last(tail_lines).join.rstrip
        tail.empty? ? "Check #{name}: #{outcome} (passed)" : "Check #{name}: #{outcome} (passed)\n#{tail}"
      end

      private

      def normalized_output(value)
        value
          .gsub(%r{\e\[[0-?]*[ -/]?[@-~]}, '')
          .gsub("\r\n", "\n")
          .lines
          .map(&:rstrip)
          .join("\n")
          .strip
      end
    end
  end
end
