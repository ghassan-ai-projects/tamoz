# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # One model-facing tool definition in OpenAI function form.
    ToolSchema = Data.define(:name, :description, :parameters) do
      def initialize(name:, description:, parameters:)
        unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9_.-]{1,64}\z/)
          raise Error,
                'tool name must match [A-Za-z0-9_.-]'
        end
        raise Error, "tool #{name} description must be a String" unless description.is_a?(String)
        unless parameters.is_a?(Hash) && parameters['type'] == 'object'
          raise Error, "tool #{name} parameters must be a JSON object schema"
        end

        super(name: name.dup.freeze, description: description.strip.freeze,
              parameters: Tamoz::Core.deep_freeze(Tamoz::Core.canonical(parameters)))
      end

      def to_wire
        { 'type' => 'function',
          'function' => { 'name' => name, 'description' => description, 'parameters' => parameters } }
      end
    end
  end
end
