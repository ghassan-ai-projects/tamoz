# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteScenarioRegistry
        VERSION = 1
        MAX_SCENARIOS = 32
        MAX_ID_BYTES = 128
        ID_PATTERN = /\A[a-z0-9][a-z0-9._-]*\z/
        TEMPLATE_PATTERN =
          /\A[a-z0-9][a-z0-9._-]*(?:\{index\}[a-z0-9._-]*)?\z/
        FAMILIES = %w[lease request checkpoint].freeze
        STATE_CLASSES = %w[old new stable].freeze
        SCENARIO_FIELDS = %w[
          id version family operation setup action state_classes contract
          convergence coverage
        ].freeze

        LEASE_ACQUIRE = %w[
          lease.acquire.time
          lease.acquire.thread
          lease.acquire.thread_state
          lease.acquire.namespace
          lease.acquire.row
          lease.acquire.update
        ].freeze
        LEASE_VALIDATE = %w[
          lease.validate.time
          lease.validate.thread
          lease.validate.row
          lease.validate.clock
        ].freeze
        LEASE_RENEW = %w[
          lease.renew.time
          lease.renew.thread
          lease.renew.row
          lease.renew.update
        ].freeze
        LEASE_RELEASE = %w[
          lease.release.time
          lease.release.row
          lease.release.update
        ].freeze
        REQUEST_ENQUEUE_NEW = %w[
          request.enqueue.time
          request.enqueue.thread
          request.enqueue.tombstone
          request.enqueue.namespace
          request.enqueue.existing
          request.enqueue.sequence
          request.enqueue.insert
          request.transition.index
          request.transition.insert
          request.enqueue.advance
          request.enqueue.result
        ].freeze
        REQUEST_ENQUEUE_DUPLICATE = %w[
          request.enqueue.time
          request.enqueue.thread
          request.enqueue.tombstone
          request.enqueue.namespace
          request.enqueue.existing
        ].freeze
        REQUEST_CLAIM_BASE = %w[
          request.claim.time
          request.claim.lease.thread
          request.claim.lease.row
          request.claim.candidates
        ].freeze
        REQUEST_CLAIM_TAIL = %w[
          request.claim.update
          request.transition.index
          request.transition.insert
          request.claim.result
        ].freeze
        # DR-4: a claim that validates and terminal-fails a stale request inside the
        # claim transaction (queued -> failed in one atomic write; the claim UPDATE
        # and bound-execution reads are skipped on the stale path).
        REQUEST_CLAIM_STALE = (
          REQUEST_CLAIM_BASE +
          %w[
            request.claim.latest_checkpoint
            request.terminal_fail
            request.transition.index
            request.transition.insert
            request.claim.result
          ]
        ).freeze
        REQUEST_RECOVER = %w[
          request.recover.time
          request.recover.lease.thread
          request.recover.lease.row
          request.recover.row
          request.recover.earlier
          request.recover.update
          request.transition.index
          request.transition.insert
          request.recover.result
        ].freeze
        # DR-4: a recover that validates and terminal-fails a stale claimed request
        # inside the recover transaction (the fence UPDATE is skipped on the stale
        # path).
        REQUEST_RECOVER_STALE = %w[
          request.recover.time
          request.recover.lease.thread
          request.recover.lease.row
          request.recover.row
          request.recover.earlier
          request.recover.latest_checkpoint
          request.terminal_fail
          request.transition.index
          request.transition.insert
          request.recover.result
        ].freeze
        REQUEST_TRANSITION = %w[
          request.transition.time
          request.transition.lease.thread
          request.transition.lease.row
          request.commit.row
          request.commit.update
          request.transition.index
          request.transition.insert
          request.transition.result
        ].freeze
        REQUEST_REDIRECT_READY = %w[
          request.redirect_ready.time
          request.redirect_ready.lease.thread
          request.redirect_ready.lease.row
          request.redirect_ready.effects
        ].freeze
        CHECKPOINT_WRITES_BASE = %w[
          checkpoint.writes.time
          checkpoint.writes.lease.thread
          checkpoint.writes.lease.row
          checkpoint.writes.base
          checkpoint.writes.existing
        ].freeze
        CHECKPOINT_COMMIT_BASE = %w[
          checkpoint.commit.time
          checkpoint.commit.lease.thread
          checkpoint.commit.lease.row
          checkpoint.commit.head
        ].freeze
        CHECKPOINT_COMMIT_REQUEST = %w[
          request.commit.row
          request.commit.update
          request.transition.index
          request.transition.insert
        ].freeze

        class << self
          def build
            new(SCENARIOS)
          end
        end

        attr_reader :document, :digest

        def initialize(scenarios)
          normalized = normalize_scenarios(scenarios)
          @index = normalized.to_h { |scenario| [scenario.fetch("id"), scenario] }.freeze
          @document = DeepFreeze.call(
            {
              "registry_version" => VERSION,
              "maximum_scenarios" => MAX_SCENARIOS,
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
                 manifests.length <= MAX_SCENARIOS
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
                 scenarios.length <= MAX_SCENARIOS
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
          unless FAMILIES.include?(family)
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
                 state_classes.all? { |entry| STATE_CLASSES.include?(entry) } &&
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

        def self.definition(
          id,
          family:,
          operation:,
          state_classes: %w[old new],
          coverage:
        )
          {
            "id" => id,
            "version" => 1,
            "family" => family,
            "operation" => operation,
            "setup" => id,
            "action" => operation,
            "state_classes" => state_classes,
            "contract" => id,
            "convergence" => id,
            "coverage" => coverage
          }.freeze
        end
        private_class_method :definition

        SCENARIOS = DeepFreeze.call([
          definition(
            "lease.acquire-new",
            family: "lease",
            operation: "lease.acquire",
            coverage: LEASE_ACQUIRE
          ),
          definition(
            "lease.acquire-takeover",
            family: "lease",
            operation: "lease.acquire",
            coverage: LEASE_ACQUIRE
          ),
          definition(
            "lease.validate",
            family: "lease",
            operation: "lease.validate",
            coverage: LEASE_VALIDATE
          ),
          definition(
            "lease.renew",
            family: "lease",
            operation: "lease.renew",
            coverage: LEASE_RENEW
          ),
          definition(
            "lease.release",
            family: "lease",
            operation: "lease.release",
            coverage: LEASE_RELEASE
          ),
          definition(
            "request.enqueue-new",
            family: "request",
            operation: "request.enqueue",
            coverage: REQUEST_ENQUEUE_NEW
          ),
          definition(
            "request.enqueue-duplicate",
            family: "request",
            operation: "request.enqueue",
            state_classes: ["stable"],
            coverage: REQUEST_ENQUEUE_DUPLICATE
          ),
          definition(
            "request.claim-turn",
            family: "request",
            operation: "request.claim",
            coverage: REQUEST_CLAIM_BASE + REQUEST_CLAIM_TAIL
          ),
          definition(
            "request.claim-resume",
            family: "request",
            operation: "request.claim",
            coverage: REQUEST_CLAIM_BASE +
                      ["request.claim.active_execution"] +
                      REQUEST_CLAIM_TAIL
          ),
          definition(
            "request.claim-redirect",
            family: "request",
            operation: "request.claim",
            coverage: REQUEST_CLAIM_BASE +
                      %w[
                        request.claim.redirect_target
                        request.claim.cancellation_generation
                      ] +
                      REQUEST_CLAIM_TAIL
          ),
          definition(
            "request.claim-stale",
            family: "request",
            operation: "request.claim",
            coverage: REQUEST_CLAIM_STALE
          ),
          *%w[claimed running redirecting].map do |status|
            definition(
              "request.recover-#{status}",
              family: "request",
              operation: "request.recover",
              coverage: REQUEST_RECOVER
            )
          end,
          definition(
            "request.recover-stale",
            family: "request",
            operation: "request.recover",
            coverage: REQUEST_RECOVER_STALE
          ),
          definition(
            "request.mark-running",
            family: "request",
            operation: "request.transition",
            coverage: REQUEST_TRANSITION
          ),
          definition(
            "request.mark-redirect-running",
            family: "request",
            operation: "request.transition",
            coverage: REQUEST_TRANSITION
          ),
          definition(
            "request.redirect-ready",
            family: "request",
            operation: "request.redirect_ready",
            state_classes: ["stable"],
            coverage: REQUEST_REDIRECT_READY
          ),
          definition(
            "checkpoint.writes-new",
            family: "checkpoint",
            operation: "checkpoint.append_writes",
            coverage: CHECKPOINT_WRITES_BASE +
                      %w[
                        checkpoint.writes.activation
                        checkpoint.writes.item.{index}
                      ]
          ),
          definition(
            "checkpoint.writes-duplicate",
            family: "checkpoint",
            operation: "checkpoint.append_writes",
            state_classes: ["stable"],
            coverage: CHECKPOINT_WRITES_BASE + ["checkpoint.writes.verify"]
          ),
          definition(
            "checkpoint.commit-start",
            family: "checkpoint",
            operation: "checkpoint.commit",
            coverage: CHECKPOINT_COMMIT_BASE +
                      %w[
                        checkpoint.commit.insert
                        checkpoint.commit.advance
                      ]
          ),
          definition(
            "checkpoint.commit-advance",
            family: "checkpoint",
            operation: "checkpoint.commit",
            coverage: CHECKPOINT_COMMIT_BASE +
                      %w[
                        checkpoint.commit.base
                        checkpoint.commit.insert
                        checkpoint.commit.consume.{index}
                        checkpoint.commit.advance
                      ]
          ),
          definition(
            "checkpoint.commit-turn",
            family: "checkpoint",
            operation: "checkpoint.commit",
            coverage: CHECKPOINT_COMMIT_BASE +
                      ["checkpoint.commit.base", "checkpoint.commit.insert"] +
                      CHECKPOINT_COMMIT_REQUEST +
                      ["checkpoint.commit.advance"]
          ),
          definition(
            "checkpoint.commit-fork",
            family: "checkpoint",
            operation: "checkpoint.commit",
            coverage: CHECKPOINT_COMMIT_BASE +
                      %w[
                        checkpoint.commit.base
                        checkpoint.commit.insert
                        checkpoint.commit.advance
                      ]
          ),
          definition(
            "checkpoint.commit-paused",
            family: "checkpoint",
            operation: "checkpoint.commit",
            coverage: CHECKPOINT_COMMIT_BASE +
                      %w[
                        checkpoint.commit.base
                        checkpoint.commit.insert
                        checkpoint.commit.advance
                      ]
          ),
          definition(
            "checkpoint.commit-failed",
            family: "checkpoint",
            operation: "checkpoint.commit",
            coverage: CHECKPOINT_COMMIT_BASE +
                      ["checkpoint.commit.base", "checkpoint.commit.insert"] +
                      CHECKPOINT_COMMIT_REQUEST +
                      ["checkpoint.commit.advance"]
          )
        ])

        private_constant :CHECKPOINT_COMMIT_BASE, :CHECKPOINT_COMMIT_REQUEST,
                         :CHECKPOINT_WRITES_BASE, :FAMILIES, :ID_PATTERN,
                         :LEASE_ACQUIRE, :LEASE_RELEASE, :LEASE_RENEW,
                         :LEASE_VALIDATE, :MAX_ID_BYTES, :REQUEST_CLAIM_BASE,
                         :REQUEST_CLAIM_TAIL, :REQUEST_ENQUEUE_DUPLICATE,
                         :REQUEST_ENQUEUE_NEW, :REQUEST_RECOVER,
                         :REQUEST_REDIRECT_READY, :REQUEST_TRANSITION,
                         :SCENARIO_FIELDS, :SCENARIOS, :STATE_CLASSES,
                         :TEMPLATE_PATTERN
      end

      private_constant :SQLiteScenarioRegistry
    end
  end
end
