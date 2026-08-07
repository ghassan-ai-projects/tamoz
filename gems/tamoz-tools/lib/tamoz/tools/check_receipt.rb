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
