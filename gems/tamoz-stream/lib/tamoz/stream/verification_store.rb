# frozen_string_literal: true

require "json"
require "tamoz/core"
require "tamoz/stream/errors"

module Tamoz
  module Stream
    # In-memory implementation of the storage-agnostic verification contract.
    # Production compositions bind the durable tamoz-sqlite implementation.
    class VerificationStore
      VERDICTS = %w[
        verified refuted inconclusive superseded_before_verification
      ].freeze
      LEARNABLE_VERDICTS = %w[verified refuted].freeze
      STATES = %i[awaiting observed reconciled].freeze

      Row = Data.define(
        :tenant_id, :intent_id, :command_id, :decision_id, :episode_id, :attempt_id, :decision_digest,
        :episode, :state, :outcome_id, :outcome_digest, :verdict,
        :reconciliation_version, :source_authority, :opened_at, :reconciled_at,
        :learnable
      ) do
        def learnable?
          state == :reconciled && learnable
        end
      end

      class VerificationError < StreamError
        CATEGORY = "stream_verification"
      end

      def initialize(clock: -> { Time.now })
        @clock = clock
        @rows = {}
        @lock = Mutex.new
      end

      def open(tenant_id:, intent_id:, episode_id:, attempt_id:, decision_digest:, episode:,
               command_id: nil, decision_id:)
        values = {
          tenant_id: text!(tenant_id, "tenant_id"),
          intent_id: text!(intent_id, "intent_id"),
          command_id: optional_text(command_id, "command_id"),
          decision_id: text!(decision_id, "decision_id"),
          episode_id: text!(episode_id, "episode_id"),
          attempt_id: text!(attempt_id, "attempt_id"),
          decision_digest: digest!(decision_digest, "decision_digest"),
          episode: canonical_episode(episode)
        }
        @lock.synchronize do
          existing = @rows[[values.fetch(:tenant_id), values.fetch(:intent_id)]]
          if existing
            return self if equivalent_open?(existing, values)

            raise VerificationError, "conflicting duplicate verification #{intent_id}"
          end

          @rows[[values.fetch(:tenant_id), values.fetch(:intent_id)]] = Row.new(
            tenant_id: values.fetch(:tenant_id), intent_id: values.fetch(:intent_id),
            command_id: values[:command_id],
            decision_id: values.fetch(:decision_id), episode_id: values.fetch(:episode_id),
            attempt_id: values.fetch(:attempt_id), decision_digest: values.fetch(:decision_digest),
            episode: values.fetch(:episode), state: :awaiting,
            outcome_id: nil, outcome_digest: nil, verdict: nil,
            reconciliation_version: nil, source_authority: nil,
            opened_at: now.to_i, reconciled_at: nil, learnable: false
          )
        end
        self
      end

      def record_outcome(tenant_id:, intent_id:, outcome_id:, outcome_digest:, command_id:)
        tenant_id = text!(tenant_id, "tenant_id")
        intent_id = text!(intent_id, "intent_id")
        outcome_id = text!(outcome_id, "outcome_id")
        outcome_digest = digest!(outcome_digest, "outcome_digest")
        command_id = text!(command_id, "command_id")
        @lock.synchronize do
          row = fetch_locked(tenant_id, intent_id)
          if %i[observed reconciled].include?(row.state)
            return self if row.outcome_id == outcome_id &&
              row.outcome_digest == outcome_digest && row.command_id == command_id

            raise VerificationError, "conflicting duplicate outcome for #{intent_id}"
          end
          unless row.state == :awaiting
            raise VerificationError, "cannot record an outcome for a #{row.state} verification"
          end

          @rows[[tenant_id, intent_id]] = row.with(
            state: :observed, outcome_id:, outcome_digest:, command_id:
          )
        end
        self
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
        @lock.synchronize do
          row = fetch_locked(tenant_id, intent_id)
          unless row.command_id == command_id && row.outcome_id == outcome_id &&
                 row.outcome_digest == outcome_digest
            raise VerificationError, "reconciliation outcome identity conflicts for #{intent_id}"
          end
          if row.state == :reconciled
            return self if row.verdict == verdict &&
              row.reconciliation_version == reconciliation_version &&
              row.source_authority == source_authority

            raise VerificationError, "conflicting duplicate reconciliation for #{intent_id}"
          end
          unless row.state == :observed
            raise VerificationError, "cannot reconcile a #{row.state} verification"
          end

          @rows[[tenant_id, intent_id]] = row.with(
            state: :reconciled, verdict:, reconciliation_version:, source_authority:,
            reconciled_at: now.to_i,
            learnable: LEARNABLE_VERDICTS.include?(verdict) && !row.outcome_id.nil?
          )
        end
        self
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
        @lock.synchronize do
          fetch_locked(text!(tenant_id, "tenant_id"), text!(intent_id, "intent_id"))
        end
      end

      def all
        @lock.synchronize { @rows.values.freeze }
      end

      private

      def fetch_locked(tenant_id, intent_id)
        row = @rows[[tenant_id, intent_id]]
        raise VerificationError, "no verification for intent #{intent_id}" unless row

        row
      end

      def equivalent_open?(row, values)
        row.intent_id == values.fetch(:intent_id) &&
          row.command_id == values[:command_id] &&
          row.decision_id == values.fetch(:decision_id) &&
          row.episode_id == values.fetch(:episode_id) && row.attempt_id == values.fetch(:attempt_id) &&
          row.decision_digest == values.fetch(:decision_digest) && row.episode == values.fetch(:episode)
      end

      def canonical_episode(episode)
        normalized = stringify(episode)
        json = Tamoz::Core.jcs(normalized)
        parsed = Tamoz::Core.parse_json_strict(json)
        unless parsed.is_a?(Hash) && Tamoz::Core.jcs(parsed) == json
          raise VerificationError, "episode content is not canonical JSON"
        end

        Tamoz::Core.deep_freeze(parsed)
      rescue Tamoz::Error, JSON::ParserError, TypeError => error
        raise VerificationError, "episode content is malformed: #{error.class}"
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

        value
      end
    end
  end
end
