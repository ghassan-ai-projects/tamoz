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
            next_version: 1, active_version: BEHAVIOR_VERSION,
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
    end
  end
end
