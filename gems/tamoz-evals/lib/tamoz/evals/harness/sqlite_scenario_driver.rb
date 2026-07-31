# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteScenarioDriver
        VERSION = 1
        MAX_PATH_BYTES = 4_096
        DEFINITION = DeepFreeze.call(
          {
            "id" => "tamoz.sqlite.scenario_driver",
            "version" => VERSION,
            "scenario_limit" => SQLiteScenarioRegistry::MAX_SCENARIOS,
            "path_policy" => "fresh-absolute-private-parent",
            "bootstrap_policy" => "fault-gate-disarmed",
            "arming_policy" => "immediately-before-one-direct-operation",
            "background_threads" => "prohibited",
            "running_recovery_fixture" =>
              "atomic-start-checkpoint-and-request-transition",
            "pending_outcome_routing" =>
              "static-edge-without-dynamic-goto",
            "fixture_graph" => {
              "name" => "tamoz-eval-sqlite-phase2",
              "version" => "1",
              "channels" => %w[value events],
              "nodes" => ["work"]
            },
            "fixture_limits" => {
              "requests" => 1,
              "lease_acquisitions" => 2,
              "setup_checkpoints" => 2,
              "subject_checkpoints" => 1,
              "tasks" => 1,
              "pending_writes" => 2,
              "consumed_tasks" => 1
            }
          }
        )
        DEFINITION_DIGEST = CanonicalJSON.content_digest(
          DEFINITION,
          domain: "eval.sqlite_scenario_driver"
        ).freeze

        class << self
          def definition
            DEFINITION
          end

          def digest
            DEFINITION_DIGEST
          end
        end

        def initialize(scenario_registry:, boundary_registry:)
          unless scenario_registry.instance_of?(SQLiteScenarioRegistry)
            raise ExecutionError,
                  "SQLite scenario registry contract is invalid"
          end
          scenario_registry.verify_boundary_registry!(boundary_registry)
          @scenario_registry = scenario_registry
          @boundary_registry = boundary_registry
          freeze
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
            fault_injector: gate
          )
          runtime.setup!
          observer.arm! if observer.respond_to?(:arm!)
          gate.arm!(observer)
          result = runtime.action!
          gate.finish!
          result
        rescue ExecutionError
          primary_error = $!
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
          unless value.is_a?(String) &&
                 value.valid_encoding? &&
                 !value.empty? &&
                 value.bytesize <= MAX_PATH_BYTES &&
                 File.absolute_path(value) == value
            raise ExecutionError, "SQLite scenario path is invalid"
          end
          if File.exist?(value) || File.symlink?(value)
            raise ExecutionError, "SQLite scenario path must be absent"
          end
          parent = File.dirname(value)
          stat = File.lstat(parent)
          unless stat.directory? &&
                 stat.uid == Process.euid &&
                 (stat.mode & 0o077).zero?
            raise ExecutionError,
                  "SQLite scenario parent must be private and owned"
          end
          value.dup.freeze
        rescue Errno::ENOENT, Errno::ELOOP => error
          raise ExecutionError.new(
            "SQLite scenario parent is invalid"
          ), cause: error
        end

        private_constant :DEFINITION, :DEFINITION_DIGEST, :MAX_PATH_BYTES
      end

      private_constant :SQLiteScenarioDriver
    end
  end
end
