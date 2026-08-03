# frozen_string_literal: true

require_relative "test_helper"

# P12-ID / P12-I1 / P12-I2 (plan §7): the candidate provenance record, the ONE
# bounded heuristic generated from verified trajectories under a capability
# restriction that excludes the holdout and the evaluator output, and the paired
# baseline/holdout evaluation with its human gate and its two hard-zero gates
# (evaluator tampering, self-promotion).
#
# Every gate below is proven by ATTEMPTING the violation and asserting the
# refusal. Nothing here argues from inspection.
class ImprovementCandidateTest < Minitest::Test
  Improvement = Tamoz::Agent::Improvement
  Harness = Tamoz::Evals::Harness

  GENERATOR = "principal.generator.p12i"
  EVALUATOR = "principal.evaluator.p12i"
  PROMOTER = "principal.operator.p12i"

  def with_corpus
    Harness::HeuristicCorpus.create { |corpus| yield corpus }
  end

  def generator_for(corpus, principal: GENERATOR)
    Improvement::Generator.new(
      toolbox: Tamoz::Tools::Toolbox.new(root: corpus.train_root),
      principal:,
      protected_paths: [corpus.holdout_root, corpus.evaluator_root]
    )
  end

  def candidate_for(corpus)
    generator_for(corpus).generate(trajectory_paths: corpus.train_trajectory_paths)
  end

  def evaluation_for(corpus, candidate, regression: false)
    Harness::HeuristicPairedEvaluation.new(
      corpus:, evaluator_principal: EVALUATOR, generator_principal: GENERATOR
    ).evaluate(candidate, regression:)
  end

  # The provenance a real promotion carries, built from the real artifacts.
  def provenance_for(corpus, candidate, report, before: "tamoz.agent.session/1",
                     after: "tamoz.agent.session/2")
    body = Improvement::EvaluationReport.verify!(report)
    Improvement::Provenance.new(
      candidate_id: candidate.heuristic_id,
      source_trajectories: generator_for(corpus).source_refs(
        trajectory_paths: corpus.train_trajectory_paths
      ),
      corpus_boundary: {
        "train_digest" => corpus.train_digest,
        "holdout_digest" => corpus.holdout_digest,
        "train_ids" => corpus.train_ids,
        "holdout_ids" => corpus.holdout_ids,
        "disjoint" => true
      },
      affected_behavior: {
        "surface" => "planning",
        "behavior_version_before" => before,
        "behavior_version_after" => after
      },
      policy_risk: {
        "gate_classes" => Improvement::EvaluationReport::HEURISTIC_GATE_CLASSES,
        "risk_class" => "reversible_local_prompt_region",
        "reversible" => true,
        "grants_authority" => false
      },
      artifact_digests: {
        "candidate_digest" => candidate.digest,
        "snapshot_digest" => Tamoz::Agent::Memory::BehaviorTransition.snapshot_digest(
          candidate.snapshot
        ),
        "generator_digest" => generator_for(corpus).digest
      },
      evaluation_lineage: {
        "report_digest" => Improvement::EvaluationReport.seal(body),
        "evaluator_principal" => EVALUATOR,
        "generator_principal" => GENERATOR,
        "development_score" => body.fetch("development").fetch("candidate").fetch("passed"),
        "holdout_score" => body.fetch("holdout").fetch("candidate").fetch("passed"),
        "paired_task_digest" => body.fetch("paired_task_digest")
      },
      rollback_target: {"behavior_version" => before, "snapshot_digest" => "sha256:prior"},
      created_by: PROMOTER,
      recorded_at: 1_700_000_000
    )
  end

  # --- P12-ID: provenance completeness -------------------------------------

  def test_provenance_completeness_is_checked_axis_by_axis
    with_corpus do |corpus|
      candidate = candidate_for(corpus)
      report = evaluation_for(corpus, candidate)
      complete = provenance_for(corpus, candidate, report)
      assert complete.complete?
      assert_equal complete, complete.assert_complete!
      assert complete.digest.start_with?("sha256:")

      # Drive the loop from the record's own axis list: a NEW plan-§7 axis added
      # to `REQUIRED_AXES` without a value fails this test rather than being
      # quietly optional.
      Improvement::Provenance::REQUIRED_AXES.each do |axis|
        blanked = complete.with(axis => nil)
        error = assert_raises(Improvement::ProvenanceIncompleteError, axis.to_s) do
          blanked.assert_complete!
        end
        assert_includes error.message, axis.to_s
        refute blanked.complete?
      end

      # And every declared sub-key of every structured axis.
      Improvement::Provenance::AXIS_KEYS.each do |axis, keys|
        keys.each do |key|
          value = complete.public_send(axis)
          # `disjoint`/`reversible`/`grants_authority` are booleans: a MISSING
          # answer is incomplete, but a recorded `false` is an answer.
          gapped = complete.with(axis => value.merge(key => nil))
          error = assert_raises(Improvement::ProvenanceIncompleteError, "#{axis}.#{key}") do
            gapped.assert_complete!
          end
          assert_includes error.message, key
        end
      end
      assert_equal 0, String(complete.candidate_id).length.zero? ? 1 : 0
    end
  end

  def test_provenance_rejects_a_boundary_that_is_not_a_boundary
    with_corpus do |corpus|
      candidate = candidate_for(corpus)
      report = evaluation_for(corpus, candidate)
      complete = provenance_for(corpus, candidate, report)

      # Overlapping train/holdout ids: the record's own claim contradicts it.
      overlapped = complete.with(
        corpus_boundary: complete.corpus_boundary.merge(
          "holdout_ids" => complete.corpus_boundary.fetch("train_ids").first(1)
        )
      )
      error = assert_raises(Improvement::ProvenanceIncompleteError) { overlapped.assert_complete! }
      assert_includes error.message, "overlap"

      # `disjoint: false` is a truthful record of a partition that is not a
      # holdout — and it is refused rather than accepted with a caveat.
      lying = complete.with(corpus_boundary: complete.corpus_boundary.merge("disjoint" => false))
      assert_raises(Improvement::ProvenanceIncompleteError) { lying.assert_complete! }

      # A source trajectory outside the declared train partition.
      stray = complete.with(
        corpus_boundary: complete.corpus_boundary.merge("train_ids" => ["t.001"])
      )
      error = assert_raises(Improvement::ProvenanceIncompleteError) { stray.assert_complete! }
      assert_includes error.message, "outside the train partition"
    end
  end

  def test_provenance_rejects_unverified_sources_self_evaluation_and_no_op_versions
    with_corpus do |corpus|
      candidate = candidate_for(corpus)
      report = evaluation_for(corpus, candidate)
      complete = provenance_for(corpus, candidate, report)

      unverified = complete.with(
        source_trajectories: complete.source_trajectories.map { |e| e.merge("verified" => false) }
      )
      error = assert_raises(Improvement::ProvenanceIncompleteError) { unverified.assert_complete! }
      assert_includes error.message, "not a verified trajectory"

      held_out_source = complete.with(
        source_trajectories: complete.source_trajectories.map { |e| e.merge("partition" => "holdout") }
      )
      assert_raises(Improvement::ProvenanceIncompleteError) { held_out_source.assert_complete! }

      selfish = complete.with(
        evaluation_lineage: complete.evaluation_lineage.merge("evaluator_principal" => GENERATOR)
      )
      error = assert_raises(Improvement::ProvenanceIncompleteError) { selfish.assert_complete! }
      assert_includes error.message, "cannot evaluate itself"

      no_op = complete.with(
        affected_behavior: complete.affected_behavior.merge(
          "behavior_version_after" => complete.affected_behavior.fetch("behavior_version_before")
        )
      )
      error = assert_raises(Improvement::ProvenanceIncompleteError) { no_op.assert_complete! }
      assert_includes error.message, "no-op"

      # DR-1 revision 4: the only v1 activation scope is first-intake-of-thread.
      scoped = complete.with(activation_scope: "mid_thread")
      error = assert_raises(Improvement::ProvenanceIncompleteError) { scoped.assert_complete! }
      assert_includes error.message, "first_intake_of_thread"

      # A "rollback target" that points at the candidate's own new version.
      forward = complete.with(
        rollback_target: complete.rollback_target.merge(
          "behavior_version" => complete.affected_behavior.fetch("behavior_version_after")
        )
      )
      error = assert_raises(Improvement::ProvenanceIncompleteError) { forward.assert_complete! }
      assert_includes error.message, "rollback_target"
    end
  end

  # --- P12-I1: one bounded candidate, holdout isolation ---------------------

  def test_exactly_one_bounded_candidate_from_verified_trajectories
    with_corpus do |corpus|
      generator = generator_for(corpus)
      candidate = generator.generate(trajectory_paths: corpus.train_trajectory_paths)

      assert_equal :planning, candidate.surface
      assert_equal "read_file", candidate.precursor_tool
      assert_equal "apply_patch", candidate.subject_tool
      # 4 verified trajectories support it; the 5th (`t.unverified`) contributes
      # NOTHING — an unverified trajectory is not evidence.
      assert_equal 4, candidate.support
      assert_equal 4, candidate.trials
      assert_equal 1.0, candidate.confidence
      assert candidate.digest.start_with?("sha256:")

      # Plan §7: "at most one". The second attempt is refused, not merged.
      error = assert_raises(Improvement::ImprovementPolicyError) do
        generator.generate(trajectory_paths: corpus.train_trajectory_paths)
      end
      assert_includes error.message, "at most"

      # Determinism: a fresh generator over the same corpus yields the same
      # candidate digest, so the promotion row is idempotent by identity.
      assert_equal candidate.digest, candidate_for(corpus).digest
    end
  end

  def test_generator_cannot_read_the_holdout_or_the_evaluator_output
    with_corpus do |corpus|
      assert corpus.secure?, "the protected partition must be mode 0o700"
      assert corpus.outside_grant?, "the protected partition must lie outside the grant"

      generator = generator_for(corpus)
      toolbox = generator.toolbox

      # (1) ABSOLUTE path into the protected partition — refused at the
      #     capability boundary, not by a convention this code checks on itself.
      holdout_file = File.join(corpus.holdout_root, "h.blind-patch.json")
      assert File.file?(holdout_file), "the holdout record must really exist"
      error = assert_raises(Tamoz::Tools::ToolPolicyError) do
        toolbox.execute("read_file", {"path" => holdout_file})
      end
      assert_includes error.message, "relative to the workspace root"

      # (2) RELATIVE traversal to the same real bytes — refused by root
      #     confinement, and the file it is aiming at is genuinely readable by
      #     the evaluator, so the refusal is the grant and not a missing file.
      escape = File.join("..", "protected", "holdout", "h.blind-patch.json")
      error = assert_raises(Tamoz::Tools::ToolPolicyError) do
        toolbox.execute("read_file", {"path" => escape})
      end
      assert_includes error.message, "escapes the workspace root"
      assert File.read(holdout_file, encoding: Encoding::UTF_8).include?("h.blind-patch")

      # (3) The evaluator's OUTPUT is equally out of reach — the candidate can
      #     never read its own score.
      corpus.write_evaluator_output("probe.json", {"secret" => "score"})
      assert_raises(Tamoz::Tools::ToolPolicyError) do
        toolbox.execute(
          "read_file", {"path" => File.join("..", "protected", "evaluator", "probe.json")}
        )
      end

      # (4) Nor can it LIST the protected partition to learn it exists.
      assert_raises(Tamoz::Tools::ToolPolicyError) do
        toolbox.execute("list_directory", {"path" => File.join("..", "protected")})
      end

      # (5) Not one byte of holdout content reaches the candidate or its
      #     provenance sources.
      candidate = generator.generate(trajectory_paths: corpus.train_trajectory_paths)
      rendered = JSON.generate(candidate.to_h)
      corpus.holdout_ids.each { |id| refute_includes rendered, id }
    end
  end

  def test_an_over_broad_generator_grant_is_refused_before_it_reads_anything
    with_corpus do |corpus|
      # A grant rooted at the corpus PARENT would contain the holdout: the
      # generator refuses to exist rather than relying on good behavior.
      parent = File.dirname(File.realpath(corpus.train_root))
      error = assert_raises(Improvement::HoldoutIsolationError) do
        Improvement::Generator.new(
          toolbox: Tamoz::Tools::Toolbox.new(root: parent),
          principal: GENERATOR,
          protected_paths: [corpus.holdout_root, corpus.evaluator_root]
        )
      end
      assert_includes error.message, "protected partition"

      # A generator holding a MUTATION capability is refused outright: plan §7
      # "never activate live prompt/code changes during the generating task".
      error = assert_raises(Improvement::HoldoutIsolationError) do
        Improvement::Generator.new(
          toolbox: Tamoz::Tools::Toolbox.new(root: corpus.train_root, allow_changes: true),
          principal: GENERATOR,
          protected_paths: [corpus.holdout_root]
        )
      end
      assert_includes error.message, "mutation capability"
    end
  end

  def test_the_heuristic_is_insert_only_and_may_never_insert_a_mutation
    with_corpus do |corpus|
      candidate = candidate_for(corpus)
      steps = [
        {"id" => "s1", "tool" => "apply_patch", "arguments" => {"path" => "lib/x.rb"}},
        {"id" => "s2", "tool" => "read_file", "arguments" => {"path" => "lib/y.rb"}}
      ]
      applied = candidate.apply(steps)

      # Insert-only: every original step survives, in order, unmodified.
      assert_equal steps, applied.reject { |step| step["origin"] }
      assert_equal 3, applied.length
      assert_equal "read_file", applied.first.fetch("tool")
      assert_equal "lib/x.rb", applied.first.fetch("arguments").fetch("path")

      # Idempotent-ish: a plan that already reads the target gains nothing.
      safe = [
        {"id" => "s1", "tool" => "read_file", "arguments" => {"path" => "lib/x.rb"}},
        {"id" => "s2", "tool" => "apply_patch", "arguments" => {"path" => "lib/x.rb"}}
      ]
      assert_equal safe, candidate.apply(safe)

      # A heuristic whose precursor is a MUTATION is refused: injecting an
      # `apply_patch` into a plan is a capability change, not a heuristic.
      error = assert_raises(Improvement::ImprovementPolicyError) do
        candidate.with(precursor_tool: "apply_patch").assert_bounded!
      end
      assert_includes error.message, "read-only"
      assert_raises(Improvement::ImprovementPolicyError) do
        candidate.with(precursor_tool: "run_check").assert_bounded!
      end
      assert_raises(Improvement::ImprovementPolicyError) do
        candidate.with(surface: :capability).assert_bounded!
      end
      assert_raises(Improvement::ImprovementPolicyError) do
        candidate.with(support: 9, trials: 4).assert_bounded!
      end
    end
  end

  # --- P12-I2: paired evaluation, human gates, hard-zero gates --------------

  def test_paired_evaluation_scores_both_arms_on_the_identical_task_set
    with_corpus do |corpus|
      candidate = candidate_for(corpus)
      report = evaluation_for(corpus, candidate)
      body = Improvement::EvaluationReport.verify!(report)

      %w[development holdout].each do |partition|
        arms = body.fetch(partition)
        assert_equal arms.fetch("baseline").fetch("task_digest"),
                     arms.fetch("candidate").fetch("task_digest"),
                     "#{partition} arms must sit the identical exam"
        assert_equal arms.fetch("baseline").fetch("total"), arms.fetch("candidate").fetch("total")
      end
      refute_equal body.fetch("development").fetch("baseline").fetch("task_digest"),
                   body.fetch("holdout").fetch("baseline").fetch("task_digest"),
                   "the holdout must not be the development set"

      decision = Improvement::EvaluationReport.decide(body)
      assert_equal 2, decision.fetch("development_margin")
      assert_equal 1, decision.fetch("holdout_margin")
      assert decision.fetch("passed")

      # The report never carries holdout task CONTENT back to the candidate —
      # only aggregate outcomes keyed by held-out task id. The held-* paths
      # exist only in the protected partition, so their absence is a content
      # check, not a keyword check.
      body_text = JSON.generate(body)
      refute_includes body_text, "held-one"
      refute_includes body_text, "held-two"
      refute_includes body_text, "held-three"
    end
  end

  def test_evaluator_tampering_is_refused
    with_corpus do |corpus|
      candidate = candidate_for(corpus)
      report = evaluation_for(corpus, candidate)

      # (1) Flip ONE held-out outcome to look better: the seal breaks.
      tampered = deep_dup(report)
      tampered["holdout"]["candidate"]["passed"] += 1
      error = assert_raises(Improvement::EvaluatorTamperError) do
        Improvement::EvaluationReport.verify!(tampered)
      end
      assert_includes error.message, "seal does not match"

      # (2) Flip a single per-task outcome, leaving the totals alone: still
      #     caught, because the seal covers the whole body.
      subtle = deep_dup(report)
      key = subtle["holdout"]["baseline"]["outcomes"].keys.first
      subtle["holdout"]["baseline"]["outcomes"][key] = !subtle["holdout"]["baseline"]["outcomes"][key]
      assert_raises(Improvement::EvaluatorTamperError) do
        Improvement::EvaluationReport.verify!(subtle)
      end

      # (3) Strip the seal entirely.
      assert_raises(Improvement::EvaluatorTamperError) do
        Improvement::EvaluationReport.verify!(deep_dup(report).tap { |r| r.delete("seal") })
      end

      # (4) RE-SEAL the tampered body. The seal is a digest, not a keyed MAC, so
      #     this one passes the seal — and is caught by the structural gates
      #     instead. Arms that no longer sat the identical exam are refused.
      forged_body = deep_dup(report).tap { |r| r.delete("seal") }
      forged_body["holdout"]["candidate"]["task_digest"] = "sha256:easier-exam"
      error = assert_raises(Improvement::EvaluatorTamperError) do
        Improvement::EvaluationReport.verify!(Improvement::EvaluationReport.sealed(forged_body))
      end
      assert_includes error.message, "identical task set"

      # (5) A "holdout" that is really the development set.
      shared = deep_dup(report).tap { |r| r.delete("seal") }
      shared["holdout"] = deep_dup(shared["development"])
      error = assert_raises(Improvement::EvaluatorTamperError) do
        Improvement::EvaluationReport.verify!(Improvement::EvaluationReport.sealed(shared))
      end
      assert_includes error.message, "not held out"

      # (6) Passing more tasks than were run.
      impossible = deep_dup(report).tap { |r| r.delete("seal") }
      impossible["development"]["candidate"]["passed"] = 99
      error = assert_raises(Improvement::EvaluatorTamperError) do
        Improvement::EvaluationReport.verify!(Improvement::EvaluationReport.sealed(impossible))
      end
      assert_includes error.message, "passed more tasks than it ran"
    end
  end

  def test_a_candidate_cannot_evaluate_or_promote_itself
    with_corpus do |corpus|
      candidate = candidate_for(corpus)
      report = evaluation_for(corpus, candidate)

      # The harness itself refuses to run an evaluation where the evaluator IS
      # the generator.
      error = assert_raises(Tamoz::Evals::ExecutionError) do
        Harness::HeuristicPairedEvaluation.new(
          corpus:, evaluator_principal: GENERATOR, generator_principal: GENERATOR
        )
      end
      assert_includes error.message, "must differ"

      # And so does the production gate, against a correctly re-sealed report
      # that names the generator as its own evaluator.
      selfish = deep_dup(report).tap { |r| r.delete("seal") }
      selfish["evaluator_principal"] = GENERATOR
      error = assert_raises(Improvement::SelfPromotionError) do
        Improvement::EvaluationReport.verify!(Improvement::EvaluationReport.sealed(selfish))
      end
      assert_includes error.message, "cannot evaluate itself"
    end
  end

  def test_every_human_gate_class_is_enforced
    gate = Improvement::EvaluationReport
    assert_equal 8, gate::HUMAN_GATE_CLASSES.length

    gate::HUMAN_GATE_CLASSES.each do |klass|
      # No evidence at all.
      error = assert_raises(Improvement::UngatedActivationError, klass) do
        gate.assert_human_gate!(gate_classes: [klass], evidence: nil)
      end
      assert_includes error.message, klass
      # Evidence that is not a resolved human approval artifact.
      assert_raises(Improvement::UngatedActivationError, klass) do
        gate.assert_human_gate!(gate_classes: [klass], evidence: "auto-approved")
      end
      # The prefix alone, with no actor, is not an approval either.
      assert_raises(Improvement::UngatedActivationError, klass) do
        gate.assert_human_gate!(gate_classes: [klass], evidence: "human:")
      end
      assert gate.assert_human_gate!(gate_classes: [klass], evidence: "human:operator-1")
    end

    # A misspelled class must not silently drop its gate.
    error = assert_raises(Improvement::ImprovementPolicyError) do
      gate.assert_human_gate!(gate_classes: %w[prompt_heirarchy], evidence: "human:operator-1")
    end
    assert_includes error.message, "unknown human-gate classes"

    # The heuristic always touches the prompt hierarchy, so its gate is never
    # vacuous.
    assert_equal %w[prompt_hierarchy], gate::HEURISTIC_GATE_CLASSES
    assert_raises(Improvement::UngatedActivationError) do
      gate.assert_human_gate!(gate_classes: gate::HEURISTIC_GATE_CLASSES, evidence: "")
    end
  end

  # --- P12-I3: the promotion surface is REVERSIBLE ------------------------
  #
  # The plan's DoD names "one reversible behavior candidate": promote → epoch
  # bump → regression monitor → rollback, and then a FOLLOW-UP ROUND may promote
  # the next candidate after the first has telemetry. The gate counting rows in
  # `recorded|claimed|activated` forever made the contract irreversible (a
  # rolled-back candidate stayed "live"); these tests pin the corrected
  # semantics on a real SQLite-backed engine.

  def with_engine
    Dir.mktmpdir("tamoz-improvement") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, "engine.sqlite3"))
      begin
        engine = Tamoz::Agent::Memory::Engine.new(tenant: "p12i", adapter:)
        yield engine, adapter
      ensure
        adapter&.close
      end
    end
  end

  def promotion_for(corpus, engine, candidate: nil, report: nil, actor: PROMOTER,
                    before: "tamoz.agent.session/1", after: "tamoz.agent.session/2")
    candidate ||= candidate_for(corpus)
    report ||= evaluation_for(corpus, candidate)
    body = Improvement::EvaluationReport.verify!(report)
    provenance = provenance_for(corpus, candidate, report, before:, after:)
    # The evidence resolver stands in for the evaluator's protected output
    # partition: given the seal of the verified body, it returns the stored
    # sealed artifact the evaluator wrote.
    evidence_resolver = lambda do |seal|
      return nil unless seal == Improvement::EvaluationReport.seal(body)

      report
    end
    promotion = Improvement::Promotion.new(engine)
    result = promotion.promote(
      candidate:, provenance:, report:,
      human_gate_evidence: "human:operator-1", actor:,
      evidence_resolver:
    )
    [promotion, result]
  end

  def activate_pending(engine, transition_id)
    claimed = engine.transitions.claim(
      transition_id:, owner: "intake", attempt: 1
    )
    assert_equal :claimed, claimed.status
    engine.transitions.finalize(
      transition_id:, consumed_by: "session.canary"
    )
  end

  # Production baseline: before any heuristic, P11's wisdom pipeline recorded
  # and activated the default behavior snapshot at session/2. A heuristic
  # promoted after it has a REAL prior snapshot to roll back to — which is the
  # production shape the "reversible candidate" DoD depends on.
  def seed_baseline(engine)
    transition, reserved = engine.transitions.record(
      kind: :wisdom_promotion,
      candidate_id: "wis.default",
      candidate_digest: "sha256:#{"9" * 64}",
      behavior_snapshot: {"wisdom" => "default baseline"},
      behavior_version_after: "tamoz.agent.session/2",
      promotion_evidence_digest: "sha256:#{"7" * 64}",
      human_gate_evidence: "human:operator-1",
      created_by: "tamoz.agent.memory.wisdom"
    )
    assert_equal 1, reserved
    activate_pending(engine, transition.transition_id)
    assert_equal "tamoz.agent.session/2", engine.transitions.active.fetch("active_version")
    transition.transition_id
  end

  def test_a_rolled_back_heuristic_is_no_longer_live_and_a_follow_up_can_promote
    with_corpus do |corpus|
      with_engine do |engine, _adapter|
        seed_baseline(engine)

        # First promotion: read_file-before-apply_patch candidate.
        first_candidate = candidate_for(corpus)
        promotion, result = promotion_for(
          corpus, engine, candidate: first_candidate,
          before: "tamoz.agent.session/2", after: "tamoz.agent.session/3"
        )
        first_id = result.fetch("transition").transition_id
        activate_pending(engine, first_id)
        assert_equal "tamoz.agent.session/3", engine.transitions.active.fetch("active_version")

        # Roll it back to the prior snapshot (DR-1 §7: a fresh serialized
        # transition restoring the prior bytes).
        rollback = promotion.rollback(
          reason: "telemetry regression", actor: PROMOTER,
          human_gate_evidence: "human:operator-1"
        )
        rollback_id = rollback.fetch("transition").transition_id
        activate_pending(engine, rollback_id)
        restored = engine.transitions.active
        assert_equal "tamoz.agent.session/4", restored.fetch("active_version")

        # A follow-up round may promote the NEXT candidate: the rolled-back
        # first candidate is no longer live.
        second_candidate = first_candidate.with(
          heuristic_id: "heuristic.read_file-before-create_file"
        )
        second_report = evaluation_for(corpus, second_candidate)
        second_body = Improvement::EvaluationReport.verify!(second_report)
        follow_up = promotion.promote(
          candidate: second_candidate,
          provenance: provenance_for(
            corpus, second_candidate, second_report,
            before: restored.fetch("active_version"), after: "tamoz.agent.session/5"
          ),
          report: second_report,
          human_gate_evidence: "human:operator-1", actor: PROMOTER,
          evidence_resolver: lambda do |seal|
            seal == Improvement::EvaluationReport.seal(second_body) ? second_report : nil
          end
        )
        assert_equal 4, follow_up.fetch("reserved_version")
        refute follow_up.fetch("activated")
        # The transition's AFTER version is what the intake applies.
        assert_equal(
          "tamoz.agent.session/5",
          follow_up.fetch("transition").behavior_version_after
        )
      end
    end
  end

  def test_rollback_restores_byte_identical_injection_region
    with_corpus do |corpus|
      with_engine do |engine, _adapter|
        seed_baseline(engine)
        candidate = candidate_for(corpus)
        promotion, result = promotion_for(
          corpus, engine, candidate:,
          before: "tamoz.agent.session/2", after: "tamoz.agent.session/3"
        )
        first_id = result.fetch("transition").transition_id
        activate_pending(engine, first_id)

        rollback = promotion.rollback(
          reason: "telemetry regression", actor: PROMOTER,
          human_gate_evidence: "human:operator-1"
        )
        target = rollback.fetch("target_snapshot_digest")
        expected_injection = rollback.fetch("injection_digest")
        activate_pending(engine, rollback.fetch("transition").transition_id)

        proof = promotion.assert_rolled_back_byte_identical!(
          expected_snapshot_digest: target,
          expected_injection_digest: expected_injection
        )
        assert proof.fetch("byte_identical")
        assert_equal "tamoz.agent.session/4", proof.fetch("active_version")
      end
    end
  end

  # The monitor compares the SAME paired task set, and refuses a report over a
  # different set as a tampering attempt rather than downgrading it to a metric.
  def test_monitor_refuses_observation_over_a_different_paired_task_set
    with_corpus do |corpus|
      candidate = candidate_for(corpus)
      promotion_report = evaluation_for(corpus, candidate)
      monitor = Improvement::Monitor.new(promotion_report:)

      # A "regressed" report over the SAME task set is an observation: the
      # holdout candidate passes fewer tasks (margins drop) but the exam set is
      # unchanged, so the monitor reports a regression instead of refusing.
      same_set = deep_dup(promotion_report).tap { |r| r.delete("seal") }
      same_set["holdout"]["candidate"]["passed"] =
        same_set.dig("holdout", "candidate", "passed").to_i - 1
      observation = monitor.observe(
        Improvement::EvaluationReport.sealed(same_set)
      )
      assert observation.regression?
      refute observation.healthy?

      # A report over a DIFFERENT paired task set is not an observation. The
      # monitor must refuse it as a tampering attempt, not downgrade it to a
      # margin metric. The report is rebuilt and RE-SEALED over the different
      # exam set (the evaluator's honest output for a different corpus), so it
      # passes verify! and reaches the monitor's own same-task-set check.
      different_set = deep_dup(promotion_report).tap { |r| r.delete("seal") }
      dev_digest = "sha256:#{"d" * 64}"
      hold_digest = "sha256:#{"e" * 64}"
      different_set["development"].each_value do |arm|
        arm["task_digest"] = dev_digest
      end
      different_set["holdout"].each_value do |arm|
        arm["task_digest"] = hold_digest
      end
      different_set["paired_task_digest"] =
        Improvement::EvaluationReport.paired_task_digest(dev_digest, hold_digest)
      error = assert_raises(Improvement::EvaluatorTamperError) do
        monitor.observe(Improvement::EvaluationReport.sealed(different_set))
      end
      assert_includes error.message, "different paired task set"
    end
  end

  private

  def deep_dup(value)
    JSON.parse(JSON.generate(value))
  end
end
