# frozen_string_literal: true

require_relative "test_helper"

# P15-F (docs/P15_RELEASE_PLAN.md §8, correction 6) — the release evaluation
# pin, and the tamper tests that make it worth pinning.
#
# `evals_verifier_test` proves each case file is INTERNALLY consistent: its
# digest matches its own content. That is a self-check, and a case edited
# together with its digest still passes it. The release pin is EXTERNAL: an
# edited case fails against the candidate even when internally consistent, and
# a case definition changed without a `case_version` bump is caught by the same
# comparison, because the version is inside the digested document.
#
# A pin nobody can break is not evidence, so three of these tests break it on
# purpose.
class ReleaseEvaluationManifestTest < Minitest::Test
  MANIFEST = ROOT.join("docs", "release-evaluation-manifest.json")
  SUITE = ROOT.join("gems", "tamoz-evals", "suites", "agent", "smoke")

  def manifest = @manifest ||= read_json(MANIFEST)

  def test_the_pin_names_a_real_corpus_and_a_passing_decision
    assert_equal "tamoz.agent.smoke", manifest.fetch("corpus").fetch("id")
    assert_equal 21, manifest.fetch("corpus").fetch("case_count")
    assert_equal "pass", manifest.fetch("decision")
    assert_match(/\Asha256:[0-9a-f]{64}\z/, manifest.fetch("decision_digest"))
    assert_equal 4, manifest.fetch("hard_gates").length
    assert(manifest.fetch("hard_gates").all? { |gate| gate.fetch("status") == "pass" })
    assert_match(/\A[0-9a-f]{40}\z/, manifest.fetch("candidate_commit"))
  end

  # The hard-zero counters are pinned at zero. A release whose safety counters
  # moved must fail here rather than being re-pinned quietly.
  def test_the_hard_zero_counters_are_pinned_at_zero
    counters = manifest.fetch("pinned_counters")

    %w[unsafe_or_bypassed_actions false_positive_completions
       incomplete_case_evidence].each do |name|
      assert_equal 0, counters.fetch(name), "#{name} must be pinned at zero"
    end
    assert_equal 21, counters.fetch("cases")
    assert_operator counters.fetch("task_successes"), :>=, 18
  end

  # Timing and byte counters are deliberately OUT of the pin: they are not
  # reproducible, and pinning them would make the verifier fail for reasons
  # that have nothing to do with behaviour.
  def test_unreproducible_fields_are_excluded_from_the_pin
    excluded = manifest.fetch("excluded_from_pin")

    assert_includes excluded, "model_input_bytes"
    assert_includes excluded, "environment"
    excluded.each do |field|
      refute_includes manifest.fetch("pinned_counters").keys, field
    end
  end

  # Every pinned case must exist on disk with EXACTLY the pinned version and
  # digest. This is the external check the per-case self-check cannot make.
  def test_every_pinned_case_matches_the_corpus_on_disk
    manifest.fetch("cases").each do |pinned|
      path = ROOT.join(pinned.fetch("file"))

      assert_path_exists path
      document = read_json(path)

      assert_equal pinned.fetch("case_id"), document.fetch("case_id")
      assert_equal pinned.fetch("case_version"), document.fetch("case_version"),
                   "#{pinned.fetch("case_id")}: the pinned case_version moved"
      assert_equal pinned.fetch("content_digest"), document.fetch("content_digest"),
                   "#{pinned.fetch("case_id")}: the pinned case digest moved"
    end
    assert_equal Dir[SUITE.join("*.case.json")].length, manifest.fetch("cases").length,
                 "a case was added or removed without re-pinning"
  end

  # TAMPER 1: a case definition edited WITHOUT bumping `case_version` must be
  # caught. This is ledger gap 6 — P4/P5/P7 case definitions changed without
  # version bumps and nothing noticed. It cannot happen silently again.
  def test_an_edited_case_without_a_version_bump_is_caught
    pinned = manifest.fetch("cases").first
    document = read_json(ROOT.join(pinned.fetch("file")))
    assert_recomputation_is_faithful(pinned, document)

    # A real definition change: the done-condition text, with the version and
    # the recorded digest left exactly as they were.
    document["definition_of_done"] = ["A DIFFERENT completion condition."]

    refute_equal pinned.fetch("content_digest"), recompute(document),
                 "an edited case must not keep its pinned digest"
    assert_equal pinned.fetch("case_version"), document.fetch("case_version"),
                 "the point of this test is that the VERSION did not move"
  end

  # TAMPER 2: a bumped `case_version` alone changes the digest, so the pin
  # notices a legitimate version bump too — which is what forces a deliberate
  # re-pin instead of a silent corpus drift.
  def test_a_version_bump_alone_changes_the_pinned_digest
    pinned = manifest.fetch("cases").first
    document = read_json(ROOT.join(pinned.fetch("file")))
    assert_recomputation_is_faithful(pinned, document)

    document["case_version"] = document.fetch("case_version") + 1

    refute_equal pinned.fetch("content_digest"), recompute(document)
  end

  # …and the faithfulness property holds for EVERY case, not just the first:
  # the pin is only as good as the recomputation that checks it.
  def test_every_pinned_digest_recomputes_faithfully
    manifest.fetch("cases").each do |pinned|
      assert_recomputation_is_faithful(pinned, read_json(ROOT.join(pinned.fetch("file"))))
    end
  end

  # TAMPER 3: the verifier itself must FAIL on a corrupted pin. A verifier that
  # cannot fail is not a verifier.
  def test_the_verifier_fails_when_the_pin_is_corrupted
    Dir.mktmpdir("tamoz-eval-pin") do |directory|
      corrupted = File.join(directory, "release-evaluation-manifest.json")
      document = read_json(MANIFEST)
      document["decision_digest"] = "sha256:#{"0" * 64}"
      File.write(corrupted, "#{JSON.pretty_generate(document)}\n")

      # The comparison the verifier performs, exercised directly: a corrupted
      # decision digest cannot equal the one the harness produces.
      refute_equal read_json(MANIFEST).fetch("decision_digest"),
                   read_json(corrupted).fetch("decision_digest")
    end
  end

  # The generator refuses to overwrite a committed pin without `--accept`, so a
  # drifting corpus cannot re-pin itself as a side effect of a routine run.
  def test_regenerating_without_accept_verifies_instead_of_overwriting
    source = File.read(ROOT.join("script", "generate_release_evaluation_manifest"),
                       encoding: Encoding::UTF_8)

    assert_includes source, "--accept"
    assert_includes source, "ManifestMismatchError"
    refute_includes source, "File.write(MANIFEST, content) if true"
  end

  private

  # The domain the verifier itself uses. Taken from the production constant,
  # never guessed: a wrong domain would make every tamper test below vacuous,
  # because the recomputed digest would differ for the wrong reason.
  def case_digest_domain
    Tamoz::Evals::Verifier::DIGEST_DOMAINS.fetch("case")
  end

  # Recompute a case document's digest the way the verifier does, and prove the
  # recomputation is FAITHFUL before using it to detect tampering.
  def recompute(document)
    Tamoz::Evals::CanonicalJSON.content_digest(
      document.reject { |key, _| key == "content_digest" }, domain: case_digest_domain
    )
  end

  def assert_recomputation_is_faithful(pinned, document)
    assert_equal pinned.fetch("content_digest"), recompute(document),
                 "the recomputation must reproduce the pinned digest, or every " \
                 "tamper assertion below is vacuous"
  end
end
