# frozen_string_literal: true

require "json"

require "tamoz/core"
require "tamoz/stream/verification_store"

module Tamoz
  module SQLite
    # Durable implementation of the stream verification contract. The row
    # transition and its idempotency decision happen in one SQLite transaction.
    class VerificationStore
      Row = Tamoz::Stream::VerificationStore::Row
      VERDICTS = Tamoz::Stream::VerificationStore::VERDICTS
      LEARNABLE_VERDICTS = Tamoz::Stream::VerificationStore::LEARNABLE_VERDICTS
      STATES = Tamoz::Stream::VerificationStore::STATES
      COLUMNS = %w[
        tenant_id intent_id command_id decision_id episode_id attempt_id decision_digest episode state
        outcome_id outcome_digest verdict reconciliation_version source_authority opened_at
        reconciled_at learnable
      ].freeze
      VerificationError = Tamoz::Stream::VerificationStore::VerificationError

      def initialize(adapter:, clock: -> { Time.now })
        @adapter = adapter
        @clock = clock
      end

      def open(tenant_id:, intent_id:, episode_id:, attempt_id:, decision_digest:, episode:,
               command_id: nil, decision_id:)
        values = open_values(
          tenant_id:, intent_id:, episode_id:, attempt_id:, decision_digest:, episode:,
          command_id:, decision_id:
        )
        @adapter.__send__(:transaction, operation: "stream.verification.open") do |tx|
          existing = find_in_transaction(tx, values.fetch(:tenant_id), values.fetch(:intent_id))
          if existing
            next self if equivalent_open?(existing, values)

            raise VerificationError, "conflicting duplicate verification #{intent_id}"
          end

          tx.execute(
            "stream.verification.open",
            <<~SQL,
              INSERT INTO tamoz_stream_verifications(
                tenant_id, intent_id, command_id, decision_id, episode_id, attempt_id,
                decision_digest, episode, state, opened_at, learnable
              ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'awaiting', ?, 0)
            SQL
            [
              values.fetch(:tenant_id), values.fetch(:intent_id), values[:command_id], values.fetch(:decision_id),
              values.fetch(:episode_id), values.fetch(:attempt_id), values.fetch(:decision_digest),
              values.fetch(:episode_json), now
            ]
          )
          self
        end
      end

      def record_outcome(tenant_id:, intent_id:, outcome_id:, outcome_digest:, command_id:)
        tenant_id = text!(tenant_id, "tenant_id")
        intent_id = text!(intent_id, "intent_id")
        outcome_id = text!(outcome_id, "outcome_id")
        outcome_digest = digest!(outcome_digest, "outcome_digest")
        command_id = text!(command_id, "command_id")
        @adapter.__send__(:transaction, operation: "stream.verification.record") do |tx|
          row = find_in_transaction(tx, tenant_id, intent_id)
          raise VerificationError, "no verification for intent #{intent_id}" unless row
          if %i[observed reconciled].include?(row.state)
            next self if row.outcome_id == outcome_id &&
              row.outcome_digest == outcome_digest && row.command_id == command_id

            raise VerificationError, "conflicting duplicate outcome for #{intent_id}"
          end
          unless row.state == :awaiting
            raise VerificationError, "cannot record an outcome for a #{row.state} verification"
          end

          tx.execute(
            "stream.verification.record",
            <<~SQL,
              UPDATE tamoz_stream_verifications
              SET command_id = ?, outcome_id = ?, outcome_digest = ?, state = 'observed'
              WHERE tenant_id = ? AND intent_id = ? AND state = 'awaiting'
            SQL
            [command_id, outcome_id, outcome_digest, tenant_id, intent_id]
          )
          raise VerificationError, "verification changed concurrently" unless tx.changes == 1

          self
        end
      end

      def reconcile(tenant_id:, intent_id:, command_id:, outcome_id:, outcome_digest:, verdict:,
                    reconciliation_version:, source_authority:)
        tenant_id = text!(tenant_id, "tenant_id")
        intent_id = text!(intent_id, "intent_id")
        command_id = text!(command_id, "command_id")
        outcome_id = text!(outcome_id, "outcome_id")
        outcome_digest = digest!(outcome_digest, "outcome_digest")
        verdict = verdict.to_s
        unless VERDICTS.include?(verdict)
          raise VerificationError, "unknown verdict #{verdict.inspect}"
        end
        unless reconciliation_version.is_a?(Integer) && reconciliation_version.positive?
          raise VerificationError, "reconciliation_version must be a positive integer"
        end
        source_authority = text!(source_authority, "source_authority")
        @adapter.__send__(:transaction, operation: "stream.verification.reconcile") do |tx|
          row = find_in_transaction(tx, tenant_id, intent_id)
          raise VerificationError, "no verification for intent #{intent_id}" unless row
          unless row.command_id == command_id && row.outcome_id == outcome_id &&
                 row.outcome_digest == outcome_digest
            raise VerificationError, "reconciliation outcome identity conflicts for #{intent_id}"
          end
          if row.state == :reconciled
            next self if row.verdict == verdict &&
              row.reconciliation_version == reconciliation_version &&
              row.source_authority == source_authority

            raise VerificationError, "conflicting duplicate reconciliation for #{intent_id}"
          end
          unless row.state == :observed
            raise VerificationError, "cannot reconcile a #{row.state} verification"
          end

          tx.execute(
            "stream.verification.reconcile",
            <<~SQL,
              UPDATE tamoz_stream_verifications
              SET state = 'reconciled', verdict = ?, reconciliation_version = ?,
                  source_authority = ?, reconciled_at = ?,
                  learnable = CASE WHEN ? IN ('verified', 'refuted')
                                   AND outcome_id IS NOT NULL THEN 1 ELSE 0 END
              WHERE tenant_id = ? AND intent_id = ? AND state = 'observed'
            SQL
            [verdict, reconciliation_version, source_authority, now, verdict, tenant_id, intent_id]
          )
          raise VerificationError, "verification changed concurrently" unless tx.changes == 1

          self
        end
      end

      def reference(tenant_id:, intent_id:)
        row = fetch(tenant_id:, intent_id:)
        return nil unless row.learnable?

        {
          "outcome_id" => row.outcome_id,
          "outcome_digest" => row.outcome_digest,
          "command_id" => row.command_id,
          "decision_id" => row.decision_id,
          "source_authority" => row.source_authority,
          "reconciliation_version" => row.reconciliation_version,
          "observation_status" => row.verdict,
          "episode_id" => row.episode_id,
          "attempt_id" => row.attempt_id
        }.freeze
      end

      def fetch(tenant_id:, intent_id:)
        tenant_id = text!(tenant_id, "tenant_id")
        intent_id = text!(intent_id, "intent_id")
        @adapter.__send__(:read, operation: "stream.verification.fetch") do |tx|
          row = find_in_transaction(tx, tenant_id, intent_id)
          raise VerificationError, "no verification for intent #{intent_id}" unless row

          row
        end
      end

      def all
        @adapter.__send__(:read, operation: "stream.verification.all") do |tx|
          tx.rows(
            "stream.verification.all",
            "SELECT #{COLUMNS.join(", ")} FROM tamoz_stream_verifications " \
            "ORDER BY tenant_id COLLATE BINARY, intent_id COLLATE BINARY"
          ).map { |values| row_from_values(values) }.freeze
        end
      end

      private

      def open_values(tenant_id:, intent_id:, episode_id:, attempt_id:, decision_digest:, episode:,
                      command_id:, decision_id:)
        {
          tenant_id: text!(tenant_id, "tenant_id"),
          intent_id: text!(intent_id, "intent_id"),
          command_id: optional_text(command_id, "command_id"),
          decision_id: text!(decision_id, "decision_id"),
          episode_id: text!(episode_id, "episode_id"),
          attempt_id: text!(attempt_id, "attempt_id"),
          decision_digest: digest!(decision_digest, "decision_digest"),
          episode_json: canonical_episode(episode)
        }
      end

      def find_in_transaction(tx, tenant_id, intent_id)
        values = tx.first(
          "stream.verification.find",
          "SELECT #{COLUMNS.join(", ")} FROM tamoz_stream_verifications " \
          "WHERE tenant_id = ? AND intent_id = ?",
          [text!(tenant_id, "tenant_id"), text!(intent_id, "intent_id")]
        )
        values && row_from_values(values)
      end

      def row_from_values(values)
        fields = COLUMNS.zip(values).to_h
        Row.new(
          tenant_id: fields.fetch("tenant_id"),
          intent_id: fields.fetch("intent_id"),
          command_id: fields["command_id"],
          decision_id: fields.fetch("decision_id"),
          episode_id: fields.fetch("episode_id"),
          attempt_id: fields.fetch("attempt_id"),
          decision_digest: fields.fetch("decision_digest"),
          episode: decode_episode(fields.fetch("episode")),
          state: fields.fetch("state").to_sym,
          outcome_id: fields["outcome_id"],
          outcome_digest: fields["outcome_digest"],
          verdict: fields["verdict"],
          reconciliation_version: fields["reconciliation_version"],
          source_authority: fields["source_authority"],
          opened_at: fields.fetch("opened_at"),
          reconciled_at: fields["reconciled_at"],
          learnable: fields.fetch("learnable") == 1
        )
      end

      def equivalent_open?(row, values)
        row.intent_id == values.fetch(:intent_id) &&
          row.command_id == values[:command_id] &&
          row.decision_id == values.fetch(:decision_id) &&
          row.episode_id == values.fetch(:episode_id) &&
          row.attempt_id == values.fetch(:attempt_id) &&
          row.decision_digest == values.fetch(:decision_digest) &&
          Tamoz::Core.jcs(row.episode) == values.fetch(:episode_json)
      end

      def canonical_episode(episode)
        normalized = stringify(episode)
        json = Tamoz::Core.jcs(normalized)
        parsed = Tamoz::Core.parse_json_strict(json)
        unless parsed.is_a?(Hash) && Tamoz::Core.jcs(parsed) == json
          raise VerificationError, "episode content is not canonical JSON"
        end

        json
      rescue Tamoz::Error, JSON::ParserError, TypeError => error
        raise VerificationError, "episode content is malformed: #{error.class}"
      end

      def decode_episode(json)
        parsed = Tamoz::Core.parse_json_strict(json)
        unless parsed.is_a?(Hash) && Tamoz::Core.jcs(parsed) == json
          raise VerificationError, "durable episode content is not canonical JSON"
        end

        Tamoz::Core.deep_freeze(parsed)
      rescue Tamoz::Error, JSON::ParserError, TypeError => error
        raise VerificationError, "durable episode content is malformed: #{error.class}"
      end

      def stringify(value)
        case value
        when Hash
          value.to_h { |key, entry| [String(key), stringify(entry)] }
        when Array
          value.map { |entry| stringify(entry) }
        else
          value
        end
      end

      def text!(value, name)
        text = String(value)
        raise VerificationError, "#{name} is required" if text.empty?
        raise VerificationError, "#{name} is too long" if text.bytesize > 256

        text
      rescue TypeError
        raise VerificationError, "#{name} is required"
      end

      def optional_text(value, name)
        value.nil? ? nil : text!(value, name)
      end

      def digest!(value, name)
        digest = text!(value, name)
        raise VerificationError, "#{name} must be a sha256 digest" unless Tamoz::Core.valid_digest?(digest)

        digest
      end

      def now
        value = @clock.call
        raise VerificationError, "verification clock must return Time" unless value.is_a?(Time)

        value.to_i
      end
    end
  end
end
