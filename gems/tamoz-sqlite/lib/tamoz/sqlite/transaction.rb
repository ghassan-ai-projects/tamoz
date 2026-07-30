# frozen_string_literal: true

module Tamoz
  module SQLite
    class Transaction
      attr_reader :connection, :operation, :fault_injector

      def initialize(connection:, operation:, fault_injector:)
        @connection = connection
        @operation = String(operation).dup.freeze
        @fault_injector = fault_injector
      end

      def execute(label, sql, binds = [])
        statement(label, sql, binds) do
          connection.execute(sql, binds)
        end
      end

      def rows(label, sql, binds = [])
        execute(label, sql, binds)
      end

      def first(label, sql, binds = [])
        statement(label, sql, binds) do
          connection.get_first_row(sql, binds)
        end
      end

      def scalar(label, sql, binds = [])
        statement(label, sql, binds) do
          connection.get_first_value(sql, binds)
        end
      end

      def changes
        connection.changes
      end

      private

      def statement(label, sql, binds)
        normalized_label = SafeText.normalize(
          label,
          name: "SQL statement label",
          max_bytes: 128,
          error_class: ConfigurationError
        )
        unless sql.is_a?(String) && !sql.empty?
          raise ConfigurationError, "SQL statement must be a non-empty String"
        end
        unless binds.is_a?(Array)
          raise ConfigurationError, "SQL binds must be an Array"
        end

        inject(:before_sql, normalized_label)
        result = yield
        inject(:after_sql, normalized_label)
        result
      end

      def inject(point, label)
        fault_injector.call(
          point,
          {
            "operation" => operation,
            "statement" => label
          }.freeze
        )
      end
    end
  end
end
