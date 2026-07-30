# frozen_string_literal: true

module Tamoz
  module SQLite
    DeletionAuthorization = Data.define(
      :actor,
      :reason,
      :effect_decisions,
      :lease_fences
    ) do
      def initialize(actor:, reason:, effect_decisions: {}, lease_fences: {})
        normalized_actor = SafeText.normalize(
          actor,
          name: "deletion actor",
          max_bytes: 256,
          error_class: ConfigurationError
        )
        normalized_reason = SafeText.normalize(
          reason,
          name: "deletion reason",
          max_bytes: 4_096,
          error_class: ConfigurationError
        )
        decisions = normalize_hash(effect_decisions, "effect decision") do |value|
          text = value.to_s
          unless text == "abandon"
            raise ConfigurationError,
                  "effect deletion decisions must explicitly be :abandon"
          end
          text.freeze
        end
        fences = normalize_hash(lease_fences, "lease fence") do |value|
          unless value.is_a?(Integer) && value.positive?
            raise ConfigurationError, "lease fences must be positive integers"
          end
          value
        end
        super(
          actor: normalized_actor,
          reason: normalized_reason,
          effect_decisions: decisions,
          lease_fences: fences
        )
        freeze
      end

      private

      def normalize_hash(value, name)
        raise ConfigurationError, "#{name}s must be a Hash" unless value.is_a?(Hash)

        value.each_with_object({}) do |(key, entry), result|
          normalized_key = if key.is_a?(Array)
                             JSON.generate(
                               key.map.with_index do |part, index|
                                 SafeText.normalize(
                                   part,
                                   name: "#{name} key[#{index}]",
                                   max_bytes: 256,
                                   error_class: ConfigurationError
                                 )
                               end
                             )
                           else
                             SafeText.normalize(
                               key,
                               name: "#{name} key",
                               max_bytes: 256,
                               error_class: ConfigurationError
                             )
                           end
          raise ConfigurationError, "duplicate #{name} key" if result.key?(normalized_key)

          result[normalized_key.freeze] = yield(entry)
        end.freeze
      end
    end

    DeletionReport = Data.define(
      :thread_id,
      :tombstone_id,
      :status,
      :namespace_count,
      :checkpoint_count,
      :request_count,
      :effect_count,
      :abandoned_effect_keys,
      :created_at_ms,
      :purge_after_ms
    )

    DeletionReceipt = Data.define(
      :thread_id_digest,
      :tombstone_id,
      :report_digest,
      :purged_at_ms,
      :counts
    )
  end
end
