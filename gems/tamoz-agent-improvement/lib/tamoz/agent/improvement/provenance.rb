# frozen_string_literal: true

require "digest"
require "json"

module Tamoz
  module Agent
    module Improvement
      # P12-ID (plan §7): the candidate provenance record. Every field the plan
      # names is REQUIRED and structurally checked; there is no "mostly filled
      # in" provenance. A candidate whose provenance does not complete cannot be
      # evaluated and cannot be promoted, so an unprovenanced behavior change
      # has no path to activation at all.
      #
      # Plan §7 field list, mapped one-to-one:
      #
      #   source trajectories      -> `source_trajectories`
      #   train/holdout boundary   -> `corpus_boundary`
      #   affected behavior        -> `affected_behavior`
      #   policy / risk            -> `policy_risk`
      #   artifact digests         -> `artifact_digests`
      #   evaluation lineage       -> `evaluation_lineage`
      #   activation scope         -> `activation_scope`
      #   rollback target          -> `rollback_target`
      class Provenance < Data.define(
        :format_version, :candidate_id,
        :source_trajectories, :corpus_boundary, :affected_behavior,
        :policy_risk, :artifact_digests, :evaluation_lineage,
        :activation_scope, :rollback_target,
        :created_by, :recorded_at
      )
        FORMAT_VERSION = 1
        DIGEST_DOMAIN = "tamoz.agent.improvement.provenance.v1\n"

        # The eight plan-§7 provenance axes. The completeness test iterates this
        # list, so a field added here without a value is a failing test, not a
        # silently optional field.
        REQUIRED_AXES = %i[
          source_trajectories corpus_boundary affected_behavior policy_risk
          artifact_digests evaluation_lineage activation_scope rollback_target
        ].freeze

        # Per-axis structural requirements: the sub-keys that must be present
        # and non-empty. `nil`/empty at any depth is an incomplete provenance.
        AXIS_KEYS = {
          corpus_boundary: %w[train_digest holdout_digest train_ids holdout_ids disjoint],
          affected_behavior: %w[surface behavior_version_before behavior_version_after],
          policy_risk: %w[gate_classes risk_class reversible grants_authority],
          artifact_digests: %w[candidate_digest snapshot_digest generator_digest],
          evaluation_lineage: %w[
            report_digest evaluator_principal generator_principal
            development_score holdout_score paired_task_digest
          ],
          rollback_target: %w[behavior_version snapshot_digest]
        }.freeze

        SURFACES = %w[planning routing verification].freeze
        # v1 activation scope is DR-1 revision 4's: first intake of a thread.
        # Existing threads are pinned; resume/continue/redirect are
        # `boundary: false` and never adopt.
        ACTIVATION_SCOPE = "first_intake_of_thread"

        def initialize(
          format_version: FORMAT_VERSION,
          candidate_id:,
          source_trajectories: nil,
          corpus_boundary: nil,
          affected_behavior: nil,
          policy_risk: nil,
          artifact_digests: nil,
          evaluation_lineage: nil,
          activation_scope: ACTIVATION_SCOPE,
          rollback_target: nil,
          created_by:,
          recorded_at: 0
        )
          super
        end

        # P12-ID completeness. Raises `ProvenanceIncompleteError` naming the
        # first missing axis or sub-key — a provenance gap is never a boolean.
        def assert_complete!
          if String(candidate_id).empty?
            raise ProvenanceIncompleteError, "provenance is missing candidate_id"
          end

          assert_axes!
          assert_trajectories!
          assert_boundary!
          assert_scope!
          assert_lineage!
          self
        end

        def complete?
          assert_complete!
          true
        rescue ProvenanceIncompleteError
          false
        end

        def to_h
          {
            "format_version" => format_version,
            "candidate_id" => candidate_id,
            "source_trajectories" => source_trajectories,
            "corpus_boundary" => corpus_boundary,
            "affected_behavior" => affected_behavior,
            "policy_risk" => policy_risk,
            "artifact_digests" => artifact_digests,
            "evaluation_lineage" => evaluation_lineage,
            "activation_scope" => activation_scope,
            "rollback_target" => rollback_target,
            "created_by" => created_by,
            "recorded_at" => recorded_at
          }
        end

        # Identity over the provenance CONTENT (`recorded_at` excluded, as with
        # `BehaviorTransition.transition_id`: identity does not include time).
        def digest
          content = to_h.reject { |key, _| key == "recorded_at" }
          Tamoz::Core.digest(DIGEST_DOMAIN, content)
        end

        private

        def blank?(value)
          case value
          when nil then true
          when String then value.strip.empty?
          when Array, Hash then value.empty?
          when false then false # an explicit `false` is a recorded answer
          else false
          end
        end

        def assert_axes!
          REQUIRED_AXES.each do |axis|
            value = public_send(axis)
            if blank?(value)
              raise ProvenanceIncompleteError, "provenance is missing #{axis}"
            end

            AXIS_KEYS.fetch(axis, []).each do |key|
              entry = value[key]
              next unless blank?(entry)

              raise ProvenanceIncompleteError, "provenance #{axis} is missing #{key}"
            end
          end
        end

        # Every source trajectory carries an identity, a content digest, and the
        # partition it came from. A trajectory that is not `verified` is not a
        # source: plan §7 says "generated from VERIFIED trajectories", so an
        # unverified trajectory in the provenance is an incomplete record.
        def assert_trajectories!
          unless source_trajectories.is_a?(Array) && !source_trajectories.empty?
            raise ProvenanceIncompleteError, "provenance source_trajectories must be a non-empty list"
          end

          source_trajectories.each_with_index do |entry, index|
            unless entry.is_a?(Hash)
              raise ProvenanceIncompleteError, "provenance source_trajectories[#{index}] must be an object"
            end

            %w[trajectory_id digest partition].each do |key|
              next unless blank?(entry[key])

              raise ProvenanceIncompleteError,
                    "provenance source_trajectories[#{index}] is missing #{key}"
            end
            unless entry["verified"] == true
              raise ProvenanceIncompleteError,
                    "provenance source_trajectories[#{index}] is not a verified trajectory"
            end
            unless entry["partition"] == "train"
              raise ProvenanceIncompleteError,
                    "provenance source_trajectories[#{index}] is not from the train partition"
            end
          end
        end

        # The train/holdout boundary is a CLAIM the record must justify: the id
        # sets must be disjoint and the flag must agree with the sets. A record
        # that says `disjoint: true` over overlapping ids is incomplete, not
        # merely wrong.
        def assert_boundary!
          train = Array(corpus_boundary["train_ids"])
          holdout = Array(corpus_boundary["holdout_ids"])
          overlap = train & holdout
          unless overlap.empty?
            raise ProvenanceIncompleteError,
                  "provenance corpus_boundary train/holdout overlap: #{overlap.sort.inspect}"
          end
          unless corpus_boundary["disjoint"] == true
            raise ProvenanceIncompleteError,
                  "provenance corpus_boundary must record disjoint: true"
          end
          # Every source trajectory must actually be inside the declared train
          # partition — the boundary is checked against the sources, not
          # asserted beside them.
          strays = source_trajectories.map { |entry| entry["trajectory_id"] } - train
          return if strays.empty?

          raise ProvenanceIncompleteError,
                "provenance source_trajectories outside the train partition: #{strays.sort.inspect}"
        end

        def assert_scope!
          unless SURFACES.include?(String(affected_behavior["surface"]))
            raise ProvenanceIncompleteError,
                  "provenance affected_behavior surface must be one of #{SURFACES.join("/")}"
          end
          if affected_behavior["behavior_version_before"] == affected_behavior["behavior_version_after"]
            raise ProvenanceIncompleteError,
                  "provenance affected_behavior records a no-op behavior version change"
          end
          unless activation_scope == ACTIVATION_SCOPE
            raise ProvenanceIncompleteError,
                  "provenance activation_scope must be #{ACTIVATION_SCOPE} (DR-1 revision 4)"
          end
          # The rollback target must name the version the candidate departs
          # from; a rollback target that points at the candidate's own new
          # version is not a rollback.
          if rollback_target["behavior_version"] != affected_behavior["behavior_version_before"]
            raise ProvenanceIncompleteError,
                  "provenance rollback_target must restore behavior_version_before"
          end
        end

        # Evaluation lineage must show the evaluator and the generator are
        # DIFFERENT principals. A candidate that evaluated itself has no lineage
        # worth recording (invariant 34).
        def assert_lineage!
          evaluator = String(evaluation_lineage["evaluator_principal"])
          generator = String(evaluation_lineage["generator_principal"])
          return unless evaluator == generator

          raise ProvenanceIncompleteError,
                "provenance evaluation_lineage evaluator and generator are the same principal " \
                "(#{evaluator}); a candidate cannot evaluate itself"
        end
      end
    end
  end
end
