# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # The singly-writer transition registry: one pending transition at a time,
      # CAS-allocated version, two-phase claim → apply → finalize.
      # :reek:TooManyStatements — `record`, `claim`, `finalize` and
      # `release_or_finalize` are each ONE ordered transaction against the control
      # record: read, refuse, persist, CAS, write. The step list is the protocol,
      # and shortening any of them would drop a refusal or a durable write.
      # `put_snapshot` is the store-if-absent-else-verify pair.
      # :reek:TooManyMethods — the registry's public protocol (record, claim,
      # apply, finalize, release) plus one private step per store interaction.
      # :reek:RepeatedConditional — `entry` is the store's absent/present answer,
      # and every read has to decide what absence means for ITS caller; there is
      # no single answer to hoist.
      # :reek:NilCheck — a nil pending_transition_id means "nothing is claimed",
      # which is a different state from a claimed-and-released transition.
      # :reek:MissingSafeMethod — the validators raise; there is no useful
      # predicate form of "this transition may not be recorded".
      # :reek:FeatureEnvy :reek:DuplicateMethodCall — the registry reads store
      # entries, control records and transition rows and decides what each means;
      # interrogating them IS the work, and they are plain data, not collaborators.
      # :reek:LongParameterList — `record`'s eight keywords are the recorded
      # transition's own fields; callers depend on the signature.
      # :reek:ManualDispatch — `engine.respond_to?(:clock)` lets a test engine
      # supply a clock without every engine having to.
      class TransitionRegistry
        def initialize(engine)
          @store = engine.store
          @clock = engine.respond_to?(:clock) ? engine.clock : -> { Time.now }
        end

        def store_clock_ms
          @clock.call.to_i * 1000
        end

        # --- promotion side (provider/eval boundary) ---

        # Record a new transition. The bounded immutable snapshot is persisted
        # under its digest FIRST; then the control record is CASed only when
        # `pending_transition_id` is nil AND the candidate's `before` matches
        # the active version. The CAS reserves next_version + 1 and installs
        # exactly one pending transition. A second pipeline must re-evaluate
        # against the eventual active version (DR-1 §2).
        # Deliberately NOT split further (CODING_STANDARD §4). After the two
        # validators, what is left is one ordered transaction — read the control,
        # refuse a pending or no-op transition, persist the snapshot, CAS the
        # reservation, then write the row — and every step needs the same five
        # values (snapshot_digest, transition_id, control, before, reserved).
        # Splitting it threads those through loose parameters and makes it
        # possible to reach the CAS without the refusals, the same failure mode
        # documented on Profile::TransitionRegistry#consume_if_candidate! and
        # CLIAuthority#resolve_session_authority. The eight keyword arguments are
        # the recorded transition's fields; callers depend on the signature.
        # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/ParameterLists
        def record(
          kind:, candidate_id:, candidate_digest:, behavior_snapshot:,
          behavior_version_after:, promotion_evidence_digest:,
          human_gate_evidence:, created_by: 'tamoz.agent.memory.wisdom'
        )
          validate_kind!(kind)
          validate_snapshot!(behavior_snapshot)

          snapshot_digest = BehaviorTransition.snapshot_digest(behavior_snapshot)
          transition_id = BehaviorTransition.transition_id(kind, candidate_digest)
          control = read_control
          pending = control.pending_transition_id
          raise BehaviorTransitionClaimConflictError, "a transition is already pending: #{pending}" if pending

          before = control.active_version
          if behavior_version_after == before
            raise BehaviorTransitionClaimConflictError, 'no-op activation rejected at record'
          end

          # Persist the bounded immutable snapshot under its digest.
          put_snapshot(snapshot_digest, behavior_snapshot)

          # CAS the control record: reserve next_version + 1, install exactly
          # one pending transition. The version allocator never moves backward.
          reserved = control.next_version
          reserved_after = control.with(
            next_version: reserved + 1,
            pending_transition_id: transition_id
          )
          begin
            cas_control(control, reserved_after)
          rescue Tamoz::StoreConflictError
            # Another pipeline recorded from the same baseline: the loser waits,
            # then re-evaluates against the eventual active version.
            raise BehaviorTransitionClaimConflictError,
                  'transition control record changed concurrently'
          end

          transition = BehaviorTransition::Transition.new(
            transition_id:,
            kind:,
            candidate_id:,
            candidate_digest:,
            behavior_version_before: before,
            behavior_version_after:,
            behavior_snapshot_digest: snapshot_digest,
            rollback_target: { 'behavior_version' => before, 'snapshot_digest' => control.active_snapshot_digest },
            promotion_evidence_digest:,
            human_gate_evidence:,
            created_by:,
            recorded_at: store_clock_ms
          )
          @store.put(
            BehaviorTransition::TRANSITIONS_NAMESPACE,
            "#{kind}/#{candidate_digest}",
            transition.to_h,
            if_version: nil
          )
          [transition, reserved]
        end
        # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/ParameterLists

        # --- intake side (first intake of a thread) ---

        def pending_transition_id
          read_control.pending_transition_id
        end

        def pending_transition
          id = pending_transition_id
          return nil unless id

          transition(id)
        end

        def transition(transition_id)
          entry = fetch_transition_row(transition_id)
          return nil unless entry

          BehaviorTransition::Transition.from_h(entry.value)
        end

        # Claim (Store CAS, BEFORE any checkpoint write): the first intake reads
        # the exact pending_transition_id, then changes the row :recorded →
        # :claimed carrying claimant {owner, attempt}. Exactly one consumer
        # wins; no unordered registry scan chooses a transition.
        #
        # Same-owner take-over: a crash between claim and apply leaves :claimed
        # with a claimant identity and no committed session; a retry by the
        # same owner re-claims and proceeds. A different owner is refused until
        # release.
        def claim(transition_id:, owner:, attempt:)
          entry = fetch_transition_row(transition_id)
          raise BehaviorTransitionClaimConflictError, "no transition #{transition_id}" unless entry

          transition = BehaviorTransition::Transition.from_h(entry.value)
          unless transition.status == :recorded
            if transition.status == :claimed
              existing_claimant = transition.claimant
              if existing_claimant && existing_claimant.fetch('owner') == owner && transition.consumed_by.nil?
                return transition.with(claimant: { 'owner' => owner, 'attempt' => attempt })
              end
            end
            raise BehaviorTransitionClaimConflictError,
                  "transition #{transition_id} is #{transition.status}, not claimable"
          end

          claimed = transition.with(
            status: :claimed,
            claimant: { 'owner' => owner, 'attempt' => attempt }
          )
          cas_transition_row(entry, claimed)
          claimed
        end

        # Finalize (Store CAS): FIRST CAS the control record requiring the same
        # pending id AND `active_version == behavior_version_before` to install
        # the new active version/snapshot/transition id and clear pending; then
        # idempotently mark the row :claimed → :activated with `consumed_by`.
        # Future first intakes read the active version/snapshot from the
        # control record; they do not depend on the canary session.
        def finalize(transition_id:, consumed_by:)
          control = read_control
          unless control.pending_transition_id == transition_id
            raise BehaviorTransitionClaimConflictError,
                  "transition #{transition_id} is not the pending transition"
          end
          transition = transition(transition_id)
          unless transition && transition.status == :claimed
            raise BehaviorTransitionClaimConflictError,
                  "transition #{transition_id} is not claimed"
          end

          installed = control.with(
            active_version: transition.behavior_version_after,
            active_snapshot_digest: transition.behavior_snapshot_digest,
            active_transition_id: transition_id,
            pending_transition_id: nil
          )
          cas_control(control, installed)
          activate_row(transition_id, consumed_by:)
          installed
        end

        def active
          control = read_control
          {
            'active_version' => control.active_version,
            'active_snapshot_digest' => control.active_snapshot_digest,
            'active_transition_id' => control.active_transition_id
          }
        end

        def active_snapshot
          active_digest = read_control.active_snapshot_digest
          return nil unless active_digest

          snapshot_for(active_digest)
        end

        # The immutable snapshot stored under its digest (loads by digest).
        def snapshot_for(snapshot_digest)
          entry = @store.get(BehaviorTransition::SNAPSHOTS_NAMESPACE, snapshot_digest)
          entry&.value&.fetch('snapshot')
        end

        # Crash recovery (DR-1 C1/C2): between apply and finalize a committed
        # canary session + :claimed row + still-pending control record exist.
        # Release is permitted ONLY after proving neither a committed session
        # nor the control record's active fields reference the transition; if
        # either does, recovery FINALIZES the remaining record instead — never
        # release-then-re-apply.
        def release_or_finalize(transition_id:, session_references:)
          control = read_control
          if control.pending_transition_id == transition_id
            if session_references.call(transition_id) ||
               control.active_transition_id == transition_id
              return finalize(transition_id:, consumed_by: 'recovery')
            end

            cleared = control.with(pending_transition_id: nil)
            cas_control(control, cleared)
            return :released
          end
          :no_pending
        end

        private

        # P12-I fix. The snapshot namespace is CONTENT-ADDRESSED: the key IS
        # the digest of the value. Writing it with `if_version: nil` therefore
        # raised `Tamoz::StoreConflictError` ("Store key already exists")
        # whenever the same snapshot content was recorded twice — which is
        # exactly what DR-1 §7 rollback does, since a rollback re-records the
        # PRIOR snapshot's bytes to restore them byte-identically. It also broke
        # any two promotions that happened to carry identical snapshot content.
        #
        # For a content-addressed key, "already present with identical bytes" is
        # success, not a conflict. Differing bytes under the same digest would be
        # a SHA-256 collision or a corrupted row, and that propagates.
        def validate_kind!(kind)
          return if BehaviorTransition::KINDS.include?(kind)

          raise MemoryPolicyError, "unknown transition kind #{kind.inspect}"
        end

        # Two refusals over the same canonical bytes: a snapshot too large to
        # store, and one carrying secret-shaped content. Both fire before any
        # control state is read, so a rejected snapshot never reserves a version.
        def validate_snapshot!(behavior_snapshot)
          bytes = JSON.generate(Tamoz::Core.canonical(behavior_snapshot))
          if bytes.bytesize > BehaviorTransition::MAX_BEHAVIOR_SNAPSHOT_BYTES
            raise MemoryPolicyError,
                  "behavior snapshot exceeds #{BehaviorTransition::MAX_BEHAVIOR_SNAPSHOT_BYTES} bytes"
          end
          return unless Surface.secret_shaped?(bytes)

          raise MemoryPolicyError, 'behavior snapshot carries secret-shaped content'
        end

        def put_snapshot(snapshot_digest, behavior_snapshot)
          existing = @store.get(BehaviorTransition::SNAPSHOTS_NAMESPACE, snapshot_digest)
          return if snapshot_matches?(existing, behavior_snapshot, snapshot_digest)

          @store.put(
            BehaviorTransition::SNAPSHOTS_NAMESPACE, snapshot_digest,
            { 'snapshot' => behavior_snapshot, 'digest' => snapshot_digest },
            if_version: nil
          )
        rescue Tamoz::StoreConflictError
          # A concurrent recorder wrote the same content-addressed row between
          # the read and the write: re-read and accept only identical bytes.
          entry = @store.get(BehaviorTransition::SNAPSHOTS_NAMESPACE, snapshot_digest)
          return if snapshot_matches?(entry, behavior_snapshot, snapshot_digest)

          raise
        end

        def snapshot_matches?(entry, behavior_snapshot, snapshot_digest)
          return false unless entry

          stored = entry.value.is_a?(Hash) ? entry.value['snapshot'] : nil
          return true if Tamoz::Core.canonical(stored) == Tamoz::Core.canonical(behavior_snapshot)

          raise MemoryPolicyError,
                "behavior snapshot #{snapshot_digest} is already stored with different content"
        end

        # FINDING (not fixed here — see the state file's owner-decision queue):
        # `expected` is accepted and then ignored. The compare-and-swap is taken
        # against the version this method RE-READS, not against the control the
        # caller already read, so the window starts here rather than at the
        # caller's read. Byte-identical to HEAD; the extraction surfaced it out of
        # the parent file's baselined smells. Whether the single-writer discipline
        # makes that safe is a concurrency-correctness question about a durable
        # registry, which is an owner decision, not a refactoring one.
        # rubocop:disable Lint/UnusedMethodArgument
        # :reek:UnusedParameters
        def cas_control(expected, replacement)
          version = @store.head_version(BehaviorTransition::CONTROL_NAMESPACE, BehaviorTransition::CONTROL_KEY)
          @store.put(
            BehaviorTransition::CONTROL_NAMESPACE, BehaviorTransition::CONTROL_KEY,
            replacement.to_h,
            if_version: version || nil
          )
        end
        # rubocop:enable Lint/UnusedMethodArgument

        def read_control
          entry = @store.get(BehaviorTransition::CONTROL_NAMESPACE, BehaviorTransition::CONTROL_KEY)
          return BehaviorTransition::ControlRecord.new unless entry

          BehaviorTransition::ControlRecord.from_h(entry.value)
        end

        def fetch_transition_row(transition_id)
          # The row key is kind/candidate_digest; locate by scanning the
          # transition namespace for the id (bounded: one pending row).
          @store.each(BehaviorTransition::TRANSITIONS_NAMESPACE, limit: 64).find do |entry|
            entry.value.is_a?(Hash) && entry.value['transition_id'] == transition_id
          end
        end

        def cas_transition_row(entry, next_transition)
          @store.put(
            BehaviorTransition::TRANSITIONS_NAMESPACE, entry.key,
            next_transition.to_h,
            if_version: entry.version
          )
        rescue Tamoz::StoreConflictError
          raise BehaviorTransitionClaimConflictError,
                'transition claim raced; another consumer won'
        end

        def activate_row(transition_id, consumed_by:)
          entry = fetch_transition_row(transition_id)
          return unless entry

          transition = BehaviorTransition::Transition.from_h(entry.value)
          return if transition.status == :activated

          activated = transition.with(
            status: :activated,
            consumed_by:,
            activated_at: store_clock_ms
          )
          @store.put(
            BehaviorTransition::TRANSITIONS_NAMESPACE, entry.key,
            activated.to_h,
            if_version: entry.version
          )
        rescue Tamoz::StoreConflictError
          # Idempotent by transition_id: another finalize already activated.
          nil
        end
      end
    end
  end
end
