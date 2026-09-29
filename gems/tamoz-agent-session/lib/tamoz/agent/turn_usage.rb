# frozen_string_literal: true

module Tamoz
  module Agent
    # Separates parent request usage from completed child usage in a work trace.
    # :reek:DuplicateMethodCall :reek:NestedIterators :reek:TooManyStatements
    # Each count reads the same bounded trace and the same three reporting fields.
    module TurnUsage
      FIELDS = %w[model_calls prompt_tokens completion_tokens].freeze

      module_function

      def summarize(trace)
        parent = trace.select { |event| event['event'] == 'request' }
        children = trace.select { |event| event['event'] == 'subagent_finished' }
        parent_usage = parent_usage(parent)
        child_usage = FIELDS.to_h { |field| [field, children.sum { |event| event.fetch(field) }] }
        { 'parent' => parent_usage, 'children' => child_usage,
          'total' => FIELDS.to_h { |field| [field, parent_usage.fetch(field) + child_usage.fetch(field)] } }
      end

      def parent_usage(parent)
        {
          'model_calls' => parent.length,
          'prompt_tokens' => parent.sum { |event| event['usage'].to_h.fetch('prompt_tokens', 0) },
          'completion_tokens' => parent.sum { |event| event['usage'].to_h.fetch('output_tokens', 0) }
        }
      end
    end
  end
end
