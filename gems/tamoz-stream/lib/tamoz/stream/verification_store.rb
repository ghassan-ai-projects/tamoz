# frozen_string_literal: true

require "tamoz/stream/errors"

module Tamoz
  module Stream
    # T5.2 (PLAN_TAMOZ_STREAM_BUILD T5.2): asynchronous verification
    # (LIFECYCLES §6, PROTOCOL §6.3). A stream attempt terminates `produced`
    # — an RPC cannot stay open for the three days it can take a technician to
    # clean a coil — and verification proceeds in its own state machine:
    #
    #   awaiting --(outcome.recorded)--> observed --(outcome.reconciled)--> reconciled
    #
    # A reconciled row is learnable only when the verdict settled the
    # question (verified / refuted). `inconclusive` and
    # `superseded_before_verification` are recorded and never learned from —
    # exactly the audit's line: the admission guard exists and this is the
    # machine that feeds it with an authenticated reference, or never feeds
    # it at all.
    #
    # Tamoz never reports acceptance or verification as a worker state — both
    # are the stream's judgments about the worker's output. This store is the
    # tamoz-side bookkeeping that turns a late Channel B outcome into a
    # learnable Experience with provenance intact across the gap.
    class VerificationStore
      VERDICTS = %w[
        verified refuted inconclusive superseded_before_verification
      ].freeze
      LEARNABLE_VERDICTS = %w[verified refuted].freeze
      STATES = %i[awaiting observed reconciled].freeze

      # One verification row, keyed by intent_id (LIFECYCLES §7: unique on
      # intent_id). The episode content is the admission input the subscriber
      # needs when the outcome finally reconciles, so a Friday outcome admits
      # a Tuesday episode with provenance intact.
      Row = Data.define(
        :intent_id, :command_id, :decision_id, :episode_id, :attempt_id, :decision_digest,
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
      end

      # Opens an :awaiting row for one intent of a produced episode. The
      # `episode` hash is the admission content (identity, task, scopes,
      # sensitivity, plan digest) — everything the subscriber needs at
      # reconcile time except the observed outcome itself.
      def open(intent_id:, episode_id:, attempt_id:, decision_digest:, episode:,
               command_id: nil, decision_id: nil)
        if @rows.key?(intent_id)
          raise VerificationError,
                "verification already open for intent #{intent_id}"
        end

        @rows[intent_id] = Row.new(
          intent_id:, command_id:, decision_id:, episode_id:, attempt_id:, decision_digest:,
          episode:, state: :awaiting,
          outcome_id: nil, outcome_digest: nil, verdict: nil,
          reconciliation_version: nil, source_authority: nil,
          opened_at: @clock.call.to_i, reconciled_at: nil, learnable: false
        )
        self
      end

      # At-least-once redelivery (a crash between the handler and the cursor
      # write) re-applies the same outcome — idempotent on the outcome id,
      # never a spurious poison skip. A DIFFERENT outcome for the same intent
      # is still a typed refusal.
      def record_outcome(intent_id:, outcome_id:, outcome_digest:, command_id: nil)
        row = fetch(intent_id:)
        if row.state == :observed && row.outcome_id == outcome_id
          return self
        end
        unless row.state == :awaiting
          raise VerificationError,
                "cannot record an outcome for a #{row.state} verification"
        end

        @rows[intent_id] = row.with(
          state: :observed, outcome_id:, outcome_digest:, command_id:
        )
      end

      # Closes the row on outcome.reconciled. Only learnable verdicts make the
      # row feed admission; the others are recorded and terminal. A row is
      # learnable only when it also carries an outcome id — a reconciled row
      # whose recorded outcome never arrived cannot produce a reference. The
      # same verdict re-applied by redelivery is a no-op.
      def reconcile(intent_id:, verdict:, reconciliation_version:, source_authority:)
        unless VERDICTS.include?(verdict.to_s)
          raise VerificationError,
                "unknown verdict #{verdict.inspect}"
        end
        row = fetch(intent_id:)
        if row.state == :reconciled &&
           row.verdict == verdict.to_s &&
           row.reconciliation_version == reconciliation_version.to_s
          return self
        end
        unless %i[awaiting observed].include?(row.state)
          raise VerificationError,
                "cannot reconcile a #{row.state} verification"
        end

        @rows[intent_id] = row.with(
          state: :reconciled,
          verdict: verdict.to_s,
          reconciliation_version: reconciliation_version.to_s,
          source_authority: source_authority.to_s,
          reconciled_at: @clock.call.to_i,
          learnable: LEARNABLE_VERDICTS.include?(verdict.to_s) && !row.outcome_id.nil?
        )
      end

      # The authenticated reconciled-outcome reference for admission — only
      # for a learnable reconciled row; nil otherwise (the admission boundary
      # refuses everything else anyway).
      def reference(intent_id:)
        row = fetch(intent_id:)
        return nil unless row.learnable?
        return nil if row.outcome_id.nil?

        {
          "outcome_id" => row.outcome_id,
          "outcome_digest" => row.outcome_digest,
          "command_id" => row.command_id.to_s,
          "decision_id" => row.decision_id.to_s,
          "source_authority" => row.source_authority,
          "reconciliation_version" => row.reconciliation_version,
          "observation_status" => row.verdict,
          "episode_id" => row.episode_id,
          "attempt_id" => row.attempt_id
        }
      end

      def fetch(intent_id:)
        row = @rows[intent_id]
        raise VerificationError, "no verification for intent #{intent_id}" unless row

        row
      end

      def all = @rows.values.freeze
    end
  end
end
