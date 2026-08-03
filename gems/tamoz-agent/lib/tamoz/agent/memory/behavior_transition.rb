# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11-W / DR-1 revision 4: the shared promotion machinery. A promoted
      # Wisdom (or, for P12-I, heuristic) record activates ONLY through a
      # `BehaviorTransition` consumed at the FIRST INTAKE OF A THREAD — the
      # serialized control record + claim → apply → finalize model. Existing
      # threads are pinned: resume/continue/redirect are `boundary: false` and
      # never rewrite the session record; a changed-version resume fails
      # closed.
      module BehaviorTransition
        TRANSITIONS_NAMESPACE = "tamoz.agent.transitions"
        SNAPSHOTS_NAMESPACE = "tamoz.agent.behavior.snapshots"
        EVIDENCE_NAMESPACE = "tamoz.agent.eval_evidence"
        CONTROL_NAMESPACE = "tamoz.agent.behavior"
        CONTROL_KEY = "control"
        ACTIVATION_SCOPE = :first_intake_of_thread
        MAX_BEHAVIOR_SNAPSHOT_BYTES = 4_096
        KINDS = %i[wisdom_promotion heuristic_promotion].freeze
        STATUSES = %i[recorded claimed activated rejected rolled_back].freeze
        # DR-1 §4 (C5): the delimited, findable injection markers. The
        # behavior-snapshot digest hashes exactly the canonical snapshot bytes,
        # so `verify_behavior_binding!` is a region comparison.
        SNAPSHOT_MARKERS = [
          "--- tamoz behavior snapshot begin ---",
          "--- tamoz behavior snapshot end ---"
        ].freeze

        # DR-1 §2 record shape. `transition_id = sha256(kind + candidate_digest)`
        # — identity does NOT include time, so a second attempt at the same
        # promotion is idempotent at the row level.
        Transition = Data.define(
          :transition_id, :kind, :candidate_id, :candidate_digest,
          :behavior_version_before, :behavior_version_after,
          :behavior_snapshot_digest, :rollback_target, :activation_scope,
          :promotion_evidence_digest, :human_gate_evidence,
          :claimant, :status, :consumed_by,
          :created_by, :recorded_at, :activated_at, :rolled_back_at
        ) do
          def initialize(
            transition_id:, kind:, candidate_id:, candidate_digest:,
            behavior_version_before:, behavior_version_after:,
            behavior_snapshot_digest:, rollback_target:,
            activation_scope: ACTIVATION_SCOPE,
            promotion_evidence_digest:, human_gate_evidence:,
            claimant: nil, status: :recorded, consumed_by: nil,
            created_by:, recorded_at:, activated_at: nil, rolled_back_at: nil
          )
            super(
              transition_id:, kind:, candidate_id:, candidate_digest:,
              behavior_version_before:, behavior_version_after:,
              behavior_snapshot_digest:, rollback_target:, activation_scope:,
              promotion_evidence_digest:, human_gate_evidence:,
              claimant:, status:, consumed_by:,
              created_by:, recorded_at:, activated_at:, rolled_back_at:
            )
          end

          def to_h
            {
              "transition_id" => transition_id,
              "kind" => kind.to_s,
              "candidate_id" => candidate_id,
              "candidate_digest" => candidate_digest,
              "behavior_version_before" => behavior_version_before,
              "behavior_version_after" => behavior_version_after,
              "behavior_snapshot_digest" => behavior_snapshot_digest,
              "rollback_target" => rollback_target,
              "activation_scope" => activation_scope.to_s,
              "promotion_evidence_digest" => promotion_evidence_digest,
              "human_gate_evidence" => human_gate_evidence,
              "claimant" => claimant,
              "status" => status.to_s,
              "consumed_by" => consumed_by,
              "created_by" => created_by,
              "recorded_at" => recorded_at,
              "activated_at" => activated_at,
              "rolled_back_at" => rolled_back_at
            }
          end

          def self.from_h(hash)
            new(
              transition_id: hash.fetch("transition_id"),
              kind: hash.fetch("kind").to_sym,
              candidate_id: hash.fetch("candidate_id"),
              candidate_digest: hash.fetch("candidate_digest"),
              behavior_version_before: hash.fetch("behavior_version_before"),
              behavior_version_after: hash.fetch("behavior_version_after"),
              behavior_snapshot_digest: hash.fetch("behavior_snapshot_digest"),
              rollback_target: hash.fetch("rollback_target"),
              activation_scope: hash.fetch("activation_scope").to_sym,
              promotion_evidence_digest: hash.fetch("promotion_evidence_digest"),
              human_gate_evidence: hash.fetch("human_gate_evidence"),
              claimant: hash["claimant"],
              status: hash.fetch("status").to_sym,
              consumed_by: hash["consumed_by"],
              created_by: hash.fetch("created_by"),
              recorded_at: hash.fetch("recorded_at"),
              activated_at: hash["activated_at"],
              rolled_back_at: hash["rolled_back_at"]
            )
          end
        end

        # The CAS-protected control record. Allocation (next_version), active
        # state, and the singleton pending transition are DISTINCT fields — one
        # pending id, allocator distinct from the active version, registry CAS
        # before any checkpoint write (DR-1 DC-1).
        ControlRecord = Data.define(
          :next_version, :active_version, :active_snapshot_digest,
          :active_transition_id, :pending_transition_id
        ) do
          def initialize(
            next_version: 1, active_version: SessionNodes::BEHAVIOR_VERSION,
            active_snapshot_digest: nil, active_transition_id: nil,
            pending_transition_id: nil
          )
            super
          end

          def to_h
            {
              "next_version" => next_version,
              "active_version" => active_version,
              "active_snapshot_digest" => active_snapshot_digest,
              "active_transition_id" => active_transition_id,
              "pending_transition_id" => pending_transition_id
            }
          end

          def self.from_h(hash)
            new(
              next_version: hash.fetch("next_version"),
              active_version: hash.fetch("active_version"),
              active_snapshot_digest: hash["active_snapshot_digest"],
              active_transition_id: hash["active_transition_id"],
              pending_transition_id: hash["pending_transition_id"]
            )
          end
        end

        module_function

        def transition_id(kind, candidate_digest)
          Digest::SHA256.hexdigest("#{kind}\0#{candidate_digest}")
        end

        def snapshot_digest(snapshot)
          "sha256:#{Digest::SHA256.hexdigest(JSON.generate(Tamoz::Core.canonical(snapshot)))}"
        end

        # DR-1 §4: the extended prompt-surface identity — the invariant-16
        # "canonical system content" axis finally digests the behavior
        # snapshot. Identical inputs to the toolbox's own digest, plus the
        # behavior-snapshot digest.
        def extended_prompt_surface_digest(toolbox:, behavior_snapshot_digest:)
          "sha256:#{Digest::SHA256.hexdigest(
            Tamoz::Tools::Toolbox::PROMPT_SURFACE_DOMAIN +
            JSON.generate([
              toolbox.catalog_digest,
              toolbox.skills.catalog_digest,
              behavior_snapshot_digest
            ])
          )}"
        end
      end

      # The singly-writer transition registry: one pending transition at a time,
      # CAS-allocated version, two-phase claim → apply → finalize.
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
        def record(
          kind:, candidate_id:, candidate_digest:, behavior_snapshot:,
          behavior_version_after:, promotion_evidence_digest:,
          human_gate_evidence:, created_by: "tamoz.agent.memory.wisdom"
        )
          unless BehaviorTransition::KINDS.include?(kind)
            raise MemoryPolicyError, "unknown transition kind #{kind.inspect}"
          end
          snapshot_canonical = Tamoz::Core.canonical(behavior_snapshot)
          snapshot_bytes = JSON.generate(snapshot_canonical)
          if snapshot_bytes.bytesize > BehaviorTransition::MAX_BEHAVIOR_SNAPSHOT_BYTES
            raise MemoryPolicyError, "behavior snapshot exceeds #{BehaviorTransition::MAX_BEHAVIOR_SNAPSHOT_BYTES} bytes"
          end
          if Surface.secret_shaped?(snapshot_bytes)
            raise MemoryPolicyError, "behavior snapshot carries secret-shaped content"
          end

          snapshot_digest = BehaviorTransition.snapshot_digest(behavior_snapshot)
          transition_id = BehaviorTransition.transition_id(kind, candidate_digest)
          control = read_control
          if control.pending_transition_id
            raise BehaviorTransitionClaimConflictError,
                  "a transition is already pending: #{control.pending_transition_id}"
          end
          before = control.active_version
          if behavior_version_after == before
            raise BehaviorTransitionClaimConflictError, "no-op activation rejected at record"
          end

          # Persist the bounded immutable snapshot under its digest.
          put_snapshot(snapshot_digest, behavior_snapshot)

          # CAS the control record: reserve next_version + 1, install exactly
          # one pending transition. The version allocator never moves backward.
          reserved = control.next_version
          reserved_after = control.with(
            next_version: control.next_version + 1,
            pending_transition_id: transition_id
          )
          begin
            cas_control(control, reserved_after)
          rescue Tamoz::StoreConflictError
            # Another pipeline recorded from the same baseline: the loser waits,
            # then re-evaluates against the eventual active version.
            raise BehaviorTransitionClaimConflictError,
                  "transition control record changed concurrently"
          end

          transition = BehaviorTransition::Transition.new(
            transition_id:,
            kind:,
            candidate_id:,
            candidate_digest:,
            behavior_version_before: before,
            behavior_version_after:,
            behavior_snapshot_digest: snapshot_digest,
            rollback_target: {"behavior_version" => before, "snapshot_digest" => control.active_snapshot_digest},
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
              existing = transition.claimant
              if existing && existing.fetch("owner") == owner && transition.consumed_by.nil?
                return transition.with(claimant: {"owner" => owner, "attempt" => attempt})
              end
            end
            raise BehaviorTransitionClaimConflictError,
                  "transition #{transition_id} is #{transition.status}, not claimable"
          end

          claimed = transition.with(
            status: :claimed,
            claimant: {"owner" => owner, "attempt" => attempt}
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
            "active_version" => control.active_version,
            "active_snapshot_digest" => control.active_snapshot_digest,
            "active_transition_id" => control.active_transition_id
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
          entry&.value&.fetch("snapshot")
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
              return finalize(transition_id:, consumed_by: "recovery")
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
        def put_snapshot(snapshot_digest, behavior_snapshot)
          existing = @store.get(BehaviorTransition::SNAPSHOTS_NAMESPACE, snapshot_digest)
          return if snapshot_matches?(existing, behavior_snapshot, snapshot_digest)

          @store.put(
            BehaviorTransition::SNAPSHOTS_NAMESPACE, snapshot_digest,
            {"snapshot" => behavior_snapshot, "digest" => snapshot_digest},
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

          stored = entry.value.is_a?(Hash) ? entry.value["snapshot"] : nil
          return true if Tamoz::Core.canonical(stored) == Tamoz::Core.canonical(behavior_snapshot)

          raise MemoryPolicyError,
                "behavior snapshot #{snapshot_digest} is already stored with different content"
        end

        def cas_control(expected, replacement)
          version = @store.head_version(BehaviorTransition::CONTROL_NAMESPACE, BehaviorTransition::CONTROL_KEY)
          @store.put(
            BehaviorTransition::CONTROL_NAMESPACE, BehaviorTransition::CONTROL_KEY,
            replacement.to_h,
            if_version: version || nil
          )
        end

        def read_control
          entry = @store.get(BehaviorTransition::CONTROL_NAMESPACE, BehaviorTransition::CONTROL_KEY)
          return BehaviorTransition::ControlRecord.new unless entry

          BehaviorTransition::ControlRecord.from_h(entry.value)
        end

        def fetch_transition_row(transition_id)
          # The row key is kind/candidate_digest; locate by scanning the
          # transition namespace for the id (bounded: one pending row).
          @store.each(BehaviorTransition::TRANSITIONS_NAMESPACE, limit: 64).find do |entry|
            entry.value.is_a?(Hash) && entry.value["transition_id"] == transition_id
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
                "transition claim raced; another consumer won"
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
