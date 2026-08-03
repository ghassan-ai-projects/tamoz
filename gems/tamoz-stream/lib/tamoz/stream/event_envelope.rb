# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Stream
    # P14-D (design §5) — an EventEnvelope: the validated, admitted typed
    # envelope. Identity is scoped by
    # `(tenant_id, channel_id, channel_revision, source_id, event_id)`; the
    # canonical payload hash makes the same-scoped-id-same-hash idempotent and
    # same-id-different-hash a quarantine conflict (invariant 45).
    #
    # Event time comes from the payload's declared time field (bounded skew);
    # observed time and ingestion time are runtime-owned (never payload).
    # Processing time lives on the injected clock, never here.
    EventEnvelope = Data.define(
      :event_id, :event_type, :schema_id, :schema_version, :payload_hash,
      :tenant_id, :source_id, :channel_id, :channel_revision, :partition_key,
      :entity_id, :event_time, :observed_time, :ingestion_time, :sequence,
      :correlation_id, :causation_id, :trace_id, :quality, :units,
      :classification, :payload
    ) do
      IDENTITY_DOMAIN = "tamoz.stream.event_identity.v1\n"
      PAYLOAD_HASH_DOMAIN = "tamoz.stream.event_payload.v1\n"
      ENVELOPE_ID_PATTERN = Patterns::ID_PATTERN

      # The canonical payload hash. Same bytes -> same hash; any byte change
      # -> different hash (the quarantine discriminator).
      def self.payload_hash(payload)
        "sha256:#{Digest::SHA256.hexdigest(
          PAYLOAD_HASH_DOMAIN + JSON.generate(Tamoz::Core.canonical(payload))
        )}"
      end

      # The scoped identity string the store keys on.
      def self.identity(tenant_id, channel_id, channel_revision, source_id, event_id)
        "sha256:#{Digest::SHA256.hexdigest(
          IDENTITY_DOMAIN + JSON.generate(Tamoz::Core.canonical(
            [tenant_id, channel_id, channel_revision, source_id, event_id]
          ))
        )}"
      end

      def initialize(
        event_id:, event_type:, schema_id:, schema_version: 1, payload:,
        tenant_id:, source_id:, channel_id:, channel_revision:, partition_key:,
        entity_id:, event_time:, observed_time:, ingestion_time:, sequence: nil,
        correlation_id: nil, causation_id: nil, trace_id: nil,
        quality: "good", units: {}, classification: :internal
      )
        payload = Tamoz::Core.deep_freeze(payload)
        validate!(
          event_id:, event_type:, schema_id:, schema_version:, tenant_id:,
          source_id:, channel_id:, channel_revision:, partition_key:,
          entity_id:, event_time:, observed_time:, ingestion_time:,
          quality:, classification:, payload:
        )
        super(
          event_id: event_id.freeze, event_type: event_type.freeze,
          schema_id: schema_id.freeze, schema_version:,
          payload_hash: self.class.payload_hash(payload),
          tenant_id: tenant_id.freeze, source_id: source_id.freeze,
          channel_id: channel_id.freeze, channel_revision:,
          partition_key: partition_key.freeze, entity_id: entity_id.freeze,
          event_time:, observed_time:, ingestion_time:,
          sequence: sequence && Integer(sequence),
          correlation_id: correlation_id&.freeze,
          causation_id: causation_id&.freeze,
          trace_id: trace_id&.freeze,
          quality: quality.freeze, units: Tamoz::Core.deep_freeze(units),
          classification:, payload:
        )
      end

      def identity
        self.class.identity(
          tenant_id, channel_id, channel_revision, source_id, event_id
        )
      end

      def to_h
        {
          "event_id" => event_id, "event_type" => event_type,
          "schema_id" => schema_id, "schema_version" => schema_version,
          "payload_hash" => payload_hash, "tenant_id" => tenant_id,
          "source_id" => source_id, "channel_id" => channel_id,
          "channel_revision" => channel_revision, "partition_key" => partition_key,
          "entity_id" => entity_id, "event_time" => event_time,
          "observed_time" => observed_time, "ingestion_time" => ingestion_time,
          "sequence" => sequence, "correlation_id" => correlation_id,
          "causation_id" => causation_id, "trace_id" => trace_id,
          "quality" => quality, "units" => units,
          "classification" => classification.to_s, "payload" => payload
        }
      end

      private

      def validate!(
        event_id:, event_type:, schema_id:, schema_version:, tenant_id:,
        source_id:, channel_id:, channel_revision:, partition_key:,
        entity_id:, event_time:, observed_time:, ingestion_time:,
        quality:, classification:, payload:
      )
        {event_id:, event_type:, schema_id:, tenant_id:, source_id:,
         channel_id:, partition_key:, entity_id:}.each do |name, value|
          unless value.is_a?(String) && ENVELOPE_ID_PATTERN.match?(value)
            raise Tamoz::ConfigurationError, "#{name} must be a bounded string"
          end
        end
        unless schema_version.is_a?(Integer) && schema_version >= 1
          raise Tamoz::ConfigurationError, "schema_version must be a positive integer"
        end
        unless channel_revision.is_a?(Integer) && channel_revision >= 1
          raise Tamoz::ConfigurationError, "channel_revision must be a positive integer"
        end
        [event_time, observed_time, ingestion_time].each do |value|
          unless value.is_a?(Integer) && value.positive?
            raise Tamoz::ConfigurationError, "event timestamps must be positive UTC epoch seconds"
          end
        end
        unless quality.is_a?(String) && !quality.empty?
          raise Tamoz::ConfigurationError, "quality must be a non-empty string"
        end
        unless %i[internal restricted public].include?(classification)
          raise Tamoz::ConfigurationError, "classification must be one of internal/restricted/public"
        end
        # Bounded typed data: depth, fields, strings, arrays, and total bytes.
        unless payload.is_a?(Hash) && payload.size.between?(1, 64)
          raise Tamoz::ConfigurationError, "payload must be a bounded hash"
        end
        total = JSON.generate(payload).bytesize
        unless total <= 16_384
          raise Tamoz::ConfigurationError, "payload exceeds the 16 KiB event bound"
        end
      end
    end
  end
end
