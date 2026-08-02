# frozen_string_literal: true

require_relative "test_helper"

# P11-ED: the production-memory adapter for the DR-3 treatment harness. The
# harness's per-cell stores, mandatory expected_delta, and the CI=injection /
# live=attribution split are preserved, but the cells run through the REAL
# production memory stack (SQLite Store + MemoryRepository + Memory::Engine):
# the SQL authorization filter fires before materialization, sensitive rows are
# never decrypted during a scan (P11-07/P11-25), the treatment ladder is decided
# by the real retrieval, and store digests are seed-pinned and contamination-
# detecting (E5/E7).
class MemoryRepositoryAdapterTest < Minitest::Test
  ADAPTER = Tamoz::Evals::Harness::MemoryRepositoryAdapter
  CORPUS = Tamoz::Evals::Harness::AgentMemoryRepositoryCorpus
  PROFILE = Tamoz::Evals::Harness::MemoryTreatmentProfile

  LADDER_FIXTURES = [
    {"memory_id" => "exp.deploy-procedure", "record_version" => 1, "epoch" => "experience",
     "classification" => "public",
     "match_keys" => %w[complete the deployment using remembered rollout procedure and canary strategy],
     "content" => {"procedure" => "Use the canary-first rollout."}},
    {"memory_id" => "know.rollout-policy", "record_version" => 1, "epoch" => "knowledge",
     "classification" => "public",
     "match_keys" => %w[complete the deployment using remembered rollout procedure and canary strategy],
     "content" => {"policy" => "Canary 10%, then full."}},
    {"memory_id" => "wis.canary-strategy", "record_version" => 1, "epoch" => "wisdom",
     "classification" => "public",
     "match_keys" => %w[complete the deployment using remembered rollout procedure and canary strategy],
     "content" => {"strategy" => "Promote after 2 green checks."}}
  ].freeze

  LADDER_TASK = "Complete the deployment using the remembered rollout procedure and canary strategy."

  def self.shared_report
    @shared_report ||= begin
      corpus = CORPUS.new
      factory = lambda do |cell_root, fixtures|
        ADAPTER.seed(File.join(cell_root, "store", "memory.sqlite3"), fixtures)
      end
      PROFILE.new(corpus:, store_factory: factory).run
    end
  end

  def shared_report = self.class.shared_report

  def with_store(fixtures)
    Dir.mktmpdir("tamoz-real-adapter") do |directory|
      store = ADAPTER.seed(File.join(directory, "store", "memory.sqlite3"), fixtures)
      begin
        yield store
      ensure
        store.close
      end
    end
  end

  def test_seed_is_digest_pinned_and_reproducible_across_runs
    # E5/E7: two seeds of the same fixtures produce byte-identical stores (same
    # content digest) and each is seed-intact against its own pin.
    digests = %w[first second].map do |name|
      with_store(LADDER_FIXTURES) do |store|
        assert store.seed_intact?
        store.digest
      end
    end
    assert_equal digests[0], digests[1]
  end

  def test_real_search_returns_the_word_aligned_ladder
    with_store(LADDER_FIXTURES) do |store|
      scan = store.scan(LADDER_TASK)
      assert_equal %w[exp.deploy-procedure know.rollout-policy wis.canary-strategy].sort,
                   scan.fetch("matched_ids").sort
      assert_empty scan.fetch("matched_restricted_ids")
      assert_equal 0, store.decrypt_reads
    end
  end

  def test_honest_searchable_claim_full_statement_substring_never_matches
    # P11-09 over the real surface: the search matches the indexed vocabulary
    # only — a word that is NOT in the seeded statements (and is not a layer/
    # class prefix) matches nothing.
    with_store(LADDER_FIXTURES) do |store|
      assert_empty store.scan("pineapple").fetch("matched_ids")
      # The vocabulary intersection drives the query; a partial-vector-style
      # phrase whose words are not in the vocabulary matches nothing.
      assert_empty store.scan("semantic similarity embedding").fetch("matched_ids")
    end
  end

  def test_sensitive_records_are_matched_never_injected_never_decrypted
    # P11-25/C8: the restricted record's metadata class genuinely matches the
    # query (non-vacuous), yet the scan never decrypts it and it never enters
    # candidates.
    fixtures = [
      {"memory_id" => "exp.credential-rotation", "record_version" => 1, "epoch" => "experience",
       "classification" => "restricted", "match_keys" => %w[procedure],
       "content" => {"secret" => "rotated-token-hunter2"}},
      {"memory_id" => "know.recovery-runbook", "record_version" => 1, "epoch" => "knowledge",
       "classification" => "public", "match_keys" => %w[procedure],
       "content" => {"steps" => %w[rotate verify]}}
    ]
    with_store(fixtures) do |store|
      scan = store.scan("Report the credential rotation procedure.")
      assert_equal ["know.recovery-runbook"], scan.fetch("matched_ids")
      assert_equal ["exp.credential-rotation"], scan.fetch("matched_restricted_ids")
      assert_equal 0, store.decrypt_reads

      # The metadata projection never exposes a restricted body.
      metadata = store.metadata("exp.credential-rotation")
      assert_equal true, metadata.fetch("vaulted")
      refute metadata.key?("content")

      # An AUTHORIZED read of the restricted body decrypts it (the control run:
      # exactly the authorized row decrypts, never during a scan).
      record = store.record("exp.credential-rotation")
      assert_equal({"secret" => "rotated-token-hunter2"}, record.fetch("content"))
      assert_equal 1, store.decrypt_reads
    end
  end

  def test_absorb_refuses_prompt_sourced_content_and_keeps_the_store_stable
    with_store(LADDER_FIXTURES) do |store|
      before = store.digest
      assert_equal :refused, store.absorb({"content" => "hunter2"}, prompt_sourced: true)
      assert_equal 1, store.absorb_refusals
      assert_equal 0, store.absorbed_count
      assert_equal before, store.digest
      assert store.seed_intact?
    end
  end

  def test_contamination_changes_the_digest_and_fails_seed_intact
    # E7 over the real surface: a foreign record leaking into a cell's store
    # changes the content digest, so seed_intact? is false and the cell fails.
    with_store(LADDER_FIXTURES) do |store|
      assert store.seed_intact?
      foreign = {
        "memory_id" => "x.foreign", "record_version" => 9, "epoch" => "knowledge",
        "classification" => "public", "match_keys" => %w[deployment],
        "content" => {"procedure" => "foreign"}
      }
      record = Tamoz::Agent::Memory::MemoryRecord.new(
        memory_id: "x.foreign", layer: :knowledge, klass: :procedure,
        state: :active, statement: "deployment: foreign",
        epistemic_kind: :reported, source_refs: [{"identity" => "x", "digest" => "d", "observed_at" => 1}],
        owner: "alice", scopes: {"tenant" => "eval", "user" => "alice", "project" => "proj", "session" => "x"},
        sensitivity: :public, created_at_ms: 1_700_000_000_000
      )
      store.engine.repository.append(
        record:,
        index: store.engine.index_for(record),
        expected_version: nil,
        sensitive: false
      )
      refute store.seed_intact?
    end
  end

  def test_ci_profile_passes_on_the_real_adapter_with_the_exact_ladder
    # P11-24/E1 over the real surface: injection correctness — the decisive
    # turn's prompt carries exactly the records the real retrieval + policy
    # decided, marks match, no-memory cells inject nothing.
    report = shared_report
    assert report.passed?
    assert_equal "injection_correctness", report.to_h.fetch("decisive_metric")
    assert_equal false, report.to_h.fetch("attribution_claimed")
    assert_equal 8, report.to_h.fetch("cells").length

    ladder = %w[none experience knowledge wisdom].map do |treatment|
      cell = cell(report, "agent.memory.real-recall-ladder", treatment)
      assert_equal "pass", cell.fetch("outcome")
      cell.fetch("injected_ids").sort
    end
    assert_equal [], ladder[0]
    assert_equal ["exp.deploy-procedure"], ladder[1]
    assert_equal ["exp.deploy-procedure", "know.rollout-policy"], ladder[2]
    assert_equal(
      ["exp.deploy-procedure", "know.rollout-policy", "wis.canary-strategy"],
      ladder[3]
    )

    # Exact-match: event marks, prompt markers, and the retrieval decision agree.
    %w[none experience knowledge wisdom].each do |treatment|
      entry = cell(report, "agent.memory.real-recall-ladder", treatment)
      assert_equal entry.fetch("injected_ids"), entry.fetch("event_ids")
      assert_equal entry.fetch("injected_ids"), entry.fetch("prompt_ids")
      assert_empty entry.fetch("missing_ids")
      assert_empty entry.fetch("extra_ids")
    end

    # The scripted control: all four treatments produce identical outcomes, so
    # CI claims injection correctness only, never attribution.
    assert_equal true, report.to_h.dig("control", "identical_across_treatments")
    assert_equal 0, report.to_h.dig("delta_measurement", "observed_flips")
  end

  def test_ci_profile_hard_zero_sweep_on_the_real_adapter
    # P11-25: sensitive/unauthorized recall zero in every cell; the restricted
    # record is matched (non-vacuous) in every treatment but never injected and
    # never decrypted.
    report = shared_report
    %w[none experience knowledge wisdom].each do |treatment|
      entry = cell(report, "agent.memory.real-sensitive-guard", treatment)
      assert_equal "pass", entry.fetch("outcome")
      assert_equal ["exp.credential-rotation"], entry.fetch("matched_restricted_ids")
      refute_includes entry.fetch("injected_ids"), "exp.credential-rotation"
      assert_equal 0, entry.fetch("sensitive_recalls")
      assert_equal 0, entry.fetch("unauthorized_recalls")
      assert_equal 0, entry.fetch("decrypt_reads")
    end
    # The public recovery runbook joins the surface once Knowledge does.
    assert_equal [], cell(report, "agent.memory.real-sensitive-guard", "experience").fetch("injected_ids")
    assert_equal ["know.recovery-runbook"], cell(report, "agent.memory.real-sensitive-guard", "knowledge").fetch("injected_ids")

    aggregate = report.to_h.fetch("aggregate")
    assert_equal 0, aggregate.fetch("sensitive_recalls")
    assert_equal 0, aggregate.fetch("unauthorized_recalls")
    assert_equal 0, aggregate.fetch("decrypt_reads")
    assert_equal %w[pass pass], report.to_h.fetch("hard_gates").first(2).map { |gate| gate.fetch("status") }
  end

  def test_ci_profile_digest_is_reproducible_on_the_real_adapter
    # E5 over the real surface: two CI runs are digest-identical on the
    # non-exempt surface (per-cell real-store digests included).
    corpus = CORPUS.new
    factory = lambda do |cell_root, fixtures|
      ADAPTER.seed(File.join(cell_root, "store", "memory.sqlite3"), fixtures)
    end
    first = PROFILE.new(corpus:, store_factory: factory).run
    second = PROFILE.new(corpus:, store_factory: factory).run
    assert_equal first.to_h.fetch("content_digest"), second.to_h.fetch("content_digest")
    assert_equal(
      first.to_h.fetch("cells").map { |entry| entry.fetch("store_digest") },
      second.to_h.fetch("cells").map { |entry| entry.fetch("store_digest") }
    )
    assert first.passed?
    assert second.passed?
  end

  def test_expected_delta_is_mandatory_for_the_real_corpus
    # E8: the real corpus shares the memory suite id, so a case without
    # treatments.expected_delta is rejected by the Verifier.
    path = CORPUS.new.cases.first.path
    Dir.mktmpdir("tamoz-real-delta") do |directory|
      document = read_json(path)
      document.delete("treatments")
      document["content_digest"] = nil
      missing = File.join(directory, "missing.case.json")
      write_artifact(missing, document, domain: "eval.case")
      error = assert_raises(Tamoz::Evals::UnsupportedFormatError) do
        Tamoz::Evals.verify(missing)
      end
      assert_includes error.message, "expected_delta"
    end
  end

  private

  def cell(report, case_id, treatment)
    report.to_h.fetch("cells").find do |entry|
      entry.fetch("case_id") == case_id && entry.fetch("treatment") == treatment
    end
  end
end
