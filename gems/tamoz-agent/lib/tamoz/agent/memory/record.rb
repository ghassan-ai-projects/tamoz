# frozen_string_literal: true

require "json"

module Tamoz
  module Agent
    module Memory
      # P11 §3 (P11-D): the canonical immutable, versioned `MemoryRecord`. One
      # instance is one VERSION of one memory identity: `memory_id` + the
      # monotonic `record_version`. States, source evidence, and statements are
      # never edited in place — every transition appends a new version.
      #
      # Field semantics (design §3):
      # * `layer`            :experience | :knowledge | :wisdom
      # * `klass`            :episode | :procedure | :policy | :profile |
      #                       :constraint | :strategy | :preference
      # * `state`            candidate/active/consolidated/rejected/superseded/
      #                       quarantined/deleted
      # * `epistemic_kind`   :observed | :reported | :inferred | :prescribed
      # * `source_refs`      [{identity:, digest:, observed_at:}] — never bare
      #                       model claims
      # * `scopes`           {tenant:, user:, project:, session:}
      # * `sensitivity`      :public | :internal | :sensitive
      # * `transition`       {actor:, authority:, reason:, prior_version:,
      #                       evidence:, policy_version:, timestamp:, trace_id:}
      # * `compatibility`    {graph_version:, behavior_version:}
      #
      # Invariant 18: the record registers a codec in the allowlist
      # (`Memory.codec`); an unknown `format_version` fails before partial load
      # (StateCodec raises CheckpointVersionError on the unknown tag/version).
      class MemoryRecord < Data.define(
        :format_version, :memory_id, :record_version, :layer, :klass, :state,
        :statement, :epistemic_kind, :source_refs, :owner, :actor, :scopes,
        :sensitivity, :disclosure_policy, :confidence, :confidence_method,
        :valid_from, :valid_until, :review_at, :supersession_key,
        :contradiction_set_id, :base_quality, :last_evaluated_at, :use_counts,
        :created_by, :compatibility, :transition, :rejection_reason,
        :created_at_ms
      )
        FORMAT_VERSION = 1
        LAYERS = %i[experience knowledge wisdom].freeze
        CLASSES = %i[episode procedure policy profile constraint strategy preference].freeze
        STATES = %i[candidate active consolidated rejected superseded quarantined deleted].freeze
        EPISTEMIC_KINDS = %i[observed reported inferred prescribed].freeze
        SENSITIVITIES = %i[public internal sensitive].freeze
        # P11 §3 (C5): retrieval-eligible state set.
        ELIGIBLE_STATES = %i[active consolidated].freeze
        DIGEST_DOMAIN = "tamoz.agent.memory_record.v1\n"
        MAX_ID_BYTES = 256

        def initialize(
          format_version: FORMAT_VERSION,
          memory_id:,
          record_version: 1,
          layer:,
          klass:,
          state: :candidate,
          statement: "",
          epistemic_kind:,
          source_refs: [],
          owner:,
          actor: nil,
          scopes:,
          sensitivity:,
          disclosure_policy: "default",
          confidence: nil,
          confidence_method: nil,
          valid_from: nil,
          valid_until: nil,
          review_at: nil,
          supersession_key: nil,
          contradiction_set_id: nil,
          base_quality: 0.0,
          last_evaluated_at: nil,
          use_counts: {"successful" => 0, "failed" => 0, "corrected" => 0},
          created_by: {},
          compatibility: {},
          transition: nil,
          rejection_reason: nil,
          created_at_ms: 0
        )
          super(
            format_version:,
            memory_id: validate_id(memory_id, "memory_id"),
            record_version: validate_version(record_version),
            layer: validate_member(layer, LAYERS, "layer"),
            klass: validate_member(klass, CLASSES, "class"),
            state: validate_member(state, STATES, "state"),
            statement: validate_statement(statement),
            epistemic_kind: validate_member(epistemic_kind, EPISTEMIC_KINDS, "epistemic_kind"),
            source_refs: Plan.deep_freeze(validate_source_refs(source_refs)),
            owner: validate_id(owner, "owner"),
            actor: actor.nil? ? nil : validate_id(actor, "actor"),
            scopes: Plan.deep_freeze(validate_scopes(scopes)),
            sensitivity: validate_member(sensitivity, SENSITIVITIES, "sensitivity"),
            disclosure_policy: validate_id(disclosure_policy, "disclosure_policy"),
            confidence: confidence,
            confidence_method: confidence_method,
            valid_from: valid_from,
            valid_until: valid_until,
            review_at: review_at,
            supersession_key: supersession_key,
            contradiction_set_id: contradiction_set_id,
            base_quality: validate_quality(base_quality),
            last_evaluated_at: last_evaluated_at,
            use_counts: Plan.deep_freeze(validate_use_counts(use_counts)),
            created_by: Plan.deep_freeze(created_by || {}),
            compatibility: Plan.deep_freeze(validate_compatibility(compatibility)),
            transition: transition && Plan.deep_freeze(validate_transition(transition)),
            rejection_reason: rejection_reason,
            created_at_ms: created_at_ms
          )
        end

        def eligible?
          ELIGIBLE_STATES.include?(state)
        end

        def sensitive? = sensitivity == :sensitive

        # P11-A anti self-ingestion: a record whose provenance is a RECALL can
        # never be admitted as new Experience evidence.
        def recalled? = !!(transition && transition["recalled"] == true)

        def with(**updates)
          self.class.new(
            **to_init_hash.merge(updates)
          )
        end

        def digest
          Tamoz::Core.digest(DIGEST_DOMAIN, to_h)
        end

        # Canonical storage hash (string keys).
        def to_h
          {
            "format_version" => format_version,
            "memory_id" => memory_id,
            "record_version" => record_version,
            "layer" => layer.to_s,
            "class" => klass.to_s,
            "state" => state.to_s,
            "statement" => statement,
            "epistemic_kind" => epistemic_kind.to_s,
            "source_refs" => source_refs,
            "owner" => owner,
            "actor" => actor,
            "scopes" => scopes,
            "sensitivity" => sensitivity.to_s,
            "disclosure_policy" => disclosure_policy,
            "confidence" => confidence,
            "confidence_method" => confidence_method,
            "valid_from" => valid_from,
            "valid_until" => valid_until,
            "review_at" => review_at,
            "supersession_key" => supersession_key,
            "contradiction_set_id" => contradiction_set_id,
            "base_quality" => base_quality,
            "last_evaluated_at" => last_evaluated_at,
            "use_counts" => use_counts,
            "created_by" => created_by,
            "compatibility" => compatibility,
            "transition" => transition,
            "rejection_reason" => rejection_reason,
            "created_at_ms" => created_at_ms
          }
        end

        def self.from_h(hash)
          unless hash.is_a?(Hash)
            raise CheckpointCorruptionError, "MemoryRecord must be an object"
          end
          version = hash["format_version"]
          unless version == FORMAT_VERSION
            raise CheckpointVersionError,
                  "MemoryRecord format_version #{version.inspect} is not supported"
          end

          string_state = hash.fetch("state").to_sym
          string_layer = hash.fetch("layer").to_sym
          string_klass = hash.fetch("class").to_sym
          string_kind = hash.fetch("epistemic_kind").to_sym
          string_sensitivity = hash.fetch("sensitivity").to_sym
          new(
            format_version: version,
            memory_id: hash.fetch("memory_id"),
            record_version: hash.fetch("record_version"),
            layer: string_layer,
            klass: string_klass,
            state: string_state,
            statement: hash.fetch("statement"),
            epistemic_kind: string_kind,
            source_refs: hash.fetch("source_refs"),
            owner: hash.fetch("owner"),
            actor: hash["actor"],
            scopes: hash.fetch("scopes"),
            sensitivity: string_sensitivity,
            disclosure_policy: hash.fetch("disclosure_policy"),
            confidence: hash["confidence"],
            confidence_method: hash["confidence_method"],
            valid_from: hash["valid_from"],
            valid_until: hash["valid_until"],
            review_at: hash["review_at"],
            supersession_key: hash["supersession_key"],
            contradiction_set_id: hash["contradiction_set_id"],
            base_quality: hash.fetch("base_quality"),
            last_evaluated_at: hash["last_evaluated_at"],
            use_counts: hash.fetch("use_counts"),
            created_by: hash.fetch("created_by"),
            compatibility: hash.fetch("compatibility"),
            transition: hash["transition"],
            rejection_reason: hash["rejection_reason"],
            created_at_ms: hash.fetch("created_at_ms")
          )
        end

        private

        def to_init_hash
          {
            format_version:, memory_id:, record_version:, layer:, klass:, state:,
            statement:, epistemic_kind:, source_refs:, owner:, actor:, scopes:,
            sensitivity:, disclosure_policy:, confidence:, confidence_method:,
            valid_from:, valid_until:, review_at:, supersession_key:,
            contradiction_set_id:, base_quality:, last_evaluated_at:, use_counts:,
            created_by:, compatibility:, transition:, rejection_reason:,
            created_at_ms:
          }
        end

        def validate_id(value, name)
          text = SafeText.normalize(
            value, name:, max_bytes: MAX_ID_BYTES, error_class: MemoryPolicyError
          )
          text
        end

        def validate_version(value)
          unless value.is_a?(Integer) && value.positive?
            raise MemoryPolicyError, "record_version must be a positive integer"
          end

          value
        end

        def validate_member(value, set, name)
          unless set.include?(value)
            raise MemoryPolicyError, "#{name} must be one of #{set.map(&:inspect).join(", ")}"
          end

          value
        end

        def validate_statement(value)
          text = SafeText.normalize(
            value, name: "memory statement", max_bytes: MemoryLimits.fetch(:max_statement_bytes),
            error_class: MemoryPolicyError
          )
          text
        end

        def validate_source_refs(value)
          unless value.is_a?(Array) && value.length <= MemoryLimits.fetch(:max_source_refs)
            raise MemoryPolicyError,
                  "source_refs must be an array of at most " \
                  "#{MemoryLimits.fetch(:max_source_refs)} refs"
          end
          value.each do |ref|
            unless ref.is_a?(Hash) && ref.key?("identity") && ref.key?("digest")
              raise MemoryPolicyError, "each source ref must carry identity and digest"
            end
            validate_id(ref.fetch("identity"), "source identity")
            unless ref.fetch("digest").is_a?(String) && !ref.fetch("digest").empty?
              raise MemoryPolicyError, "source digest must be a non-empty string"
            end
          end
          value
        end

        def validate_scopes(value)
          unless value.is_a?(Hash)
            raise MemoryPolicyError, "scopes must be an object"
          end
          # T0.3: canonicalize keys to strings so symbol- and string-keyed
          # scopes validate identically, then require the situation dimension
          # to be all-or-none by VALUE: any non-nil situation key must come
          # with a non-nil entity identity, and an explicit nil is the same as
          # an absent key.
          normalized = value.to_h { |key, entry| [String(key), entry] }
          present = %w[situation_type entity_type entity_id].reject { |key| normalized[key].nil? }
          unless present.empty? || present.length == 3
            raise MemoryPolicyError,
                  "situation scopes must be complete: situation_type, entity_type, entity_id"
          end
          %w[tenant user project session situation_type entity_type entity_id].each do |key|
            next if normalized[key].nil?

            SafeText.normalize(
              normalized[key], name: "scope #{key}", max_bytes: MAX_ID_BYTES,
              error_class: MemoryPolicyError
            )
          end
          normalized
        end

        def validate_quality(value)
          unless value.is_a?(Numeric) && value.finite? && value.between?(0.0, 1.0)
            raise MemoryPolicyError, "base_quality must be a finite number between 0 and 1"
          end

          value
        end

        def validate_use_counts(value)
          unless value.is_a?(Hash) && %w[successful failed corrected].all? { |k| value[k].is_a?(Integer) }
            raise MemoryPolicyError, "use_counts must carry successful/failed/corrected integers"
          end

          value
        end

        def validate_compatibility(value)
          unless value.is_a?(Hash)
            raise MemoryPolicyError, "compatibility must be an object"
          end
          %w[graph_version behavior_version].each do |key|
            next if value[key].nil?

            SafeText.normalize(
              value[key], name: "compatibility #{key}", max_bytes: MAX_ID_BYTES,
              error_class: MemoryPolicyError
            )
          end
          value
        end

        def validate_transition(value)
          unless value.is_a?(Hash) && value.key?("actor") && value.key?("reason")
            raise MemoryPolicyError, "transition must carry actor and reason"
          end
          %w[actor authority trace_id policy_version].each do |key|
            next if value[key].nil?

            SafeText.normalize(
              value[key], name: "transition #{key}", max_bytes: MAX_ID_BYTES,
              error_class: MemoryPolicyError
            )
          end
          value
        end
      end
    end
  end
end
