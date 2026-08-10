# frozen_string_literal: true

require 'json'

module Tamoz
  # Durable SQLite storage and its transaction-boundary collaborators.
  module SQLite
    # Decodes and validates durable tombstone and purge reports.
    # :reek:ControlParameter :reek:DuplicateMethodCall :reek:FeatureEnvy
    # :reek:UncommunicativeVariableName -- the rescue variable names the codec error.
    # Row indexes and report field order are the durable deletion contract.
    class DeletionReportCodec
      def decode_report(bytes, digest:)
        Wire.verify_digest!(
          bytes,
          digest,
          domain: 'tamoz.sqlite.tombstone_report'
        )
        value = JSON.parse(bytes, create_additions: false, max_nesting: 16)
        build_report(value)
      rescue JSON::ParserError, KeyError, TypeError => e
        raise IntegrityError.new('deletion report is invalid'), cause: e
      end

      def decode_receipt(tombstone_id, row)
        Wire.verify_digest!(
          row.fetch(1),
          row.fetch(2),
          domain: 'tamoz.sqlite.deletion_report'
        )
        value = JSON.parse(row.fetch(1), create_additions: false, max_nesting: 16)
        DeletionReceipt.new(
          thread_id_digest: row.fetch(0).dup.freeze,
          tombstone_id: tombstone_id,
          report_digest: row.fetch(2).dup.freeze,
          purged_at_ms: row.fetch(3),
          counts: value.fetch('purged_counts').freeze
        )
      rescue JSON::ParserError, KeyError, TypeError => e
        raise IntegrityError.new('deletion receipt is invalid'), cause: e
      end

      private

      def build_report(value)
        counts = value.fetch('counts')
        DeletionReport.new(**report_attributes(value, counts))
      end

      def report_attributes(value, counts)
        {
          thread_id: value.fetch('thread_id').dup.freeze,
          tombstone_id: value.fetch('tombstone_id').dup.freeze,
          status: report_status(value.fetch('status')),
          namespace_count: counts.fetch('namespaces'),
          checkpoint_count: counts.fetch('checkpoints'),
          request_count: counts.fetch('requests'),
          effect_count: counts.fetch('effects'),
          abandoned_effect_keys: value.fetch('abandoned_effect_keys').map do |key|
            key.dup.freeze
          end.freeze,
          created_at_ms: value.fetch('created_at_ms'),
          purge_after_ms: value.fetch('purge_after_ms')
        }
      end

      def report_status(value)
        case value
        when 'active' then :active
        when 'purged' then :purged
        else
          raise IntegrityError, 'deletion report status is invalid'
        end
      end
    end

    private_constant :DeletionReportCodec
  end
end
