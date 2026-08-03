# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Stream
    # P14-D (design §5) — the ChannelDescriptor: a content-addressed deployed
    # contract for one read-only source channel.
    #
    # Every field is validated and frozen; the definition digest binds the
    # deployed contract (a revision is a new digest). The descriptor is
    # deterministic configuration, never code. `partition_by` and `time`
    # configure the deterministic core; `delivery` is at-least-once plus
    # application dedup (never transport exactly-once).
    ChannelDescriptor = Data.define(
      :channel_id, :revision, :transport, :source_identity, :schema,
      :partition_by, :delivery, :max_event_bytes, :queue_capacity,
      :spool_capacity_bytes, :overflow, :time, :classification, :units,
      :definition_digest
    ) do
      DELIVERY_MODES = %i[at_least_once].freeze
      OVERFLOW_POLICIES = %i[block retry spill_then_reject sample coalesce reject].freeze
      CLASSIFICATIONS = %i[internal restricted public].freeze
      DIGEST_DOMAIN = "tamoz.stream.channel_descriptor.v1\n"
      ID_PATTERN = Patterns::LOWERCASE_ID_PATTERN
      SOURCE_PATTERN = Patterns::SOURCE_PATTERN

      def initialize(
        channel_id:, revision:, transport:, source_identity:, schema:,
        partition_by:, delivery: :at_least_once, max_event_bytes: 16_384,
        queue_capacity: 2_000, spool_capacity_bytes: 268_435_456,
        overflow: :spill_then_reject, time: {}, classification: :internal,
        units: {}, definition_digest: nil
      )
        validated = validate!(
          channel_id:, revision:, transport:, source_identity:, schema:,
          partition_by:, delivery:, max_event_bytes:, queue_capacity:,
          spool_capacity_bytes:, overflow:, time:, classification:, units:
        )
        @digest = definition_digest || compute_digest(validated)
        super(**validated, definition_digest: @digest)
      end

      def to_h
        {
          "channel_id" => channel_id, "revision" => revision,
          "transport" => transport, "source_identity" => source_identity,
          "schema" => schema, "partition_by" => partition_by,
          "delivery" => delivery.to_s, "max_event_bytes" => max_event_bytes,
          "queue_capacity" => queue_capacity,
          "spool_capacity_bytes" => spool_capacity_bytes,
          "overflow" => overflow.to_s, "time" => time,
          "classification" => classification.to_s, "units" => units,
          "definition_digest" => definition_digest
        }
      end

      private

      def compute_digest(fields)
        definition = fields.reject { |key, _value| key == :definition_digest }
        "sha256:#{Digest::SHA256.hexdigest(
          DIGEST_DOMAIN + JSON.generate(Tamoz::Core.canonical(definition))
        )}"
      end

      def validate!(
        channel_id:, revision:, transport:, source_identity:, schema:,
        partition_by:, delivery:, max_event_bytes:, queue_capacity:,
        spool_capacity_bytes:, overflow:, time:, classification:, units:
      )
        unless channel_id.is_a?(String) && ID_PATTERN.match?(channel_id)
          raise Tamoz::ConfigurationError, "channel_id must be a bounded lowercase identifier"
        end
        unless revision.is_a?(Integer) && revision >= 1
          raise Tamoz::ConfigurationError, "revision must be a positive integer"
        end
        unless transport.is_a?(String) && !transport.strip.empty? && transport.bytesize <= 128
          raise Tamoz::ConfigurationError, "transport must be a bounded string"
        end
        unless source_identity.is_a?(String) && SOURCE_PATTERN.match?(source_identity)
          raise Tamoz::ConfigurationError, "source_identity must be a bounded string"
        end
        unless schema.is_a?(String) && !schema.strip.empty? && schema.bytesize <= 128
          raise Tamoz::ConfigurationError, "schema must be a bounded string"
        end
        unless partition_by.is_a?(Array) && partition_by.length.between?(1, 4) &&
               partition_by.all? { |p| p.is_a?(String) && !p.empty? }
          raise Tamoz::ConfigurationError, "partition_by must be 1..4 non-empty strings"
        end
        unless DELIVERY_MODES.include?(delivery)
          raise Tamoz::ConfigurationError, "delivery must be one of #{DELIVERY_MODES.inspect}"
        end
        unless OVERFLOW_POLICIES.include?(overflow)
          raise Tamoz::ConfigurationError, "overflow must be one of #{OVERFLOW_POLICIES.inspect}"
        end
        unless CLASSIFICATIONS.include?(classification)
          raise Tamoz::ConfigurationError, "classification must be one of #{CLASSIFICATIONS.inspect}"
        end
        [max_event_bytes, queue_capacity, spool_capacity_bytes].each do |value|
          unless value.is_a?(Integer) && value.positive?
            raise Tamoz::ConfigurationError, "channel bounds must be positive integers"
          end
        end
        unless time.is_a?(Hash) && time["field"].is_a?(String)
          raise Tamoz::ConfigurationError, "time must declare a field name"
        end
        unless time["max_clock_skew_s"].is_a?(Integer) && time["max_clock_skew_s"].positive?
          raise Tamoz::ConfigurationError, "time.max_clock_skew_s must be a positive integer"
        end
        unless units.is_a?(Hash)
          raise Tamoz::ConfigurationError, "units must be a hash"
        end

        {
          channel_id: channel_id.freeze, revision:, transport: transport.freeze,
          source_identity: source_identity.freeze, schema: schema.freeze,
          partition_by: partition_by.map(&:freeze).freeze, delivery:,
          max_event_bytes:, queue_capacity:, spool_capacity_bytes:, overflow:,
          time: Tamoz::Core.deep_freeze(time),
          classification:,
          units: Tamoz::Core.deep_freeze(units)
        }.freeze
      end
    end
  end
end
