# frozen_string_literal: true

require "digest"

module Tamoz
  module Scheduler
    # P13-D (SCHEDULER_DESIGN §5) — the Occurrence value.
    #
    # Identity derives from `(schedule_id, schedule_revision, nominal_fire_at_utc)`
    # and `request_id` is a deterministic digest of that identity. Jitter changes
    # `not_before`, never the identity or the nominal instant. A crash at any
    # seam can repeat delivery, but the request inbox commits ONE logical turn:
    # the enqueue primitive keys on the request id and accepts a duplicate only
    # when the payload is byte-identical.
    #
    # The state machine is closed and typed: due → claimed → enqueued →
    # running → succeeded|failed|cancelled|unknown, with due → skipped(reason)
    # and due → coalesced(into occurrence id). `enqueued` is never terminal on
    # its own — delivery is not execution success (hard zero: no false green).
    Occurrence = Data.define(
      :occurrence_id, :schedule_id, :schedule_revision,
      :nominal_fire_at_utc, :not_before,
      :state, :fence, :owner,
      :request_id, :reason,
      :created_at, :updated_at
    ) do
      STATES = %i[due claimed enqueued running succeeded failed cancelled unknown
                  skipped coalesced].freeze
      TERMINAL = %i[succeeded failed cancelled unknown skipped coalesced].freeze
      IDENTITY_DOMAIN = "tamoz.scheduler.occurrence.v1\n"

      # Deterministic occurrence identity from the three load-bearing fields.
      def self.identity(schedule_id, schedule_revision, nominal_fire_at_utc)
        components = [
          String(schedule_id), Integer(schedule_revision), Integer(nominal_fire_at_utc)
        ]
        Tamoz::Core.digest(IDENTITY_DOMAIN, components)
      end

      # The request id the enqueue primitive keys on: a digest of the identity
      # itself, so a retried delivery re-materializes the SAME request row.
      def self.request_id(occurrence_id)
        "sha256:#{Digest::SHA256.hexdigest(IDENTITY_DOMAIN + String(occurrence_id))}"
      end

      def initialize(
        schedule_id:, schedule_revision:, nominal_fire_at_utc:,
        not_before: nominal_fire_at_utc, state: :due,
        fence: nil, owner: nil,
        reason: nil, created_at:, updated_at: created_at
      )
        occurrence_id = self.class.identity(
          schedule_id, schedule_revision, nominal_fire_at_utc
        )
        validate!(state:, nominal_fire_at_utc:, not_before:, created_at:, updated_at:)
        super(
          occurrence_id:, schedule_id:, schedule_revision:,
          nominal_fire_at_utc:, not_before:,
          state:, fence:, owner:,
          request_id: self.class.request_id(occurrence_id),
          reason:, created_at:, updated_at:
        )
      end

      # --- transitions (closed; each returns a NEW value) ------------------

      def claimed(fence:, owner:, now:)
        raise SchedulerError, "occurrence #{occurrence_id} is #{state}" unless state == :due

        with_state(:claimed, now:, fence:, owner:)
      end

      def enqueued(fence:, now:)
        unless state == :claimed
          raise SchedulerError,
                "occurrence #{occurrence_id} is #{state}, not claimed"
        end

        with_state(:enqueued, now:, fence:, owner:)
      end

      def running(execution_id, now:)
        raise SchedulerError, "occurrence #{occurrence_id} is not enqueued" unless state == :enqueued

        with_state(:running, now:, reason: execution_id)
      end

      def succeeded(execution_id, evidence, now:)
        transition_from_running(:succeeded, execution_id, evidence, now)
      end

      def failed(execution_id, evidence, now:)
        transition_from_running(:failed, execution_id, evidence, now)
      end

      def cancelled(execution_id, evidence, now:)
        transition_from_running(:cancelled, execution_id, evidence, now)
      end

      def unknown(execution_id, evidence, now:)
        transition_from_running(:unknown, execution_id, evidence, now)
      end

      def skipped(reason, now:)
        raise SchedulerError, "occurrence #{occurrence_id} is not due" unless state == :due

        with_state(:skipped, now:, reason:)
      end

      def coalesced(into_occurrence_id, now:)
        raise SchedulerError, "occurrence #{occurrence_id} is not due" unless state == :due

        with_state(:coalesced, now:, reason: into_occurrence_id)
      end

      def terminal? = TERMINAL.include?(state)

      def to_h
        {
          "occurrence_id" => occurrence_id,
          "schedule_id" => schedule_id,
          "schedule_revision" => schedule_revision,
          "nominal_fire_at_utc" => nominal_fire_at_utc,
          "not_before" => not_before,
          "state" => state.to_s,
          "fence" => fence,
          "owner" => owner,
          "request_id" => request_id,
          "reason" => reason,
          "created_at" => created_at,
          "updated_at" => updated_at
        }
      end

      private

      def transition_from_running(to, execution_id, evidence, now)
        unless state == :running
          raise SchedulerError,
                "occurrence #{occurrence_id} is #{state}, not running"
        end

        with_state(to, now:, reason: {"execution_id" => execution_id, "evidence" => evidence})
      end

      def with_state(to, now:, reason: self.reason, fence: self.fence, owner: self.owner)
        Occurrence.new(
          schedule_id:, schedule_revision:, nominal_fire_at_utc:,
          not_before:, state: to, fence:, owner:,
          reason:, created_at:, updated_at: now
        )
      end

      def validate!(state:, nominal_fire_at_utc:, not_before:, created_at:, updated_at:)
        unless STATES.include?(state)
          raise SchedulerError, "unknown occurrence state #{state.inspect}"
        end

        validate_time!(nominal_fire_at_utc, "nominal_fire_at_utc")
        unless not_before.is_a?(Integer) && not_before >= nominal_fire_at_utc
          raise SchedulerError, "not_before must not precede the nominal instant"
        end

        validate_time!(created_at, "created_at")
        unless updated_at.is_a?(Integer) && updated_at >= created_at
          raise SchedulerError, "updated_at must not precede created_at"
        end
      end

      def validate_time!(value, name)
        return if value.is_a?(Integer) && value.positive?

        raise SchedulerError, "#{name} must be a positive UTC epoch second"
      end
    end
  end
end
