# frozen_string_literal: true

module Tamoz
  module Harness
    # Budgets for one work turn and the repeat guard.
    LoopPolicy = Data.define(:max_model_calls, :max_tool_calls, :max_seconds, :remind_at, :stop_at) do
      def self.default = new(max_model_calls: 60, max_tool_calls: 120, max_seconds: 1800, remind_at: [3, 5], stop_at: 8)

      def self.from_h(overrides)
        unknown = overrides.keys.map(&:to_s) - members.map(&:to_s)
        raise Error, "unknown loop policy keys: #{unknown.join(', ')}" unless unknown.empty?

        default.with(**overrides.transform_keys(&:to_sym)).tap(&:validate!)
      end

      # `epoch` counts successful changes: repeating a read or a check after an edit is progress, not a loop.
      def self.signature(name, arguments, epoch: 0)
        Tamoz::Core.digest("tamoz.harness.call.v1\n",
                           { 'name' => name, 'arguments' => Tamoz::Core.canonical(arguments), 'epoch' => epoch })
      end

      def validate!
        counts = [max_model_calls, max_tool_calls, max_seconds, stop_at]
        raise Error, 'loop budgets must be positive integers' unless counts.all? do |value|
          value.is_a?(Integer) && value.positive?
        end
        raise Error, 'remind_at must be integers below stop_at' unless remind_at.all? do |value|
          value.is_a?(Integer) && value < stop_at
        end
      end

      def repeat(previous_signatures, signature)
        count = previous_signatures.count(signature) + 1
        return [:stop, count] if count >= stop_at
        return [:remind, count] if remind_at.include?(count)

        [:ok, count]
      end

      def reminder(tool, count) = format(PromptPack.fetch('repeat_reminder'), tool:, count:)

      def exhausted(model_calls:, tool_calls:, seconds:)
        return 'model_call_budget' if model_calls >= max_model_calls
        return 'tool_call_budget' if tool_calls >= max_tool_calls

        'time_budget' if seconds >= max_seconds
      end
    end
  end
end
