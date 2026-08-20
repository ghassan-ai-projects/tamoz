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
      # Effect receipts gained durable logical and attempt identities. This is an
      # incompatible checkpoint wire change; old session records are rejected and
      # callers must start from a fresh database as required by the repository
      # compatibility policy.
      RECORD_VERSION = 2
      DIGEST_DOMAIN = "tamoz.agent.session_record.v1"
      LEGACY_PROFILE_ID = "legacy"
      LEGACY_PROFILE_DIGEST = "legacy:none"
      # P16: `LEGACY_SKILL_EPOCH` moved to tamoz-core (`Tamoz::Core::LEGACY_SKILL_EPOCH`),
      # shared with the moved toolbox's empty-snapshot `skill_epoch`.
      LEGACY_PROMPT_SURFACE_DIGEST = "legacy:none"

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
            "profile_authority" => HASH,
            # DR-5 D1: per-role POST-OVERRIDE {provider:, model:} tuples — the
            # accurate record of which models actually ran, built from
            # model_roles + override names only (never the model instance, never
            # a credential). Optional HASH, legacy sentinel {}, RECORD_VERSION
            # stays 1. The invariant `profile_roles ≡ f(model_roles, overrides)`
            # holds: it carries NO independent data. `{}` with a present
            # profile_id means "profiled with zero roles"; `{}` under the legacy
            # profile_id sentinel means "no profile resolution existed".
            "profile_roles" => HASH,
            # DR-5 D1 RC9: the validated profile budgets, recorded per profile
            # (equality to `profile.budgets` only — labeled). Forward-looking for
            # P13; no runtime consumer exists today. Empty sentinel {}.
            "profile_budgets" => HASH,
            "skill_epoch" => STRING,
            "prompt_surface_digest" => STRING,
            # P10 §5 epoch rules: a session that used an MCP capability pins the
            # catalog digests it ran against as {server_id => snapshot_digest}.
            # Optional HASH, legacy sentinel {}, RECORD_VERSION stays 1.
            "mcp_catalogs" => HASH,
            "mcp_source_digests" => HASH,
            # P17 (correction 5): a session that ran under a profile carrying an
            # `egress:` section pins the canonical egress declaration. Optional
            # HASH, legacy sentinel {} — the pre-P17 state and the "profile has
            # no egress" state are one and the same "no egress declaration".
            # `Session#verify_egress_binding!` compares this on resume and stops
            # typed on a mismatch (invariant 35/36).
            "egress_pin" => HASH,
            # P11 (C4): the per-session memory snapshot — {"layers" => [...],
            # "retrieval_policy" => ..., "catalog_digest" => ...}. Legacy
            # sentinel "none" is filled at load when memory did not exist
            # (RECORD_VERSION stays 1; exact P9 LEGACY_SKILL_EPOCH pattern).
            # Pre-P11 sessions resume with zero memory injection and an
            # identical prefix digest. Retrieval/injection policy is
            # per-session; the snapshot rides the session record.
            "memory_epoch" => ANY,
            # DR-1 (P11-W): a promoted behavior change activates at the FIRST
            # INTAKE OF A THREAD. The adopting session record pins the new
            # behavior version, the behavior-snapshot digest + inline content
            # (bounded), the extended prompt-surface digest (the cache epoch
            # moved, invariant 16), and `epoch_reason` = the transition id.
            # Optional; absent means "no behavior transition" (pre-P11 state).
            "epoch_reason" => STRING,
            "behavior_snapshot_digest" => STRING,
            "behavior_snapshot" => ANY,
            # P12 (P12-HD): the healing rule set a session was bound to, as
            # {rule_id => "version:contract_digest"} (`Healing.pin_for`). Optional
            # HASH, legacy sentinel {} — the pre-P12 state and the "healing is
            # disabled" state are one and the same "no rule set was bound", the
            # same equivalence `egress_pin` makes for egress. RECORD_VERSION stays
            # 1: a pre-P12 record simply has no key, and `fetch("healing_pin", {})`
            # yields legacy semantics without a migration.
            "healing_pin" => HASH
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
        "route" => {
          required: {
            "route" => STRING,
            "reason_class" => STRING,
            "route_digest" => STRING
          },
          optional: {
            "plan_digest" => STRING,
            "fallback" => STRING,
            "mode" => STRING,
            "authority_revision" => STRING,
            "catalog_revision" => STRING
          }
        },
        "adaptive_decision" => {
          required: {
            "decision" => STRING,
            "iteration" => INTEGER,
            "decision_digest" => STRING
          },
          optional: {
            "capability_id" => STRING,
            "arguments_digest" => STRING,
            "answer" => STRING,
            "evidence_refs" => STRINGS,
            "reason" => STRING
          }
        },
        "lifecycle_event" => {
          required: {
            "event_type" => STRING,
            "sequence" => INTEGER,
            "request_id" => STRING,
            "thread_id" => STRING,
            "execution_id" => STRING,
            "phase" => STRING,
            "effect_state" => STRING,
            "delivery_state" => STRING
          },
          optional: {
            "iteration" => INTEGER,
            "sub_operation" => INTEGER,
            "effect_key" => STRING,
            "logical_key" => STRING,
            "attempt_number" => INTEGER,
            "capability_id" => STRING,
            "source_id" => STRING,
            "provenance" => STRING,
            "truncated" => BOOLEAN,
            "output_bytes" => INTEGER,
            "terminal_reason" => STRING
          }
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
            "check_name" => STRING,
            "iteration" => INTEGER,
            "sub_operation" => INTEGER
          }
        },
        "effect_receipt" => {
          required: {
            "effect_key" => STRING,
            "logical_key" => STRING,
            "attempt_identity" => STRING,
            "step_id" => STRING,
            "operation" => STRING,
            "safety" => STRING,
            "status" => STRING,
            "attempt_number" => INTEGER
          },
          optional: {
            "reconciliation" => STRING,
            "external_id" => STRING,
            "iteration" => INTEGER,
            "sub_operation" => INTEGER
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
            "effect_key" => STRING,
            "iteration" => INTEGER,
            "sub_operation" => INTEGER,
            "provenance" => STRING,
            "source_id" => STRING,
            "truncated" => BOOLEAN,
            "output_bytes" => INTEGER,
            "result_class" => STRING,
            "decision_digest" => STRING,
            "evidence_ref" => STRING,
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

      # P17 W6 (correction 6) — invariant 24 at the checkpoint boundary for
      # MODEL-PROPOSED INVOCATIONS. A credential VALUE must never enter a plan
      # record (the durable proposal) or an accepted plan: plans flow into the
      # journal, prompts, and audit, and a rejected credential-shaped step must
      # not leave its raw value behind. Tool OBSERVATIONS are the user's own
      # workspace content and are deliberately NOT scanned (the pre-P17
      # `test_sensitive_content_is_not_rendered_to_streams_or_transcript`
      # behavior). SECRET_VALUE_PATTERNS is the one shared credential set
      # (Tamoz::Core::SECRET_VALUE_PATTERNS) — see profile.rb and tamoz-mcp's
      # websearch.rb for the other consumers.
      SECRET_VALUE_PATTERNS = Tamoz::Core::SECRET_VALUE_PATTERNS
      CREDENTIAL_SCANNED_KINDS = %w[plan accepted_plan].freeze

      # Pure `old_hash -> new_hash` upgrade functions keyed by [kind, from_version].
      # No compatibility migrations: version 1 receipts do not carry the identity
      # fields required by the current journal contract.
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

        # Pre-P8/P9 session records carry no profile or skill identity; they load
        # with the legacy sentinels so resume can distinguish them from profiled or
        # skill-bearing sessions. RECORD_VERSION stays 1: defaults are filled at
        # load time, so no migration is needed and old sessions still resume.
        if stored_kind == "session"
          defaults = {}
          defaults["profile_id"] = LEGACY_PROFILE_ID unless migrated.key?("profile_id")
          defaults["profile_digest"] = LEGACY_PROFILE_DIGEST unless migrated.key?("profile_digest")
          defaults["skill_epoch"] = Tamoz::Core::LEGACY_SKILL_EPOCH unless migrated.key?("skill_epoch")
          unless migrated.key?("prompt_surface_digest")
            defaults["prompt_surface_digest"] = LEGACY_PROMPT_SURFACE_DIGEST
          end
          # DR-5 D1: no profile resolution is one state, however it arose — a
          # pre-P8 session and a P8 profiled session with zero roles both carry
          # {} as `profile_roles`, disambiguated by `profile_id` ("legacy"
          # sentinel vs a real id). Budgets likewise default to {}.
          defaults["profile_roles"] = {} unless migrated.key?("profile_roles")
          defaults["profile_budgets"] = {} unless migrated.key?("profile_budgets")
          # P10 §5: no MCP catalogs is one state, however it arose — a pre-P10
          # session and a P10 session built without an MCP source both resume
          # against "no catalogs". "{}" is the legacy sentinel.
          defaults["mcp_catalogs"] = {} unless migrated.key?("mcp_catalogs")
          defaults["mcp_source_digests"] = {} unless migrated.key?("mcp_source_digests")
          # P17: no egress pin is one state, however it arose — a pre-P17 session
          # and a P17 session whose profile carried no `egress:` section both
          # resume against "no egress declaration". "{}" is the legacy sentinel.
          defaults["egress_pin"] = {} unless migrated.key?("egress_pin")
          # P11 (C4): pre-P11 sessions carry no memory snapshot; they load with
          # the "none" sentinel so resume is byte-identical (zero memory
          # injection, identical prefix digest). A session built post-P11 with
          # memory records a hash-shaped `memory_epoch`.
          defaults["memory_epoch"] = Tamoz::Agent::Memory::LEGACY_MEMORY_EPOCH unless migrated.key?("memory_epoch")
          migrated = Plan.deep_freeze(migrated.merge(defaults)) unless defaults.empty?
        end

        validate_fields!(migrated, stored_kind)
        reject_sensitive!(migrated)
        reject_credential_values!(migrated) if CREDENTIAL_SCANNED_KINDS.include?(stored_kind)
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

      # The plan/acceptance credential gate (P17 W6). Fail-closed and typed:
      # a plan record carrying a credential VALUE raises `SensitiveValueError`,
      # which `SessionNodes#deliberate` converts into a plan-revision issue so
      # the model replans without the value — nothing is committed.
      def reject_credential_values!(value)
        case value
        when String
          if SECRET_VALUE_PATTERNS.any? { |pattern| pattern.match?(value) }
            raise SensitiveValueError,
                  "the plan step arguments carry a credential value; use a " \
                  "credential reference instead"
          end
        when Hash
          value.each_value { |entry| reject_credential_values!(entry) }
        when Array
          value.each { |entry| reject_credential_values!(entry) }
        end
        value
      end

      def digest(value)
        Tamoz::Core.digest("#{DIGEST_DOMAIN}\n", value)
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
        # P11 (C4): the memory_epoch value is either the legacy "none" sentinel
        # or a hash-shaped snapshot; anything else is corruption.
        if value.key?("memory_epoch")
          snapshot = value.fetch("memory_epoch")
          unless snapshot == Tamoz::Agent::Memory::LEGACY_MEMORY_EPOCH || snapshot.is_a?(Hash)
            raise CheckpointCorruptionError,
                  "session record memory_epoch must be #{Tamoz::Agent::Memory::LEGACY_MEMORY_EPOCH.inspect} " \
                  "or an object"
          end
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
