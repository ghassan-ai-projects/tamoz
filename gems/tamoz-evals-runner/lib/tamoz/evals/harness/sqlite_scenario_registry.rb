# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteScenarioRegistry
        VERSION = 1
        DEFAULT_MAXIMUM_SCENARIOS = 32
        DEFAULT_FAMILIES = %w[lease request checkpoint].freeze
        DEFAULT_STATE_CLASSES = %w[old new stable].freeze
        MAX_ID_BYTES = 128
        ID_PATTERN = /\A[a-z0-9][a-z0-9._-]*\z/
        TEMPLATE_PATTERN =
          /\A[a-z0-9][a-z0-9._-]*(?:\{index\}[a-z0-9._-]*)?\z/
        SCENARIO_FIELDS = %w[
          id version family operation setup action state_classes contract
          convergence coverage
        ].freeze

        attr_reader :document, :digest

        class << self
          def build(scenarios:, maximum_scenarios: DEFAULT_MAXIMUM_SCENARIOS,
                    families: DEFAULT_FAMILIES, state_classes: DEFAULT_STATE_CLASSES)
            new(scenarios, maximum_scenarios:, families:, state_classes:)
          end

          def from_manifest(manifest)
            scenarios = manifest.scenarios
            registry_document = ExternalInputs.document(
              manifest, scenarios.fetch("registry"), label: "SQLite scenario registry"
            )
            limits = ExternalInputs.document(
              manifest, scenarios.fetch("limits"), label: "SQLite scenario limits"
            )
            build(
              scenarios: registry_document.fetch("scenarios", registry_document),
              maximum_scenarios: limits.fetch("maximum_scenarios"),
              families: limits.fetch("families"),
              state_classes: limits.fetch("state_classes")
            )
          rescue KeyError, TypeError
            raise ExecutionError, "SQLite scenario manifest is incomplete"
          end
        end

        def initialize(scenarios, maximum_scenarios:, families:, state_classes:)
          @maximum_scenarios = bounded_limit(maximum_scenarios)
          @families = normalized_values(families, "scenario families")
          @state_classes = normalized_values(state_classes, "scenario state classes")
          normalized = normalize_scenarios(scenarios)
          @index = normalized.to_h { |scenario| [scenario.fetch("id"), scenario] }.freeze
          @document = DeepFreeze.call(
            {
              "registry_version" => VERSION,
              "maximum_scenarios" => @maximum_scenarios,
              "scenarios" => normalized
            }
          )
          @digest = CanonicalJSON.content_digest(
            @document,
            domain: "eval.sqlite_scenario_registry"
          ).freeze
          freeze
        end

        def scenario(id)
          key = identifier(id, "scenario id")
          @index[key]
        end

        def fetch(id)
          scenario(id) || raise(ExecutionError, "unknown SQLite scenario")
        end

        def reference(id)
          definition = fetch(id)
          DeepFreeze.call(
            {
              "id" => definition.fetch("id"),
              "version" => definition.fetch("version"),
              "digest" => scenario_digest(definition)
            }
          )
        end

        def verify_boundary_registry!(registry)
          validate_boundary_registry!(registry)
          required = required_coverage(registry)
          declared = @document.fetch("scenarios").flat_map do |scenario|
            scenario.fetch("coverage").map do |template|
              [scenario.fetch("operation"), template]
            end
          end.uniq.sort
          unless declared == required
            raise ExecutionError,
                  "SQLite scenario coverage does not equal the Phase 2 registry"
          end
          true
        end

        def verify_manifest!(manifest, boundary_registry:)
          validate_boundary_registry!(boundary_registry)
          verified = SQLiteTraceRecorder.verify_manifest!(
            manifest,
            registry: boundary_registry
          )
          scenario_id = verified.fetch("scenario").fetch("id")
          definition = fetch(scenario_id)
          unless verified.fetch("scenario") == reference(scenario_id)
            raise ExecutionError, "trace scenario reference is invalid"
          end
          operations = verified.fetch("events").map do |event|
            event.fetch("operation")
          end.uniq
          unless operations == [definition.fetch("operation")]
            raise ExecutionError, "trace operation disagrees with its scenario"
          end
          observed = observed_templates(verified, boundary_registry)
          unless observed == definition.fetch("coverage")
            raise ExecutionError,
                  "trace statements disagree with scenario coverage"
          end
          verified
        end

        def verify_trace_union!(manifests, boundary_registry:)
          verify_boundary_registry!(boundary_registry)
          unless manifests.is_a?(Array) &&
                 manifests.length == @document.fetch("scenarios").length &&
                 manifests.length <= @maximum_scenarios
            raise ExecutionError, "SQLite scenario manifest set is incomplete"
          end
          verified = manifests.map do |manifest|
            verify_manifest!(manifest, boundary_registry:)
          end
          ids = verified.map { |manifest| manifest.dig("scenario", "id") }
          expected_ids = @document.fetch("scenarios").map { |scenario| scenario.fetch("id") }
          unless ids.uniq.length == ids.length && ids.sort == expected_ids.sort
            raise ExecutionError,
                  "SQLite scenario manifest identities are incomplete"
          end
          observed = verified.flat_map do |manifest|
            operation = manifest.fetch("events").first.fetch("operation")
            observed_templates(manifest, boundary_registry).map do |template|
              [operation, template]
            end
          end.uniq.sort
          unless observed == required_coverage(boundary_registry)
            raise ExecutionError,
                  "SQLite trace union does not equal required coverage"
          end
          DeepFreeze.call(verified)
        end

        private

        def normalize_scenarios(scenarios)
          unless scenarios.is_a?(Array) &&
                 scenarios.any? &&
                 scenarios.length <= @maximum_scenarios
            raise ExecutionError, "SQLite scenario definitions are invalid"
          end
          normalized = scenarios.map { |scenario| normalize_scenario(scenario) }
          ids = normalized.map { |scenario| scenario.fetch("id") }
          unless ids.uniq.length == ids.length
            raise ExecutionError, "SQLite scenario ids must be unique"
          end
          normalized.sort_by { |scenario| scenario.fetch("id") }.freeze
        end

        def normalize_scenario(value)
          exact_hash!(value, SCENARIO_FIELDS, "SQLite scenario")
          id = identifier(value.fetch("id"), "scenario id")
          version = positive_integer(value.fetch("version"), "scenario version")
          family = identifier(value.fetch("family"), "scenario family")
          unless @families.include?(family)
            raise ExecutionError, "SQLite scenario family is invalid"
          end
          operation = identifier(value.fetch("operation"), "scenario operation")
          setup = identifier(value.fetch("setup"), "scenario setup")
          action = identifier(value.fetch("action"), "scenario action")
          contract = identifier(value.fetch("contract"), "scenario contract")
          convergence = identifier(
            value.fetch("convergence"),
            "scenario convergence"
          )
          state_classes = string_array(
            value.fetch("state_classes"),
            "scenario state classes"
          )
          unless state_classes.any? &&
                 state_classes.uniq.length == state_classes.length &&
                 state_classes.all? { |entry| @state_classes.include?(entry) } &&
                 (state_classes == ["stable"] ||
                  state_classes.sort == %w[new old])
            raise ExecutionError, "SQLite scenario state classes are invalid"
          end
          coverage = template_array(
            value.fetch("coverage"),
            "scenario coverage"
          )
          unless coverage.any? && coverage.uniq.length == coverage.length
            raise ExecutionError, "SQLite scenario coverage is invalid"
          end
          DeepFreeze.call(
            {
              "id" => id,
              "version" => version,
              "family" => family,
              "operation" => operation,
              "setup" => setup,
              "action" => action,
              "state_classes" => state_classes,
              "contract" => contract,
              "convergence" => convergence,
              "coverage" => coverage
            }
          )
        rescue KeyError, TypeError => error
          raise ExecutionError.new(
            "SQLite scenario definition is invalid"
          ), cause: error
        end

        def validate_boundary_registry!(registry)
          required = %i[
            document digest operation phase_operations resolve_statement
          ]
          unless required.all? { |method| registry.respond_to?(method) } &&
                 deeply_frozen?(registry.document)
            raise ExecutionError, "SQLite boundary registry contract is invalid"
          end
          first_digest = registry.digest
          unless Tamoz::Core.valid_digest?(first_digest) &&
                 registry.digest == first_digest
            raise ExecutionError, "SQLite boundary registry digest is invalid"
          end
          @document.fetch("scenarios").each do |scenario|
            operation = registry.operation(scenario.fetch("operation"))
            unless operation &&
                   operation.fetch("phase") == 2 &&
                   operation.fetch("kill_required") == true
              raise ExecutionError,
                    "SQLite scenario operation is not Phase 2 kill-required"
            end
            allowed = operation.fetch("statements").map do |statement|
              statement.fetch("template")
            end
            unless (scenario.fetch("coverage") - allowed).empty?
              raise ExecutionError,
                    "SQLite scenario declares an unknown statement"
            end
          end
        rescue KeyError, TypeError, NoMethodError => error
          raise ExecutionError.new(
            "SQLite boundary registry contract is invalid"
          ), cause: error
        end

        def required_coverage(registry)
          registry.phase_operations(phase: 2, kill_required: true).flat_map do |operation|
            operation.fetch("statements").map do |statement|
              [operation.fetch("operation"), statement.fetch("template")]
            end
          end.sort.freeze
        end

        def observed_templates(manifest, registry)
          operation = manifest.fetch("events").first.fetch("operation")
          manifest.fetch("events").filter_map do |event|
            statement = event.fetch("statement")
            next unless statement

            resolved = registry.resolve_statement(operation, statement)
            unless resolved
              raise ExecutionError, "trace contains an unknown statement"
            end
            resolved.fetch("template")
          end.uniq.freeze
        end

        def scenario_digest(definition)
          CanonicalJSON.content_digest(
            definition,
            domain: "eval.sqlite_scenario"
          ).freeze
        end

        def exact_hash!(value, fields, name)
          unless value.is_a?(Hash) &&
                 value.length == fields.length &&
                 fields.all? { |field| value.key?(field) }
            raise ExecutionError, "#{name} shape is invalid"
          end
        end

        def identifier(value, name)
          unless value.is_a?(String) &&
                 value.valid_encoding? &&
                 !value.empty? &&
                 value.bytesize <= MAX_ID_BYTES &&
                 value.match?(ID_PATTERN)
            raise ExecutionError, "#{name} is invalid"
          end
          value.dup.freeze
        end

        def positive_integer(value, name)
          return value if value.is_a?(Integer) && value.between?(1, 1_000_000)

          raise ExecutionError, "#{name} is invalid"
        end

        def bounded_limit(value)
          return value if value.is_a?(Integer) && value.between?(1, 1_000_000)

          raise ExecutionError, "maximum scenario count is invalid"
        end

        def normalized_values(value, name)
          unless value.is_a?(Array) && value.any?
            raise ExecutionError, "#{name} are invalid"
          end
          value.map { |entry| identifier(entry, name) }.uniq.freeze
        end

        def string_array(value, name)
          unless value.is_a?(Array) && value.length <= 256
            raise ExecutionError, "#{name} is invalid"
          end
          value.map { |entry| identifier(entry, name) }.freeze
        end

        def template_array(value, name)
          unless value.is_a?(Array) && value.length <= 256
            raise ExecutionError, "#{name} is invalid"
          end
          value.map do |entry|
            unless entry.is_a?(String) &&
                   entry.valid_encoding? &&
                   !entry.empty? &&
                   entry.bytesize <= MAX_ID_BYTES &&
                   entry.match?(TEMPLATE_PATTERN)
              raise ExecutionError, "#{name} is invalid"
            end
            entry.dup.freeze
          end.freeze
        end

        def deeply_frozen?(value)
          return false unless value.frozen?

          case value
          when Hash
            value.all? { |key, entry| deeply_frozen?(key) && deeply_frozen?(entry) }
          when Array
            value.all? { |entry| deeply_frozen?(entry) }
          else
            true
          end
        end

      end

    end
  end
end
