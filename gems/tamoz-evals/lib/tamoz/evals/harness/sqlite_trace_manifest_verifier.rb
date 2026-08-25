# frozen_string_literal: true

module Tamoz
  module Evals
    module Harness
      class SQLiteTraceRecorder
        class ManifestVerifier
          MANIFEST_FIELDS = %w[
            manifest_version recorder scenario registry subject events selectors
            content_digest
          ].freeze
          RECORDER_FIELDS = %w[id version digest].freeze
          REGISTRY_FIELDS = %w[version digest].freeze
          SUBJECT_FIELDS = %w[
            id version git_revision git_tree dirty digest
          ].freeze
          SCENARIO_FIELDS = %w[id version digest].freeze

          def initialize(manifest:, registry:)
            @manifest = manifest
            @registry = registry
          end

          def verify!
            preflight!
            normalized = CanonicalJSON.normalize(@manifest)
            exact_hash!(normalized, MANIFEST_FIELDS, "trace manifest")
            unless normalized.fetch("manifest_version") == 1
              raise ExecutionError, "trace manifest version is invalid"
            end
            expected_digest = CanonicalJSON.content_digest(
              normalized,
              domain: "eval.sqlite_trace_manifest"
            )
            unless normalized.fetch("content_digest") == expected_digest
              raise ExecutionError, "trace manifest digest is invalid"
            end
            verify_recorder!(normalized.fetch("recorder"))
            verify_registry!(normalized.fetch("registry"))

            events = normalized.fetch("events")
            unless events.is_a?(Array) && events.any?
              raise ExecutionError, "trace manifest events are invalid"
            end
            first = events.fetch(0)
            exact_hash!(first, EVENT_FIELDS, "trace event")
            subject = normalized.fetch("subject")
            exact_hash!(subject, SUBJECT_FIELDS, "trace subject")
            recorder = SQLiteTraceRecorder.new(
              scenario: normalized.fetch("scenario"),
              operation: first.fetch("operation"),
              subject: subject.except("digest"),
              registry: @registry
            )
            recorder.arm!
            events.each do |event|
              exact_hash!(event, EVENT_FIELDS, "trace event")
              recorder.call(
                event.fetch("point"),
                DeepFreeze.call(
                  {
                    "hook_version" => event.fetch("hook_version"),
                    "kind" => event.fetch("kind"),
                    "operation" => event.fetch("operation"),
                    "statement" => event.fetch("statement"),
                    "attempt" => event.fetch("attempt")
                  }
                )
              )
            end
            expected = recorder.finish
            unless expected == normalized
              raise ExecutionError,
                    "trace manifest disagrees with deterministic replay"
            end

            expected
          rescue ExecutionError
            raise
          rescue InvalidArtifactError, KeyError, TypeError, NoMethodError => error
            raise ExecutionError.new(
              "trace manifest is invalid: #{error.class}: #{error.message}"
            ), cause: error
          end

          private

          def preflight!
            exact_hash!(@manifest, MANIFEST_FIELDS, "trace manifest")
            scalar!(@manifest.fetch("manifest_version"), "manifest version")
            scalar!(@manifest.fetch("content_digest"), "manifest digest")
            scalar_hash!(
              @manifest.fetch("recorder"),
              RECORDER_FIELDS,
              "trace recorder reference"
            )
            scalar_hash!(
              @manifest.fetch("registry"),
              REGISTRY_FIELDS,
              "trace registry reference"
            )
            scalar_hash!(
              @manifest.fetch("scenario"),
              SCENARIO_FIELDS,
              "trace scenario"
            )
            scalar_hash!(
              @manifest.fetch("subject"),
              SUBJECT_FIELDS,
              "trace subject"
            )

            events = bounded_array!(
              @manifest.fetch("events"),
              maximum: MAX_EVENTS,
              name: "trace events"
            )
            events.each do |event|
              scalar_hash!(event, EVENT_FIELDS, "trace event")
            end
            selectors = bounded_array!(
              @manifest.fetch("selectors"),
              maximum: MAX_SELECTORS,
              name: "trace selectors"
            )
            selectors.each do |selector|
              scalar_hash!(selector, SELECTOR_FIELDS, "trace selector")
            end
          end

          def scalar_hash!(value, fields, name)
            exact_hash!(value, fields, name)
            value.each_value { |entry| scalar!(entry, name) }
          end

          def bounded_array!(value, maximum:, name:)
            unless value.is_a?(Array) &&
                   value.length <= maximum &&
                   value.any?
              raise ExecutionError, "#{name} are invalid"
            end
            value
          end

          def scalar!(value, name)
            case value
            when String
              unless value.valid_encoding? &&
                     value.bytesize <= MAX_MANIFEST_STRING_BYTES
                raise ExecutionError, "#{name} contains an invalid string"
              end
            when Integer
              if value.bit_length > 63 ||
                 value.abs > MAX_MANIFEST_INTEGER
                raise ExecutionError, "#{name} contains an invalid integer"
              end
            when TrueClass, FalseClass, NilClass
              nil
            else
              raise ExecutionError, "#{name} contains a non-scalar value"
            end
          end

          def verify_recorder!(value)
            exact_hash!(value, RECORDER_FIELDS, "trace recorder reference")
            expected = {
              "id" => DEFINITION.fetch("id"),
              "version" => VERSION,
              "digest" => DEFINITION_DIGEST
            }
            unless value == expected
              raise ExecutionError, "trace recorder reference is invalid"
            end
          end

          def verify_registry!(value)
            exact_hash!(value, REGISTRY_FIELDS, "trace registry reference")
            expected = {
              "version" => @registry.document.fetch("registry_version"),
              "digest" => @registry.digest
            }
            unless value == expected
              raise ExecutionError, "trace registry reference is invalid"
            end
          rescue NoMethodError, KeyError => error
            raise ExecutionError.new(
              "trace registry contract is invalid"
            ), cause: error
          end

          def exact_hash!(value, fields, name)
            unless value.is_a?(Hash) &&
                   value.length == fields.length &&
                   fields.all? { |field| value.key?(field) }
              raise ExecutionError, "#{name} shape is invalid"
            end
          end
        end

        private_constant :ManifestVerifier
      end
    end
  end
end
