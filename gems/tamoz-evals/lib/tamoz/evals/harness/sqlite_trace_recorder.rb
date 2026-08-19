# frozen_string_literal: true

require "set"

module Tamoz
  module Evals
    module Harness
      class SQLiteTraceRecorder
        VERSION = 1
        MAX_EVENTS = 256
        MAX_OPERATIONS = 32
        MAX_STATEMENTS = 256
        MAX_ATTEMPTS = 16
        MAX_OCCURRENCES = 256
        MAX_SELECTORS = 4_096
        MAX_ID_BYTES = 128
        MAX_VERSION_BYTES = 64
        MAX_MANIFEST_STRING_BYTES = 256
        MAX_MANIFEST_INTEGER = 1_000_000
        GIT_OBJECT_PATTERN = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
        ID_PATTERN = /\A[a-z0-9][a-z0-9._-]*\z/
        VERSION_PATTERN = /\A[0-9A-Za-z][0-9A-Za-z.+_-]*\z/
        EVENT_FIELDS = %w[
          sequence scenario point hook_version kind operation statement
          attempt occurrence
        ].freeze
        SELECTOR_FIELDS = %w[
          scenario point operation statement attempt_class occurrence
          iteration_class selector_digest
        ].freeze
        ATTEMPT_CLASSES = %w[first retry exhausted].freeze
        ITERATION_CLASSES = %w[single first middle final].freeze
        DEFINITION = DeepFreeze.call(
          {
            "id" => "tamoz.sqlite.trace_recorder",
            "version" => VERSION,
            "limits" => {
              "events" => MAX_EVENTS,
              "operations" => MAX_OPERATIONS,
              "statements" => MAX_STATEMENTS,
              "attempts" => MAX_ATTEMPTS,
              "occurrences" => MAX_OCCURRENCES,
              "selectors" => MAX_SELECTORS,
              "manifest_string_bytes" => MAX_MANIFEST_STRING_BYTES,
              "manifest_integer" => MAX_MANIFEST_INTEGER
            },
            "event_fields" => EVENT_FIELDS,
            "selector_fields" => SELECTOR_FIELDS,
            "manifest_fields" => %w[
              manifest_version recorder scenario registry subject events
              selectors content_digest
            ],
            "attempt_classes" => ATTEMPT_CLASSES,
            "iteration_classes" => ITERATION_CLASSES,
            "phase2_attempt_policy" => "first-only",
            "phase2_operation_policy" => "exactly-one",
            "thread_policy" => "arming-thread-only",
            "bootstrap_policy" => "ignore-until-armed",
            "hook_ownership" => "deeply-frozen-input-copied",
            "trace_protocol" =>
              "before_begin,after_begin,(before_sql,after_sql)+," \
              "before_commit,after_commit",
            "dynamic_index_policy" => "zero-based-contiguous",
            "manifest_verification" => "canonical-digest-and-replay",
            "occurrence_identity" => %w[
              point operation statement attempt
            ],
            "coverage_identity" => %w[
              scenario point operation statement_template attempt_class
              iteration_class
            ],
            "selector_order" => "selector-digest",
            "middle_representative" => "lower-median"
          }
        )
        DEFINITION_DIGEST = CanonicalJSON.content_digest(
          DEFINITION,
          domain: "eval.sqlite_trace_recorder"
        ).freeze

        class << self
          def definition
            DEFINITION
          end

          def digest
            DEFINITION_DIGEST
          end

          def verify_manifest!(manifest, registry:)
            ManifestVerifier.new(manifest:, registry:).verify!
          end
        end

        def initialize(scenario:, operation:, subject:, registry:)
          @scenario = normalize_scenario(scenario)
          @operation = identifier(
            operation,
            name: "trace operation",
            maximum: MAX_ID_BYTES
          )
          @subject = normalize_subject(subject)
          @registry = validate_registry(registry)
          @registry_ref = registry_reference
          operation_entry = @registry.operation(@operation)
          unless operation_entry &&
                 operation_entry.fetch("phase") == 2 &&
                 operation_entry.fetch("kill_required") == true
            raise ExecutionError,
                  "trace operation is not a Phase 2 kill-required boundary"
          end

          @mutex = Mutex.new
          @state = :fresh
          @owner_thread = nil
          @protocol_state = :before_begin
          @pending_statement = nil
          @events = []
          @occurrences = Hash.new(0)
          @semantic_counts = Hash.new(0)
          @operations = Set.new
          @statements = Set.new
          @attempts = Set.new
          @manifest = nil
        end

        def arm!
          @mutex.synchronize do
            unless @state == :fresh
              raise ExecutionError, "trace recorder can only be armed once"
            end

            @state = :armed
            @owner_thread = Thread.current
          end
          self
        end

        def call(point, metadata)
          @mutex.synchronize do
            return nil if @state == :fresh

            ensure_armed_owner!
            record!(point, metadata)
          rescue ExecutionError
            @state = :failed
            raise
          rescue StandardError => error
            @state = :failed
            raise ExecutionError.new(
              "SQLite trace hook is invalid: #{error.class}: #{error.message}"
            ), cause: error
          end
          nil
        end

        def finish
          @mutex.synchronize do
            return @manifest if @state == :finished

            begin
              ensure_armed_owner!
              unless @protocol_state == :complete &&
                     @events.any? &&
                     @statements.any?
                raise ExecutionError, "SQLite trace is incomplete"
              end
              unless registry_reference == @registry_ref
                raise ExecutionError,
                      "SQLite boundary registry changed during trace"
              end

              events = @events.dup.freeze
              selectors = SelectorDeriver.new(
                scenario: @scenario.fetch("id"),
                events:,
                registry: @registry
              ).derive
              if selectors.length > MAX_SELECTORS
                raise ExecutionError,
                      "SQLite trace exceeds #{MAX_SELECTORS} selectors"
              end

              @manifest = build_manifest(events, selectors)
              @events.freeze
              @occurrences.freeze
              @semantic_counts.freeze
              @operations.freeze
              @statements.freeze
              @attempts.freeze
              @state = :finished
              @manifest
            rescue ExecutionError
              @state = :failed
              raise
            rescue StandardError => error
              @state = :failed
              raise ExecutionError.new(
                "cannot finalize SQLite trace: #{error.class}: #{error.message}"
              ), cause: error
            end
          end
        end

        private

        def record!(point, metadata)
          if @protocol_state == :complete
            raise ExecutionError, "SQLite trace observed a second operation"
          end
          if @events.length >= MAX_EVENTS
            raise ExecutionError, "SQLite trace exceeds #{MAX_EVENTS} events"
          end

          unless deeply_frozen?(metadata)
            raise ExecutionError, "SQLite trace hook must be deeply frozen"
          end
          @registry.validate_hook!(point, metadata)
          point_name = point.to_s.dup.freeze
          operation_name = metadata.fetch("operation").dup.freeze
          unless operation_name == @operation
            raise ExecutionError,
                  "SQLite trace observed an unexpected operation"
          end
          attempt = metadata.fetch("attempt")
          unless attempt == 1
            raise ExecutionError,
                  "Phase 2 traces accept only the first transaction attempt"
          end

          track_unique!(@operations, operation_name, MAX_OPERATIONS, "operations")
          track_unique!(@attempts, attempt, MAX_ATTEMPTS, "attempts")
          statement = metadata.fetch("statement")&.dup&.freeze
          track_unique!(@statements, statement, MAX_STATEMENTS, "statements") if statement
          resolved = statement && @registry.resolve_statement(operation_name, statement)
          enforce_protocol!(point_name, statement)

          occurrence_key = [point_name, operation_name, statement, attempt].freeze
          occurrence = @occurrences[occurrence_key] + 1
          if occurrence > MAX_OCCURRENCES
            raise ExecutionError,
                  "SQLite trace exceeds #{MAX_OCCURRENCES} occurrences"
          end
          @occurrences[occurrence_key] = occurrence
          enforce_semantic_bound!(point_name, resolved)

          @events << DeepFreeze.call(
            {
              "sequence" => @events.length + 1,
              "scenario" => @scenario.fetch("id"),
              "point" => point_name,
              "hook_version" => metadata.fetch("hook_version"),
              "kind" => metadata.fetch("kind").dup.freeze,
              "operation" => operation_name,
              "statement" => statement,
              "attempt" => attempt,
              "occurrence" => occurrence
            }
          )
        end

        def enforce_protocol!(point, statement)
          case [@protocol_state, point]
          when [:before_begin, "before_begin"]
            @protocol_state = :after_begin
          when [:after_begin, "after_begin"]
            @protocol_state = :sql_or_commit
          when [:sql_or_commit, "before_sql"]
            @pending_statement = statement
            @protocol_state = :after_sql
          when [:after_sql, "after_sql"]
            unless statement == @pending_statement
              raise ExecutionError,
                    "SQLite trace statement hooks are not paired"
            end
            @pending_statement = nil
            @protocol_state = :sql_or_commit
          when [:sql_or_commit, "before_commit"]
            @protocol_state = :after_commit
          when [:after_commit, "after_commit"]
            @protocol_state = :complete
          else
            raise ExecutionError,
                  "SQLite trace hook order is invalid at #{point}"
          end
        end

        def enforce_semantic_bound!(point, resolved)
          if resolved
            template = resolved.fetch("template")
            maximum = resolved.fetch("max_instances")
          else
            template = nil
            maximum = 1
          end
          key = [point, template].freeze
          previous = @semantic_counts[key]
          if resolved &&
             template.include?("{index}") &&
             resolved.fetch("instance") != previous
            raise ExecutionError,
                  "SQLite trace dynamic boundary indices are not contiguous"
          end
          count = previous + 1
          if count > maximum || count > MAX_OCCURRENCES
            raise ExecutionError,
                  "SQLite trace exceeds the registry boundary expansion"
          end
          @semantic_counts[key] = count
        end

        def track_unique!(collection, value, maximum, name)
          collection.add(value)
          return if collection.length <= maximum

          raise ExecutionError,
                "SQLite trace exceeds #{maximum} unique #{name}"
        end

        def ensure_armed_owner!
          unless @state == :armed
            raise ExecutionError, "trace recorder is not armed"
          end
          unless Thread.current.equal?(@owner_thread)
            raise ExecutionError,
                  "trace recorder received a hook from another thread"
          end
        end

        def build_manifest(events, selectors)
          document = {
            "manifest_version" => 1,
            "recorder" => {
              "id" => DEFINITION.fetch("id"),
              "version" => VERSION,
              "digest" => DEFINITION_DIGEST
            },
            "scenario" => @scenario,
            "registry" => @registry_ref,
            "subject" => @subject,
            "events" => events,
            "selectors" => selectors,
            "content_digest" => "pending"
          }
          document["content_digest"] = CanonicalJSON.content_digest(
            document,
            domain: "eval.sqlite_trace_manifest"
          )
          DeepFreeze.call(document)
        end

        def normalize_scenario(value)
          normalized = exact_hash(
            value,
            %w[id version digest],
            name: "trace scenario"
          )
          id = identifier(
            normalized.fetch("id"),
            name: "scenario id",
            maximum: MAX_ID_BYTES
          )
          version = positive_integer(
            normalized.fetch("version"),
            name: "scenario version",
            maximum: 1_000_000
          )
          digest = digest_value(normalized.fetch("digest"), name: "scenario digest")
          DeepFreeze.call(
            {"id" => id, "version" => version, "digest" => digest}
          )
        end

        def normalize_subject(value)
          normalized = exact_hash(
            value,
            %w[id version git_revision git_tree dirty],
            name: "trace subject"
          )
          id = identifier(
            normalized.fetch("id"),
            name: "subject id",
            maximum: MAX_ID_BYTES
          )
          version = version_value(normalized.fetch("version"))
          revision = git_object(
            normalized.fetch("git_revision"),
            name: "subject revision"
          )
          tree = git_object(
            normalized.fetch("git_tree"),
            name: "subject tree"
          )
          dirty = normalized.fetch("dirty")
          unless dirty == true || dirty == false
            raise ExecutionError, "subject dirty state must be boolean"
          end
          body = {
            "id" => id,
            "version" => version,
            "git_revision" => revision,
            "git_tree" => tree,
            "dirty" => dirty
          }
          body["digest"] = CanonicalJSON.content_digest(
            body,
            domain: "eval.subject"
          )
          DeepFreeze.call(body)
        end

        def validate_registry(registry)
          required = %i[
            digest document operation resolve_statement validate_hook!
          ]
          unless required.all? { |method| registry.respond_to?(method) }
            raise ExecutionError, "SQLite boundary registry contract is invalid"
          end
          document = registry.document
          unless deeply_frozen?(document)
            raise ExecutionError, "SQLite boundary registry must be deeply frozen"
          end
          version = document.fetch("registry_version")
          positive_integer(
            version,
            name: "registry version",
            maximum: 1_000_000
          )
          digest_value(registry.digest, name: "registry digest")
          registry
        rescue KeyError, TypeError => error
          raise ExecutionError.new(
            "SQLite boundary registry contract is invalid"
          ), cause: error
        end

        def registry_reference
          DeepFreeze.call(
            {
              "version" => @registry.document.fetch("registry_version"),
              "digest" => digest_value(
                @registry.digest,
                name: "registry digest"
              )
            }
          )
        end

        def exact_hash(value, keys, name:)
          unless value.is_a?(Hash) &&
                 value.length == keys.length &&
                 keys.all? { |key| value.key?(key) }
            raise ExecutionError, "#{name} shape is invalid"
          end
          value
        end

        def identifier(value, name:, maximum:)
          text = bounded_utf8(value, name:, maximum:)
          unless text.match?(ID_PATTERN)
            raise ExecutionError, "#{name} is invalid"
          end
          text.freeze
        end

        def version_value(value)
          text = bounded_utf8(
            value,
            name: "subject version",
            maximum: MAX_VERSION_BYTES
          )
          unless text.match?(VERSION_PATTERN)
            raise ExecutionError, "subject version is invalid"
          end
          text.freeze
        end

        def bounded_utf8(value, name:, maximum:)
          unless value.is_a?(String) &&
                 value.valid_encoding? &&
                 !value.empty? &&
                 value.bytesize <= maximum
            raise ExecutionError, "#{name} is invalid"
          end
          value.dup.freeze
        end

        def digest_value(value, name:)
          unless value.is_a?(String) &&
                 value.valid_encoding? &&
                 Tamoz::Core.valid_digest?(value)
            raise ExecutionError, "#{name} is invalid"
          end
          value.dup.freeze
        end

        def git_object(value, name:)
          unless value.is_a?(String) &&
                 value.valid_encoding? &&
                 value.match?(GIT_OBJECT_PATTERN)
            raise ExecutionError, "#{name} is invalid"
          end
          value.dup.freeze
        end

        def positive_integer(value, name:, maximum:)
          return value if value.is_a?(Integer) &&
                          value.positive? &&
                          value <= maximum

          raise ExecutionError, "#{name} is invalid"
        end

        def deeply_frozen?(value)
          return false unless value.frozen?

          case value
          when Hash
            value.all? do |key, entry|
              deeply_frozen?(key) && deeply_frozen?(entry)
            end
          when Array
            value.all? { |entry| deeply_frozen?(entry) }
          else
            true
          end
        end

        private_constant :ATTEMPT_CLASSES, :DEFINITION, :DEFINITION_DIGEST,
                         :EVENT_FIELDS, :GIT_OBJECT_PATTERN,
                         :ID_PATTERN, :ITERATION_CLASSES, :MAX_ATTEMPTS,
                         :MAX_EVENTS, :MAX_ID_BYTES,
                         :MAX_MANIFEST_INTEGER, :MAX_MANIFEST_STRING_BYTES,
                         :MAX_OCCURRENCES,
                         :MAX_OPERATIONS, :MAX_SELECTORS, :MAX_STATEMENTS,
                         :MAX_VERSION_BYTES, :SELECTOR_FIELDS,
                         :VERSION_PATTERN
      end

      private_constant :SQLiteTraceRecorder
    end
  end
end
