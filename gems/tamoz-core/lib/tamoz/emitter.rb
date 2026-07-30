# frozen_string_literal: true

module Tamoz
  module Emitter
    class Null
      def emit(_type, _namespace, _data = {}, run_id: nil, task_id: nil)
        false
      end

      INSTANCE = new.freeze
    end
  end
end
