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
    end

    # In-memory implementation for tests and the one-shot runtime.
    class MemoryDecisionLog < DecisionLog
      def initialize
        @decisions = {}
        @resolutions = {}
        @mutex = Mutex.new
      end

      def append(record)
        @mutex.synchronize do
          existing = @decisions[record[:decision_id]]
          if existing
            return if existing == record

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

      def records
        @mutex.synchronize { @decisions.values }
      end
    end
  end
end
