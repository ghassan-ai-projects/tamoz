# frozen_string_literal: true

module Tamoz
  module Harness
    # Parses the assistant's native tool calls against the fixed tool surface of the series.
    module ToolCalls
      MAX_PER_STEP = 8

      # One parsed call; `error` is fed back to the model instead of executing.
      Call = Data.define(:id, :name, :arguments, :error) do
        def ok? = error.nil?
      end

      module_function

      def parse(calls, allowed:)
        calls.each_with_index.map do |call, index|
          id = call.fetch('id')
          name = call.fetch('name')
          next Call.new(id:, name:, arguments: {}, error: "too many tool calls in one step (max #{MAX_PER_STEP})") if
            index >= MAX_PER_STEP

          parse_one(id, name, call.fetch('arguments'), allowed)
        end
      end

      def parse_one(id, name, raw, allowed)
        return Call.new(id:, name:, arguments: {}, error: "unknown tool #{name.inspect}") unless allowed.include?(name)

        arguments = raw.to_s.strip.empty? ? {} : JSON.parse(raw, allow_duplicate_key: false)
        unless arguments.is_a?(Hash)
          return Call.new(id:, name:, arguments: {},
                          error: 'tool arguments must be a JSON object')
        end

        Call.new(id:, name:, arguments: Tamoz::Core.deep_freeze(arguments), error: nil)
      rescue JSON::ParserError => e
        Call.new(id:, name:, arguments: {}, error: "tool arguments are not valid JSON: #{e.message.lines.first.strip}")
      end
      private_class_method :parse_one
    end
  end
end
