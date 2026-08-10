# frozen_string_literal: true

require_relative "effect_journal_validation"
require_relative "effect_journal_key"
require_relative "effect_journal_rows"
require_relative "effect_transition_log"
require_relative "effect_attempt_ledger"
require_relative "effect_preparation"
require_relative "effect_lifecycle"
require_relative "effect_completion"
require_relative "effect_reconciler"
require_relative "effect_record_reader"

module Tamoz
  module SQLite
    # Durable effect journal façade preserving the graph-facing effect contract.
    # :reek:TooManyInstanceVariables -- the façade retains its public storage
    # collaborators and one immutable collaborator per cohesive effect domain.
    class EffectJournal
      PROTOCOL_VERSION = 1
      SAFETIES = %w[
        read_only idempotent transactional reconcilable unsafe
      ].freeze
      STATUSES = %w[
        prepared running succeeded failed unknown reconcile abandoned
      ].freeze
      TERMINAL_ATTEMPT_STATUSES = %w[succeeded failed abandoned].freeze
      MAX_ATTEMPT_TTL = 3_600.0

      attr_reader :store, :guard, :attempt_ttl

      def initialize(store:, guard:, attempt_ttl: 60.0)
        unless attempt_ttl.is_a?(Numeric) &&
               attempt_ttl.finite? &&
               attempt_ttl >= 0.1 &&
               attempt_ttl <= MAX_ATTEMPT_TTL
          raise ConfigurationError,
                "effect attempt_ttl must be between 0.1 and #{MAX_ATTEMPT_TTL}"
        end

        @store = store
        @guard = guard
        @attempt_ttl = attempt_ttl.to_f
        @record_reader = EffectRecordReader.new(
          store:,
          safeties: SAFETIES,
          statuses: STATUSES
        )
        @preparation = EffectPreparation.new(
          store:,
          guard:,
          attempt_ttl: @attempt_ttl,
          record_reader: @record_reader,
          safeties: SAFETIES
        )
        @lifecycle = EffectLifecycle.new(
          store:,
          guard:,
          record_reader: @record_reader
        )
        @completion = EffectCompletion.new(
          store:,
          record_reader: @record_reader,
          terminal_attempt_statuses: TERMINAL_ATTEMPT_STATUSES
        )
        @reconciler = EffectReconciler.new(
          store:,
          guard:,
          attempt_ttl: @attempt_ttl,
          record_reader: @record_reader
        )
        freeze
      end

      def protocol_version = PROTOCOL_VERSION
      def storage_identity = store.adapter

      # :reek:LongParameterList -- this is the stable public effect identity
      # contract; collapsing its fields would hide the digest inputs.
      def key(execution_id:, task_id:, call_index:, operation:)
        EffectJournalKey.build(
          guard: guard,
          execution_id:,
          task_id:,
          call_index:,
          operation:
        )
      end

      # :reek:LongParameterList -- the public prepare contract names every
      # durable effect binding and request field.
      def prepare(
        execution_id:,
        task_id:,
        call_index:,
        operation:,
        safety:,
        request:
      )
        @preparation.prepare(
          execution_id:,
          task_id:,
          call_index:,
          operation:,
          safety:,
          request:
        )
      end

      def start(key:, attempt_token:)
        @lifecycle.start(key:, attempt_token:)
      end

      # :reek:LongParameterList -- the public completion contract carries the
      # receipt fields that are persisted byte-for-byte.
      def complete(
        key:,
        attempt_token:,
        status:,
        result: nil,
        external_id: nil,
        error: nil
      )
        @completion.complete(
          key:,
          attempt_token:,
          status:,
          result:,
          external_id:,
          error:
        )
      end

      # :reek:LongParameterList -- evidence, actor, and disposition are the
      # public reconciliation audit contract.
      def reconcile(key:, disposition:, actor:, evidence:)
        @reconciler.reconcile(
          key:,
          disposition:,
          actor:,
          evidence:
        )
      end

      # :reek:LongParameterList -- human resolution records all audit fields in
      # the public contract.
      def resolve(key:, status:, actor:, evidence:)
        @reconciler.resolve(
          key:,
          status:,
          actor:,
          evidence:
        )
      end

      def fetch(key)
        @record_reader.fetch(key)
      end

      private_constant :PROTOCOL_VERSION, :SAFETIES, :STATUSES,
                       :TERMINAL_ATTEMPT_STATUSES, :MAX_ATTEMPT_TTL
    end
  end
end
