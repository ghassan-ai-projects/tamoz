# frozen_string_literal: true

module Tamoz
  module Approval
    # Port: durable or in-memory append-only decision log. Appends are
    # idempotent on decision_id. `lookup` returns a record whose :decision is
    # the full stored Decision — durable implementations reconstruct it from
    # columns, so `append` records must carry nothing a column cannot hold.
    # Resolution is one-per-decision: `record_resolution` returns the stored
    # resolution (answer/scope/actor_evidence/grant) and raises
    # ConflictingResolutionError when a different answer or scope arrives.
    class DecisionLog
      def append(record)
        raise NotImplementedError
      end

      def lookup(decision_id)
        raise NotImplementedError
      end

      def record_resolution(decision_id:, answer:, scope:, actor_evidence:, grant:)
        raise NotImplementedError
      end

      def lookup_resolution(decision_id)
        raise NotImplementedError
      end

      # The §2.6 audit record: who rebound one session's mode, when, from and
      # to which rev. Appends are idempotent on the switch id; a different
      # switch arriving under a taken id is a defect, not a retry.
      def record_mode_switch(id:, session_id:, actor_id:, from_rev:, to_rev:, profile_name:, ts_ms:)
        raise NotImplementedError
      end

      def lookup_mode_switch(id)
        raise NotImplementedError
      end

      # The newest switch recorded for a session, or nil. Durable engines use
      # this to re-pin a session's rev across process restarts.
      def latest_mode_switch(session_id)
        raise NotImplementedError
      end

      # The newest decision already logged for this exact request identity, or
      # nil. A replayed gate reuses it instead of deciding again under a moved
      # policy — the issuing decision owns the step until it settles.
      def latest_decision_for(session_id:, argv_digest:, targets_digest:, step_scope:)
        raise NotImplementedError
      end

      # When the decision was logged (epoch ms), for ask-age clocks: a parked
      # approval times out by how long the ASK has been pending, not by how
      # long its occurrence has existed.
      def decision_created_at_ms(decision_id)
        raise NotImplementedError
      end
    end

    # In-memory implementation for tests and the one-shot runtime.
    class MemoryDecisionLog < DecisionLog
      def initialize
        @decisions = {}
        @resolutions = {}
        @mode_switches = {}
        @mutex = Mutex.new
      end

      def append(record)
        @mutex.synchronize do
          existing = @decisions[record[:decision_id]]
          if existing
            # step_scope is provenance, not identity: one question asked in two
            # executions shares the decision id and keeps the first scope.
            return if existing.reject { |key, _| key == :step_scope || key == :created_at_ms } ==
                      record.reject { |key, _| key == :step_scope || key == :created_at_ms }

            raise ConflictingResolutionError,
                  "decision #{record[:decision_id]} already logged with different content"
          end

          @decisions[record[:decision_id]] = record.freeze
        end
        nil
      end

      def lookup(decision_id)
        @mutex.synchronize { @decisions[decision_id] }
      end

      def record_resolution(decision_id:, answer:, scope:, actor_evidence:, grant:)
        @mutex.synchronize do
          existing = @resolutions[decision_id]
          if existing
            unless existing[:answer] == answer && existing[:scope] == scope
              raise ConflictingResolutionError,
                    "decision #{decision_id} already resolved as #{existing[:answer]}/#{existing[:scope]}"
            end

            next existing
          end

          @resolutions[decision_id] = {
            answer: answer,
            scope: scope,
            actor_evidence: actor_evidence,
            grant: grant
          }.freeze
        end
      end

      def lookup_resolution(decision_id)
        @mutex.synchronize { @resolutions[decision_id] }
      end

      # Idempotent on the switch id; the identity is who/where/from/to, so a
      # replayed append with a fresh ts_ms returns the originally stored record.
      def record_mode_switch(id:, session_id:, actor_id:, from_rev:, to_rev:, profile_name:, ts_ms:)
        record = {
          id: id, session_id: session_id, actor_id: actor_id,
          from_rev: from_rev, to_rev: to_rev, profile_name: profile_name, ts_ms: ts_ms
        }.freeze
        stored = @mutex.synchronize do
          existing = @mode_switches[id]
          if existing
            unless existing[:session_id] == session_id && existing[:actor_id] == actor_id &&
                   existing[:from_rev] == from_rev && existing[:to_rev] == to_rev &&
                   existing[:profile_name] == profile_name
              raise ConflictingResolutionError,
                    "mode switch #{id} already recorded with different content"
            end

            next existing
          end

          @mode_switches[id] = record
          record
        end
        stored
      end

      def lookup_mode_switch(id)
        @mutex.synchronize { @mode_switches[id] }
      end

      def latest_mode_switch(session_id)
        @mutex.synchronize do
          @mode_switches.values
                        .select { |record| record[:session_id] == session_id.to_s }
                        .max_by { |record| [record[:ts_ms], record[:id]] }
        end
      end

      def decision_created_at_ms(decision_id)
        record = lookup(decision_id)
        record && record[:created_at_ms]
      end

      def latest_decision_for(session_id:, argv_digest:, targets_digest:, step_scope:)
        found = @mutex.synchronize do
          @decisions.values.reverse.find do |record|
            record[:session_id] == session_id &&
              record[:argv_digest] == argv_digest && record[:targets_digest] == targets_digest &&
              record[:step_scope] == step_scope
          end
        end
        found && found.fetch(:decision)
      end

      def records
        @mutex.synchronize { @decisions.values }
      end
    end
  end
end
