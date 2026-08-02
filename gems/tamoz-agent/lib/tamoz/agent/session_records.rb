# frozen_string_literal: true

require "json"
require "digest"

module Tamoz
  module Agent
    # Versioned, allowlisted durable records for a durable agent session.
    #
    # Invariant 18: every record carries a format version; only allowlisted kinds and
    # keys are accepted; a newer unsupported version fails *before* any field is read.
    # Invariant 24: no `Tamoz::Secret` may reach a checkpoint, stream, or instrumentation
    # payload. `Tamoz::StateCodec` already rejects it at dump time; this module rejects it
    # one layer earlier so the failure names the record rather than a JSON path.
    module SessionRecords
      RECORD_VERSION = 1
      DIGEST_DOMAIN = "tamoz.agent.session_record"
      LEGACY_PROFILE_ID = "legacy"
      LEGACY_PROFILE_DIGEST = "legacy:none"

      STRING = :string
      INTEGER = :integer
      BOOLEAN = :boolean
      HASH = :hash
      STRINGS = :strings
      ARRAY = :array
      ANY = :any

      SCHEMAS = {
        "session" => {
          required: {
            "session_id" => STRING,
            "task" => STRING,
            "task_digest" => STRING,
            "root" => STRING,
            "graph_version" => STRING,
            "behavior_version" => STRING,
            "tool_catalog_digest" => STRING,
            "created_at_ms" => INTEGER
          },
          optional: {
            "profile_id" => STRING,
            "profile_digest" => STRING,
            "profile_authority" => HASH
          }
        },
        "plan" => {
          required: {
            "plan_id" => STRING,
            "phase" => STRING,
            "attempt" => INTEGER,
            "plan" => HASH,
            "plan_digest" => STRING
          },
          optional: {}
        },
        "review" => {
          required: {
            "review_id" => STRING,
            "plan_id" => STRING,
            "plan_digest" => STRING,
            "layer" => STRING,
            "decision" => STRING,
            "issues" => STRINGS
          },
          optional: {"rationale" => STRING}
        },
        "accepted_plan" => {
          required: {
            "plan_id" => STRING,
            "plan_digest" => STRING,
            "phase" => STRING,
            "plan" => HASH,
            "accepted_at_ms" => INTEGER
          },
          optional: {}
        },
        "approval" => {
          required: {
            "approval_id" => STRING,
            "plan_id" => STRING,
            "plan_digest" => STRING,
            "step_id" => STRING,
            "tool" => STRING,
            "arguments_digest" => STRING,
            "preview_digest" => STRING,
            "decision" => STRING
          },
          optional: {}
        },
        "effect_intent" => {
          required: {
            "step_id" => STRING,
            "plan_id" => STRING,
            "plan_digest" => STRING,
            "tool" => STRING,
            "operation" => STRING,
            "safety" => STRING,
            "arguments_digest" => STRING
          },
          optional: {
            "path" => STRING,
            "before_state" => STRING,
            "after_digest" => STRING,
            "after_mode" => INTEGER,
            "check_name" => STRING
          }
        },
        "effect_receipt" => {
          required: {
            "effect_key" => STRING,
            "step_id" => STRING,
            "operation" => STRING,
            "safety" => STRING,
            "status" => STRING,
            "attempt_number" => INTEGER
          },
          optional: {
            "reconciliation" => STRING,
            "external_id" => STRING
          }
        },
        "observation" => {
          required: {
            "phase" => STRING,
            "repair_attempt" => INTEGER,
            "step_id" => STRING,
            "output" => STRING
          },
          optional: {
            "tool" => STRING,
            "check" => HASH,
            # A repairable tool rejection, recorded as evidence rather than raised.
            # Carries kind, tool, error_class, reason, and failure_signature.
            "failure" => HASH
          }
        },
        "verification" => {
          required: {
            "answer" => STRING,
            "satisfied" => BOOLEAN,
            "evidence" => STRINGS,
            "configured_check_passed" => BOOLEAN,
            "terminal_reason" => STRING
          },
          optional: {}
        },
        "terminal" => {
          required: {
            "reason" => STRING,
            "satisfied" => BOOLEAN
          },
          optional: {"blocked" => HASH}
        },
        "blocked" => {
          required: {
            "reason" => STRING,
            "effect_key" => STRING,
            "operation" => STRING,
            "actions" => STRINGS
          },
          optional: {
            "resource" => STRING,
            "step_id" => STRING,
            "prepared_at_ms" => INTEGER
          }
        }
      }.freeze

      KINDS = SCHEMAS.keys.freeze

      # Pure `old_hash -> new_hash` upgrade functions keyed by [kind, from_version].
      # Empty at RECORD_VERSION 1: there is no earlier shipped version to migrate.
      MIGRATIONS = {}.freeze

      module_function

      def build(kind, **fields)
        schema = SCHEMAS.fetch(String(kind)) do
          raise ProtocolError, "unknown session record kind #{kind.inspect}"
        end
        record = {"record" => String(kind), "record_version" => RECORD_VERSION}
        fields.each do |key, value|
          name = String(key)
          unless schema.fetch(:required).key?(name) || schema.fetch(:optional).key?(name)
            raise ProtocolError, "session record #{kind} does not accept #{name.inspect}"
          end
          next if value.nil? && schema.fetch(:optional).key?(name)

          record[name] = value
        end
        load!(Plan.deep_freeze(record), kind:)
      end

      # Validates one stored record. Rejection order is load-bearing: an unsupported
      # newer version must fail before any field is inspected.
      def load!(value, kind: nil)
        unless value.is_a?(Hash)
          raise CheckpointCorruptionError, "session record must be an object"
        end

        stored_kind = value["record"]
        unless stored_kind.is_a?(String) && SCHEMAS.key?(stored_kind)
          raise CheckpointCorruptionError,
                "session record kind #{stored_kind.inspect} is not allowlisted"
        end
        if kind && String(kind) != stored_kind
          raise CheckpointCorruptionError,
                "expected session record #{String(kind).inspect}, found #{stored_kind.inspect}"
        end

        version = value["record_version"]
        unless version.is_a?(Integer) && version.positive?
          raise CheckpointCorruptionError,
                "session record #{stored_kind} has no usable record_version"
        end
        if version > RECORD_VERSION
          raise CheckpointVersionError,
                "session record #{stored_kind} version #{version} exceeds supported " \
                "version #{RECORD_VERSION}"
        end

        migrated = value
        while migrated.fetch("record_version") < RECORD_VERSION
          from = migrated.fetch("record_version")
          migration = MIGRATIONS[[stored_kind, from]]
          unless migration
            raise CheckpointVersionError,
                  "no migration from session record #{stored_kind} version #{from} to " \
                  "version #{RECORD_VERSION}"
          end

          migrated = Plan.deep_freeze(migration.call(migrated))
        end

        # Pre-P8 session records carry no profile identity; they load with the
        # legacy sentinels so resume can distinguish them from profiled sessions.
        if stored_kind == "session"
          defaults = {}
          defaults["profile_id"] = LEGACY_PROFILE_ID unless migrated.key?("profile_id")
          defaults["profile_digest"] = LEGACY_PROFILE_DIGEST unless migrated.key?("profile_digest")
          migrated = Plan.deep_freeze(migrated.merge(defaults)) unless defaults.empty?
        end

        validate_fields!(migrated, stored_kind)
        reject_sensitive!(migrated)
        migrated
      end

      def load_state!(state)
        unless state.is_a?(Hash)
          raise CheckpointCorruptionError, "session state must be a Hash"
        end

        state.each do |key, value|
          case value
          when Hash
            load!(value) if value.key?("record")
          when Array
            value.each do |entry|
              load!(entry) if entry.is_a?(Hash) && entry.key?("record")
            end
          end
        rescue CheckpointCorruptionError, CheckpointVersionError => error
          raise error.class, "session channel #{key.inspect}: #{error.message}"
        end
        state
      end

      def reject_sensitive!(value)
        case value
        when Secret
          raise SensitiveValueError,
                "session records reject Tamoz::Secret; use a credential reference"
        when Hash
          value.each_value { |entry| reject_sensitive!(entry) }
        when Array
          value.each { |entry| reject_sensitive!(entry) }
        end
        value
      end

      def digest(value)
        Digest::SHA256.hexdigest(
          "#{DIGEST_DOMAIN}\n#{JSON.generate(Deliberation.canonical(value))}"
        )
      end

      def validate_fields!(value, kind)
        schema = SCHEMAS.fetch(kind)
        required = schema.fetch(:required)
        optional = schema.fetch(:optional)
        allowed = ["record", "record_version", *required.keys, *optional.keys]
        unknown = value.keys - allowed
        unless unknown.empty?
          raise CheckpointCorruptionError,
                "session record #{kind} has unknown keys: #{unknown.sort.join(", ")}"
        end
        required.each do |name, type|
          unless value.key?(name)
            raise CheckpointCorruptionError,
                  "session record #{kind} is missing #{name.inspect}"
          end

          check_type!(value.fetch(name), type, kind, name)
        end
        optional.each do |name, type|
          next unless value.key?(name)

          check_type!(value.fetch(name), type, kind, name)
        end
        value
      end

      def check_type!(value, type, kind, name)
        ok = case type
             when STRING then value.is_a?(String)
             when INTEGER then value.is_a?(Integer)
             when BOOLEAN then value == true || value == false
             when HASH then value.is_a?(Hash)
             when STRINGS then value.is_a?(Array) && value.all?(String)
             when ARRAY then value.is_a?(Array)
             when ANY then true
             else false
             end
        return value if ok

        raise CheckpointCorruptionError,
              "session record #{kind} field #{name.inspect} must be #{type}"
      end
    end
  end
end
