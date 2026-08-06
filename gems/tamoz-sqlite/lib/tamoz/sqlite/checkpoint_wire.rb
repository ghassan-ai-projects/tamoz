# frozen_string_literal: true

# Tamoz::SQLite::CheckpointWire — the checkpoint store's wire layer (Q3):
# stored bytes become verified values. Validators guard enums/statuses/
# canonicality; the row decoders materialize tamoz_requests and
# tamoz_checkpoints rows into their graph records, failing closed with
# CheckpointCorruptionError on any digest or canonicality mismatch. Pinned by
# the sqlite checkpoint/request-inbox/corruption tests.
module Tamoz
  module SQLite
    # Stateless over stored checkpoint/request bytes. Corruption or bad input
    # never silently passes; each method guards one wire contract.
    class CheckpointWire
      REQUEST_STATUSES = %w[queued claimed running redirecting completed failed].freeze
      REQUEST_OPERATIONS = %w[
        turn resume retry continue fork redirect
      ].freeze
      DELIVERY_MODES = %w[queue redirect].freeze

      def initialize(checkpoint_codec:)
        @checkpoint_codec = checkpoint_codec
      end

      def enum_text(value, allowed, name)
        text = value.to_s
        return text if allowed.include?(text)

        raise ConfigurationError, "#{name} is invalid"
      end

      # :reek:FeatureEnvy -- validating these params IS this class's purpose;
      # the rules cannot move to the value or the allowed list.
      def persisted_enum_symbol(value, allowed, name)
        return value.to_sym if value.is_a?(String) && allowed.include?(value)

        raise CheckpointCorruptionError, "stored #{name} is invalid"
      end

      def request_status(value)
        raise CheckpointCorruptionError, 'request status is invalid' unless REQUEST_STATUSES.include?(value)

        value.to_sym
      end

      def canonical_state_value(bytes, name)
        codec = @checkpoint_codec.state_codec
        value = codec.load(bytes)
        # Byte comparison: stored BLOBs decode as ASCII-8BIT (see
        # EffectJournal#decode_receipt).
        raise CheckpointCorruptionError, "#{name} is not canonical" unless codec.dump(value).b == bytes.b

        value
      end

      # :reek:TooManyStatements :reek:FeatureEnvy :reek:NilCheck
      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      # A declarative row->record mapping (CODING_STANDARD §6): the field list
      # IS the wire contract; splitting it would scatter the mapping. The
      # nullable retryable flag decodes as nil/0/1 — that nil-check is the wire
      # contract for a tri-state column.
      def materialize_request(row)
        payload = row.fetch(8)
        Wire.verify_digest!(
          payload,
          row.fetch(9),
          domain: 'tamoz.sqlite.request_payload'
        )
        operation = persisted_enum_symbol(
          row.fetch(5),
          REQUEST_OPERATIONS,
          'request operation'
        )
        delivery_mode = persisted_enum_symbol(
          row.fetch(6),
          DELIVERY_MODES,
          'request delivery mode'
        )
        decoded_payload = @checkpoint_codec.load_request_payload(
          operation,
          payload
        )
        # Byte comparison: stored BLOBs decode as ASCII-8BIT (see
        # EffectJournal#decode_receipt).
        unless @checkpoint_codec.dump_request_payload(
          operation,
          decoded_payload
        ).b == payload.b
          raise CheckpointCorruptionError, 'request payload is not canonical'
        end

        response = row.fetch(14)
        response_digest = row.fetch(15)
        if response
          Wire.verify_digest!(response, response_digest, domain: 'tamoz.sqlite.request_response')
        elsif response_digest
          raise CheckpointCorruptionError, 'request response digest exists without response'
        end
        terminal_error = row.fetch(16)
        error_digest = row.fetch(17)
        if terminal_error
          Wire.verify_digest!(terminal_error, error_digest, domain: 'tamoz.sqlite.request_error')
        elsif error_digest
          raise CheckpointCorruptionError, 'request error digest exists without terminal error'
        end
        retryable_flag = row.fetch(18)
        Tamoz::Graph::RequestRecord.new(
          thread_id: Wire.identity(row.fetch(0), name: 'stored request thread'),
          namespace: Wire.decode_namespace(row.fetch(1)),
          request_id: Wire.identity(
            row.fetch(2),
            name: 'stored request id',
            max_bytes: Wire::MAX_REQUEST_ID_BYTES
          ),
          enqueue_sequence: row.fetch(3),
          input_digest: row.fetch(4).dup.freeze,
          operation:,
          delivery_mode:,
          status: request_status(row.fetch(7)),
          payload: decoded_payload,
          execution_id: row.fetch(10)&.dup&.freeze,
          target_execution_id: row.fetch(11)&.dup&.freeze,
          cancellation_generation: row.fetch(12),
          checkpoint_id: row.fetch(13)&.dup&.freeze,
          response: response && canonical_state_value(response, 'request response'),
          terminal_error: terminal_error &&
                          canonical_state_value(terminal_error, 'request terminal error'),
          retryable: retryable_flag.nil? ? nil : retryable_flag == 1,
          created_at_ms: row.fetch(19),
          updated_at_ms: row.fetch(20)
        )
      end
      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # :reek:FeatureEnvy
      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize
      # A declarative row->Checkpoint mapping; the column cross-check is the
      # wire contract (columns and payload must agree).
      def decode_checkpoint_row(row)
        payload = row.fetch(11)
        Wire.verify_digest!(
          payload,
          row.fetch(12),
          domain: 'tamoz.sqlite.checkpoint_payload'
        )
        attributes = @checkpoint_codec.load(payload)
        unless attributes.fetch(:execution_id) == row.fetch(6) &&
               attributes.fetch(:graph_name) == row.fetch(7) &&
               attributes.fetch(:graph_version) == row.fetch(8) &&
               attributes.fetch(:definition_digest) == row.fetch(9) &&
               attributes.fetch(:status).to_s == row.fetch(10)
          raise CheckpointCorruptionError,
                'checkpoint columns and payload disagree'
        end
        Tamoz::Graph::Checkpoint.new(
          format_version: row.fetch(5),
          id: Wire.identity(row.fetch(0), name: 'stored checkpoint id'),
          sequence: row.fetch(1),
          thread_id: Wire.identity(row.fetch(2), name: 'stored thread id'),
          namespace: Wire.decode_namespace(row.fetch(3)),
          parent_id: row.fetch(4)&.dup&.freeze,
          **attributes
        )
      end

      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize
    end
  end
end
