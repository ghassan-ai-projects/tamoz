# frozen_string_literal: true

# Tamoz::SQLite::CheckpointWriter — the fenced writer handed to callers of
# CheckpointStore#open_writer (Q3 slice 4). Every mutating method goes through
# the lease guard (fence/check!), so a stale or foreign lease fails closed.
# `store` here is the APPLICATION store (adapter.store); the checkpoint store
# is @store. Pinned by the sqlite checkpoint lease/fencing tests.
module Tamoz
  module SQLite
    # A guarded facade over the checkpoint store's lease-arg operations. The
    # guard carries the lease; callers never touch a lease directly.
    # :reek:TooManyMethods -- each method is one guarded delegation; the facade
    # IS the Writer's public surface, and splitting it would scatter the guard.
    # :reek:MissingSafeMethod -- check! verifies the fenced lease and RAISES on
    # staleness by contract; a boolean twin would invite callers to proceed on
    # a stale lease, which is exactly what fencing forbids.
    class CheckpointWriter
      def initialize(store:, guard:)
        @store = store
        @guard = guard
        adapter = store.adapter
        @effects = EffectJournal.new(
          store:,
          guard:,
          attempt_ttl: adapter.limits.effect_attempt_ttl
        )
        @application_store = adapter.store
        freeze
      end

      def fence = @guard.lease.fence
      def check! = @guard.check!
      attr_reader :effects

      def store = @application_store

      # :reek:ManualDispatch :reek:FeatureEnvy -- the storage-identity check is
      # the journal's duck-typed accepts contract (any object exposing
      # storage_identity); the value IS the entire input by design.
      def accepts_effects?(value)
        value.respond_to?(:storage_identity) &&
          value.storage_identity.equal?(@store.adapter)
      end

      # :reek:ManualDispatch :reek:FeatureEnvy -- same duck-typed accepts
      # contract.
      def accepts_store?(value)
        value.respond_to?(:storage_identity) &&
          value.storage_identity.equal?(@store.adapter)
      end

      def latest
        lease = @guard.lease
        @store.latest(
          thread_id: lease.thread_id,
          namespace: Wire.decode_namespace(lease.namespace)
        )
      end

      def find(checkpoint_id:)
        lease = @guard.lease
        @store.find(
          thread_id: lease.thread_id,
          namespace: Wire.decode_namespace(lease.namespace),
          checkpoint_id:
        )
      end

      def append_writes(task:, outcome:)
        @store.append_writes(
          lease: @guard.lease,
          task:,
          outcome:
        )
      end

      # :reek:LongParameterList -- the checkpoint-commit contract is five
      # cohesive keyword args (mode/base/attributes/consumed/transition).
      def append_checkpoint(
        expected_base_id:,
        mode:,
        attributes:,
        consumed_task_ids: [],
        request_transition: nil
      )
        @store.append_checkpoint(
          lease: @guard.lease,
          expected_base_id:,
          mode:,
          attributes:,
          consumed_task_ids:,
          request_transition:
        )
      end

      def claim_next_request(validator: nil)
        @store.claim_next_request(lease: @guard.lease, validator:)
      end

      def recover_request(request_id:, validator: nil)
        @store.recover_request(
          lease: @guard.lease,
          request_id:,
          validator:
        )
      end

      # Public fenced terminal-fail for the post-claim execution backstop (DR-4 D2):
      # opens its own fenced transaction and fails a claimed/running request with the
      # canonical stale payload.
      def terminal_fail(request_id:, operation:, reason:)
        @store.terminal_fail(
          lease: @guard.lease,
          request_id:,
          operation:,
          reason:
        )
      end

      def mark_request_running(request_id:, execution_id:)
        @store.mark_request_running(
          lease: @guard.lease,
          request_id:,
          execution_id:
        )
      end

      def complete_request(request_id:, execution_id:)
        @store.mark_request_completed(
          lease: @guard.lease,
          request_id:,
          execution_id:
        )
      end

      # :reek:LongParameterList -- the five keyword args are the transition
      # action contract; collapsing them would hide what a transition is.
      def request_transition(
        request_id:,
        execution_id:,
        action:,
        graph_status:,
        retryable: nil
      )
        @store.request_transition(
          request_id:,
          execution_id:,
          action:,
          graph_status:,
          retryable:
        )
      end

      def redirect_ready?(target_execution_id:)
        @store.redirect_ready?(
          lease: @guard.lease,
          target_execution_id:
        )
      end
    end
  end
end
