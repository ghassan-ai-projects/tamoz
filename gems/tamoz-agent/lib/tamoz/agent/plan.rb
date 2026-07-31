# frozen_string_literal: true

require "json"

module Tamoz
  module Agent
    Step = Data.define(:id, :purpose, :tool, :arguments, :verification) do
      def initialize(id:, purpose:, tool:, arguments:, verification:)
        unless tool.nil? || tool.is_a?(String)
          raise ProtocolError, "plan step tool must be a string or null"
        end
        raise ProtocolError, "plan step arguments must be an object" unless arguments.is_a?(Hash)

        super(
          id: Plan.string(id, name: "plan step id"),
          purpose: Plan.string(purpose, name: "plan step purpose"),
          tool: tool&.dup&.freeze,
          arguments: Plan.deep_freeze(arguments),
          verification: Plan.string(verification, name: "plan step verification")
        )
      end

      def to_h
        {
          "id" => id,
          "purpose" => purpose,
          "tool" => tool,
          "arguments" => arguments,
          "verification" => verification
        }
      end
    end

    Plan = Data.define(:goal, :done_when, :steps) do
      MAX_STEPS = 12

      def self.parse(value)
        document = parse_object(value)
        raw_steps = document.fetch("steps")
        raise ProtocolError, "plan steps must be an array" unless raw_steps.is_a?(Array)

        steps = raw_steps.map do |entry|
          unless entry.is_a?(Hash)
            raise ProtocolError, "each plan step must be an object"
          end

          Step.new(
            id: entry.fetch("id"),
            purpose: entry.fetch("purpose"),
            tool: entry["tool"],
            arguments: entry.fetch("arguments", {}),
            verification: entry.fetch("verification")
          )
        end
        raise ProtocolError, "plan exceeds #{MAX_STEPS} steps" if steps.length > MAX_STEPS

        new(
          goal: document.fetch("goal"),
          done_when: document.fetch("done_when"),
          steps:
        )
      rescue KeyError, TypeError => error
        raise ProtocolError, "invalid plan: #{error.message}"
      end

      def self.parse_object(value)
        return value.transform_keys(&:to_s) if value.is_a?(Hash)

        text = String(value).strip
        text = text.delete_prefix("```json").delete_prefix("```").delete_suffix("```").strip
        document = JSON.parse(text)
        raise ProtocolError, "model response must be a JSON object" unless document.is_a?(Hash)

        document
      rescue JSON::ParserError => error
        raise ProtocolError, "model returned invalid JSON: #{error.message}"
      end

      def self.deep_freeze(value)
        case value
        when Hash
          value.to_h { |key, entry| [String(key).dup.freeze, deep_freeze(entry)] }.freeze
        when Array
          value.map { |entry| deep_freeze(entry) }.freeze
        when String
          value.dup.freeze
        when NilClass, TrueClass, FalseClass, Numeric
          value
        else
          raise ProtocolError, "unsupported plan argument #{value.class}"
        end
      end

      def self.string(value, name:)
        raise ProtocolError, "#{name} must be a string" unless value.is_a?(String)

        value.dup.freeze
      end

      def self.strings(value, name:)
        raise ProtocolError, "#{name} must be an array" unless value.is_a?(Array)

        value.map { |entry| string(entry, name: "#{name} entry") }.freeze
      end

      def initialize(goal:, done_when:, steps:)
        super(
          goal: Plan.string(goal, name: "plan goal"),
          done_when: Plan.strings(done_when, name: "plan done_when"),
          steps: steps.freeze
        )
      end

      def to_h
        {
          "goal" => goal,
          "done_when" => done_when,
          "steps" => steps.map(&:to_h)
        }
      end
    end
  end
end
