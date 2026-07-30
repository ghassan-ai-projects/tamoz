# frozen_string_literal: true

module Tamoz
  module Evals
    module DeepFreeze
      module_function

      def call(value)
        case value
        when Hash
          value.each { |key, entry| call(key); call(entry) }
        when Array
          value.each { |entry| call(entry) }
        end

        value.freeze
      end
    end
  end
end
