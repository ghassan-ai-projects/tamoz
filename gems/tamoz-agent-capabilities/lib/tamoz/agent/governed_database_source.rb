# frozen_string_literal: true

require 'delegate'

module Tamoz
  module Agent
    # Read-first database access over the existing supervised MCP source. This
    # wrapper narrows an operator-owned source; it does not open a second
    # database connection or execute SQL against Tamoz's own state.
    class GovernedDatabaseSource < SimpleDelegator
      MAX_QUERY_BYTES = 4 * 1024
      MAX_ROWS = 1_000
      READ_ONLY = /\A\s*(?:SELECT|WITH|EXPLAIN)\b/i
      WRITE_KEYWORDS = /\b(?:INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|ATTACH|DETACH|REPLACE|VACUUM|PRAGMA)\b/i
      Policy = Data.define(:server_id, :max_rows) do
        def validate(arguments)
          GovernedDatabaseSource.validate_arguments(arguments, max_rows:)
        end
      end

      def self.policy(server_id:, max_rows: MAX_ROWS)
        Policy.new(server_id: normalize_server_id(server_id), max_rows: normalize_max_rows(max_rows))
      end

      def initialize(source:, server_id:, max_rows: MAX_ROWS)
        @source = source
        @server_id = self.class.normalize_server_id(server_id)
        @max_rows = self.class.normalize_max_rows(max_rows)

        super(source)
      end

      def names
        @source.names.select { |name| String(name).start_with?("mcp:#{@server_id}/") }
      end

      def validate(arguments)
        self.class.validate_arguments(arguments, max_rows: @max_rows)
      end

      def self.validate_arguments(arguments, max_rows:)
        validate_arguments_shape(arguments)
        query = validate_query(arguments.fetch('query', nil))

        {
          'query' => query,
          'max_rows' => validate_max_rows(arguments.fetch('max_rows', max_rows), max_rows)
        }
      rescue KeyError, ArgumentError => e
        raise Tamoz::Agent::ToolArgumentError, "invalid database query options: #{e.message}"
      end

      def self.validate_arguments_shape(arguments)
        return if arguments.is_a?(Hash)

        raise Tamoz::Agent::ToolArgumentError, 'database query options must be an object'
      end

      def self.validate_query(query)
        valid = query.is_a?(String) && !query.empty? && query.bytesize <= MAX_QUERY_BYTES
        raise Tamoz::Agent::ToolArgumentError, 'database query must be a non-empty bounded string' unless valid
        unless !query.include?(';') && !query.match?(WRITE_KEYWORDS) && query.match?(READ_ONLY)
          raise Tamoz::Agent::ToolPolicyError, 'database source permits one read-only query only'
        end

        query
      end

      def self.validate_max_rows(value, maximum)
        rows = Integer(value)
        raise ArgumentError, 'database max_rows must be positive' unless rows.positive?

        [rows, maximum].min
      end
      private_class_method :validate_max_rows

      def self.normalize_server_id(server_id)
        normalized = String(server_id)
        raise ArgumentError, 'database server_id must not be empty' if normalized.empty?

        normalized
      end
      private_class_method :normalize_server_id

      def self.normalize_max_rows(max_rows)
        normalized = Integer(max_rows)
        unless normalized.between?(1, MAX_ROWS)
          raise ArgumentError, "database max_rows must be between 1 and #{MAX_ROWS}"
        end

        normalized
      end
      private_class_method :normalize_max_rows

      def execute(context, capability_id, arguments)
        name = String(capability_id)
        unless names.include?(name)
          raise Tamoz::Agent::ToolPolicyError, "database capability is not admitted: #{name.inspect}"
        end

        @source.execute(context, name, validate(arguments))
      end
    end
  end
end
