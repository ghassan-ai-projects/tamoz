# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteScenarioDriver
        VERSION = 1
        MAX_PATH_BYTES = 4_096
        def initialize(
          scenario_registry:,
          boundary_registry:,
          definition:,
          runtime_inputs:
        )
          unless scenario_registry.instance_of?(SQLiteScenarioRegistry)
            raise ExecutionError,
                  "SQLite scenario registry contract is invalid"
          end
          scenario_registry.verify_boundary_registry!(boundary_registry)
          @scenario_registry = scenario_registry
          @boundary_registry = boundary_registry
          @definition = validate_definition!(definition)
          @runtime_inputs = runtime_inputs
          freeze
        end

        attr_reader :definition

        def digest
          CanonicalJSON.content_digest(
            @definition,
            domain: "eval.sqlite_scenario_driver"
          )
        end

        def trace(scenario_id:, path:, subject:)
          definition = @scenario_registry.fetch(scenario_id)
          recorder = SQLiteTraceRecorder.new(
            scenario: @scenario_registry.reference(scenario_id),
            operation: definition.fetch("operation"),
            subject:,
            registry: @boundary_registry
          )
          run(scenario_id:, path:, observer: recorder)
          manifest = recorder.finish
          @scenario_registry.verify_manifest!(
            manifest,
            boundary_registry: @boundary_registry
          )
        end

        def run(scenario_id:, path:, observer:)
          primary_error = nil
          definition = @scenario_registry.fetch(scenario_id)
          database_path = validate_path!(path)
          unless observer.respond_to?(:call)
            raise ExecutionError, "SQLite scenario observer is invalid"
          end

          gate = SQLiteScenarioFaultGate.new
          runtime = SQLiteScenarioRuntime.new(
            definition:,
            path: database_path,
            fault_injector: gate,
            runtime_inputs: @runtime_inputs
          )
          runtime.setup!
          observer.arm! if observer.respond_to?(:arm!)
          gate.arm!(observer)
          result = runtime.action!
          gate.finish!
          result
        rescue ExecutionError => error
          primary_error = error
          raise
        rescue StandardError => error
          primary_error = error
          raise ExecutionError.new(
            "SQLite scenario failed: #{error.class}: #{error.message}"
          ), cause: error
        ensure
          begin
            runtime&.close
          rescue StandardError
            raise unless primary_error
          end
        end

        private

        def validate_path!(value)
          unless valid_path_shape?(value)
            raise ExecutionError, "SQLite scenario path is invalid"
          end
          if File.exist?(value) || File.symlink?(value)
            raise ExecutionError, "SQLite scenario path must be absent"
          end
          unless private_parent?(File.dirname(value))
            raise ExecutionError,
                  "SQLite scenario parent must be private and owned"
          end
          value.dup.freeze
        rescue Errno::ENOENT, Errno::ELOOP => error
          raise ExecutionError.new(
            "SQLite scenario parent is invalid"
          ), cause: error
        end

        def valid_path_shape?(value)
          value.is_a?(String) &&
            value.valid_encoding? &&
            !value.empty? &&
            value.bytesize <= MAX_PATH_BYTES &&
            File.absolute_path(value) == value
        end

        def private_parent?(parent)
          stat = File.lstat(parent)
          stat.directory? &&
            stat.uid == Process.euid &&
            (stat.mode & 0o077).zero?
        end

        def validate_definition!(value)
          unless value.is_a?(Hash) &&
                 value.fetch("graph").is_a?(Hash) &&
                 value.fetch("limits").is_a?(Hash)
            raise ExecutionError, "SQLite scenario driver definition is invalid"
          end
          DeepFreeze.call(value)
        rescue KeyError, TypeError
          raise ExecutionError, "SQLite scenario driver definition is invalid"
        end

      end

    end
  end
end
