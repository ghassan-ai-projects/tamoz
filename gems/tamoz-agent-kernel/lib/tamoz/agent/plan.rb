# frozen_string_literal: true

module Tamoz
  module Agent
    Step = Data.define(:id, :purpose, :tool, :arguments, :verification) do
      def initialize(id:, purpose:, tool:, arguments:, verification:)
        unless tool.nil? || tool.is_a?(String)
          raise ProtocolError, "plan step tool must be a string or null"
        end
        raise ProtocolError, "plan step arguments must be an object" unless arguments.is_a?(Hash)

        super(
          id: Tamoz::Core.string(id, name: "plan step id"),
          purpose: Tamoz::Core.string(purpose, name: "plan step purpose"),
          tool: tool&.dup&.freeze,
          arguments: Tamoz::Core.deep_freeze(arguments),
          verification: Tamoz::Core.string(verification, name: "plan step verification")
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
        document = Tamoz::Core.parse_object(value)
        raw_steps = document.fetch("steps")
        raise ProtocolError, "plan steps must be an array" unless raw_steps.is_a?(Array)

        steps = raw_steps.map { |entry| parse_step(entry) }
        raise ProtocolError, "plan exceeds #{MAX_STEPS} steps" if steps.length > MAX_STEPS

        new(
          goal: document.fetch("goal"),
          done_when: document.fetch("done_when"),
          steps:
        )
      rescue KeyError, TypeError => error
        raise ProtocolError, "invalid plan: #{error.message}"
      end

      def self.parse_step(entry)
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
      private_class_method :parse_step

      def initialize(goal:, done_when:, steps:)
        super(
          goal: Tamoz::Core.string(goal, name: "plan goal"),
          done_when: Tamoz::Core.strings(done_when, name: "plan done_when"),
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
