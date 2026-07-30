# frozen_string_literal: true

module Tamoz
  module SQLite
    module FaultHook
      VERSION = 1

      module_function

      def transaction(operation:, attempt:)
        metadata(
          kind: "transaction",
          operation:,
          statement: nil,
          attempt:
        )
      end

      def statement(operation:, statement:, attempt:)
        metadata(
          kind: "statement",
          operation:,
          statement:,
          attempt:
        )
      end

      def metadata(kind:, operation:, statement:, attempt:)
        {
          "hook_version" => VERSION,
          "kind" => String(kind).dup.freeze,
          "operation" => String(operation).dup.freeze,
          "statement" => statement && String(statement).dup.freeze,
          "attempt" => attempt
        }.freeze
      end
      private_class_method :metadata

      private_constant :VERSION
    end

    private_constant :FaultHook
  end
end
