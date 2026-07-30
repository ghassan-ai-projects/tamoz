# frozen_string_literal: true

module Tamoz
  module Notifier
    class Null
      def instrument(_name, _payload = {})
        return yield if block_given?

        false
      end

      INSTANCE = new.freeze
    end
  end
end
