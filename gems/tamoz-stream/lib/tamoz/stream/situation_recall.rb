# frozen_string_literal: true

require "tamoz/core"

module Tamoz
  module Stream
    # Storage-agnostic boundary for related Situation memory. Only safe
    # projections and audit metadata cross this boundary; a storage adapter
    # must never expose its rows or canonical MemoryRecord objects here.
    module SituationRecall
      DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/.freeze
      SCOPE_FIELDS = %w[tenant situation_type entity_type entity_id].freeze
      PROVENANCE_FIELDS = %w[episode_id decision_id command_id outcome_id].freeze

      Projection = Data.define(:statement, :scopes, :provenance, :digest) do
        def initialize(statement:, scopes:, provenance:, digest:)
          values = {
            statement: String(statement),
            scopes: normalize_hash(scopes, "scopes"),
            provenance: normalize_hash(provenance, "provenance"),
            digest: String(digest)
          }
          unless values.fetch(:digest).match?(SituationRecall::DIGEST_PATTERN)
            raise ArgumentError, "recall projection digest must be sha256:<64 lowercase hex>"
          end
          validate_fields!(values.fetch(:scopes), SCOPE_FIELDS, "scopes")
          validate_fields!(values.fetch(:provenance), SituationRecall::PROVENANCE_FIELDS, "provenance")

          super(**values.transform_values { |value| Tamoz::Core.deep_freeze(value) })
        end

        def to_h
          {
            "statement" => statement,
            "scopes" => scopes,
            "provenance" => provenance,
            "digest" => digest
          }.freeze
        end

        private

        def validate_fields!(value, fields, name)
          unless value.keys.sort == fields.sort && value.values.all? { |entry| entry.is_a?(String) && !entry.empty? }
            raise ArgumentError, "recall projection #{name} is incomplete or unsafe"
          end
        end

        def normalize_hash(value, name)
          raise ArgumentError, "#{name} must be a Hash" unless value.is_a?(Hash)

          value.to_h { |key, entry| [String(key), entry] }
        end
      end

      Result = Data.define(:records, :record_digests, :restricted, :dropped, :truncated) do
        def initialize(records: [], record_digests: [], restricted: [], dropped: [], truncated: false)
          normalized_records = Array(records).map do |record|
            raise ArgumentError, "recall records must be projections" unless record.is_a?(Projection)

            record
          end
          normalized_digests = Array(record_digests).map(&:to_s)
          unless normalized_digests == normalized_records.map(&:digest)
            raise ArgumentError, "recall digests must match the ordered projections"
          end

          super(
            records: normalized_records.freeze,
            record_digests: Tamoz::Core.deep_freeze(normalized_digests),
            restricted: Tamoz::Core.deep_freeze(Array(restricted)),
            dropped: Tamoz::Core.deep_freeze(Array(dropped)),
            truncated: !!truncated
          )
        end

        def projections
          records.map(&:to_h).freeze
        end
      end

      module_function

      def validate!(result)
        unless result.is_a?(Result)
          raise ArgumentError, "situation recaller must return Tamoz::Stream::SituationRecall::Result"
        end

        result
      end
    end
  end
end
