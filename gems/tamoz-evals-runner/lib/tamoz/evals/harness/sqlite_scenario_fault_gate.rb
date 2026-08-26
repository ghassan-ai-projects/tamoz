# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteScenarioFaultGate
        def initialize
          @owner_process = Process.pid
          @owner_thread = Thread.current
          @state = :bootstrap
          @observer = nil
        end

        def arm!(observer)
          ensure_owner!
          unless @state == :bootstrap && observer.respond_to?(:call)
            raise ExecutionError, "SQLite scenario fault gate cannot be armed"
          end
          @observer = observer
          @state = :armed
          self
        end

        def call(point, metadata)
          ensure_owner!
          return nil if @state == :bootstrap
          unless @state == :armed
            raise ExecutionError, "SQLite scenario fault gate is not armed"
          end

          @observer.call(point, metadata)
        end

        def finish!
          ensure_owner!
          unless @state == :armed
            raise ExecutionError, "SQLite scenario fault gate cannot finish"
          end
          @state = :finished
          @observer.finish! if @observer.respond_to?(:finish!)
          true
        end

        private

        def ensure_owner!
          unless Process.pid == @owner_process &&
                 Thread.current.equal?(@owner_thread)
            raise ExecutionError,
                  "SQLite scenario fault gate changed process or thread"
          end
        end
      end

      private_constant :SQLiteScenarioFaultGate
    end
  end
end
