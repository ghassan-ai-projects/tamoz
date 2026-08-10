# frozen_string_literal: true

module Tamoz
  # The SQLite namespace owns durable effect-journal storage boundaries.
  module SQLite
    # Reads, verifies, and materializes durable effect records and receipts.
    class EffectRecordReader
      def initialize(store:, safeties:, statuses:)
        @store = store
        @safeties = safeties
        @statuses = statuses
        freeze
      end

      def fetch(key)
        effect_key = Wire.identity(key, name: 'effect key')
        row, attempts = fetch_rows(effect_key)
        return nil unless row

        materialize(row, attempts)
      end

      private

      def fetch_rows(effect_key)
        @store.adapter.__send__(:read, operation: 'effect.fetch') do |tx|
          [
            EffectJournalRows.effect(tx, effect_key, 'effect.fetch.row'),
            tx.rows(
              'effect.fetch.attempts',
              <<~SQL,
                SELECT attempt_number, attempt_token, fence, status,
                       deadline_ms, result, result_digest, external_id,
                       error, error_digest, prepared_at_ms, started_at_ms,
                       completed_at_ms
                FROM tamoz_effect_attempts
                WHERE effect_key = ?
                ORDER BY attempt_number
              SQL
              [effect_key]
            )
          ]
        end
      end

      # :reek:FeatureEnvy -- positional row access is the durable column contract;
      # keeping the mapping here prevents callers from decoding raw rows.
      def materialize(row, attempts)
        safety = EffectJournalValidation.checked_symbol!(
          row.fetch(7),
          @safeties,
          'effect safety'
        )
        status = EffectJournalValidation.checked_symbol!(
          row.fetch(8),
          @statuses,
          'effect status'
        )
        materialize_record(row, safety:, status:, attempts:)
      end

      # :reek:FeatureEnvy -- this is the positional durable effect-row mapping.
      # rubocop:disable Metrics/AbcSize
      # :reek:LongParameterList -- row plus the decoded status fields form one
      # durable record mapping.
      def materialize_record(row, safety:, status:, attempts:)
        Tamoz::Graph::EffectRecord.new(
          key: row.fetch(0).dup.freeze,
          thread_id: row.fetch(1).dup.freeze,
          namespace: Wire.decode_namespace(row.fetch(2)),
          execution_id: row.fetch(3).dup.freeze,
          task_id: row.fetch(4).dup.freeze,
          call_index: row.fetch(5),
          operation: row.fetch(6).dup.freeze,
          safety:,
          status:,
          request_digest: row.fetch(9).dup.freeze,
          current_attempt: row.fetch(10),
          requires_reconciliation: row.fetch(11) == 1,
          attempts: materialize_attempts(attempts),
          created_at_ms: row.fetch(12),
          updated_at_ms: row.fetch(13)
        )
      end
      # rubocop:enable Metrics/AbcSize

      def materialize_attempts(attempts)
        attempts.map { |attempt| materialize_attempt(attempt) }.freeze
      end

      # :reek:FeatureEnvy -- the attempt row is a positional durable wire value.
      def materialize_attempt(attempt)
        result = decode_receipt(
          attempt.fetch(5),
          attempt.fetch(6),
          'tamoz.sqlite.effect_result'
        )
        error = decode_receipt(
          attempt.fetch(8),
          attempt.fetch(9),
          'tamoz.sqlite.effect_error'
        )
        materialize_attempt_record(attempt, result:, error:)
      end

      # :reek:FeatureEnvy -- this is the positional durable attempt-row mapping.
      # :reek:UtilityFunction -- this pure mapping keeps the attempt wire shape
      # together with the record reader's other positional mappings.
      def materialize_attempt_record(attempt, result:, error:)
        Tamoz::Graph::EffectAttempt.new(
          attempt_number: attempt.fetch(0),
          attempt_token: attempt.fetch(1).dup.freeze,
          fence: attempt.fetch(2),
          status: EffectJournalValidation.checked_symbol!(
            attempt.fetch(3),
            %w[prepared running succeeded failed unknown abandoned],
            'effect attempt status'
          ),
          deadline_ms: attempt.fetch(4),
          result:,
          external_id: attempt.fetch(7)&.dup&.freeze,
          error:,
          prepared_at_ms: attempt.fetch(10),
          started_at_ms: attempt.fetch(11),
          completed_at_ms: attempt.fetch(12)
        )
      end

      # :reek:NilCheck -- nil payloads are the durable representation of an
      # attempt without a receipt; a digest beside nil is corruption.
      # :reek:TooManyStatements -- the ordered nil, digest, decode, and
      # canonicality checks are one corruption boundary.
      def decode_receipt(bytes, digest, domain)
        if bytes.nil?
          raise IntegrityError, "#{domain} digest exists without payload" if digest

          return nil
        end
        Wire.verify_digest!(bytes, digest, domain:)
        codec = @store.checkpoint_codec.state_codec
        value = codec.load(bytes)
        # Canonicality is a BYTE property. SQLite returns BLOB columns as
        # ASCII-8BIT while the codec dumps UTF-8, so == is false for any
        # byte-identical payload that is not ASCII-only — one non-ASCII
        # character in a model reply would forge a corruption error.
        raise CheckpointCorruptionError, "#{domain} payload is not canonical" unless
          codec.dump(value).b == bytes.b

        value
      end
    end

    private_constant :EffectRecordReader
  end
end
