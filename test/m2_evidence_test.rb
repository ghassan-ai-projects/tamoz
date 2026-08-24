# frozen_string_literal: true

require_relative "test_helper"

class M2EvidenceTest < Minitest::Test
  CORPORA = {
    m1_core: {
      tmpdir_prefix: "tamoz-m1-evidence",
      script: "run_m1_conformance",
      result_count: 4,
      clean_behavior: "m1.core",
      dirty_behavior: "m1.core.dirty-test"
    },
    m2_graph: {
      tmpdir_prefix: "tamoz-m2-evidence",
      script: "run_m2_conformance",
      result_count: 6,
      clean_behavior: "m2.graph",
      dirty_behavior: "m2.graph.dirty-test",
      subject_id: "tamoz-graph"
    }
  }.freeze

  def test_m1_runner_emits_four_verified_results
    run_conformance_corpus(CORPORA.fetch(:m1_core))
  end

  def test_m2_runner_emits_six_verified_results
    run_conformance_corpus(CORPORA.fetch(:m2_graph))
  end

  def test_m1_runner_uses_only_fixed_source_controlled_selections
    assert_runner_source_is_fixed("run_m1_conformance")
  end

  def test_m2_runner_uses_only_fixed_source_controlled_selections
    assert_runner_source_is_fixed("run_m2_conformance")
  end

  private

  def run_conformance_corpus(corpus)
    unless RUBY_PLATFORM.include?("darwin") && File.executable?("/usr/bin/sandbox-exec")
      skip "this host has no supported OS network sandbox"
    end
    skip "this host denies sandbox profile application (sandbox_apply EPERM)" unless seatbelt_profiles_apply?

    Dir.mktmpdir(corpus.fetch(:tmpdir_prefix)) do |directory|
      stdout, stderr, status = Open3.capture3(
        {"TAMOZ_ALLOW_DIRTY_EVIDENCE" => "1"},
        RbConfig.ruby,
        ROOT.join("script", corpus.fetch(:script)).to_s,
        directory
      )
      assert status.success?, "#{stdout}\n#{stderr}"

      summary = JSON.parse(stdout)
      assert_empty summary.fetch("failures")
      assert_equal "macos-seatbelt", summary.fetch("sandbox")
      expected_behavior = summary.fetch("dirty") ? corpus.fetch(:dirty_behavior) : corpus.fetch(:clean_behavior)
      results = Pathname.new(directory).glob("*.result.json").sort
      assert_equal corpus.fetch(:result_count), results.length

      results.each do |path|
        verification = Tamoz::Evals.verify(path)
        document = verification.document
        assert_equal "pass", verification.decision
        assert_equal "sandbox", document.dig("environment", "isolation")
        assert_equal "denied", document.dig("environment", "network")
        assert_equal expected_behavior, document.dig("subject", "behavior_version")
        if (subject_id = corpus[:subject_id])
          assert_equal subject_id, document.dig("subject", "id")
        end
        assert_equal 0, document.dig("provenance", "seed")
        assert_equal ["evaluator", "scorer", "gate"],
                     document.dig("provenance", "components").map { |entry| entry.fetch("role") }
        assert_equal 1, verification.references.length
        assert_equal "passed", document.dig("provenance", "attempts", 0, "status")
      end
    end
  end

  def assert_runner_source_is_fixed(script_name)
    source = ROOT.join("script", script_name).read(encoding: Encoding::UTF_8)

    assert_includes source, "SELECTIONS = {"
    assert_includes source, "(deny network*)"
    assert_includes source, "BUNDLE_IGNORE_CONFIG"
    assert_includes source, "Tamoz::Evals::Harness::SubprocessRunner"
    assert_includes source, "OUTPUT_LIMIT_BYTES"
    assert_includes source, "\"--seed\""
    refute_match(/input.*(?:command|test_file)|system\s*\(|shell|sh\s+-c|Open3/i, source)
  end

  # sandbox-exec can exist while profile application is denied (hardened
  # runtimes, nested sandboxes). The runner's own self-test aborts in that
  # case, so probe the same property before claiming the host is supported.
  def seatbelt_profiles_apply?
    Dir.mktmpdir("tamoz-seatbelt-probe") do |directory|
      profile = File.join(directory, "probe.sb")
      File.write(profile, "(version 1)(allow default)")
      system("/usr/bin/sandbox-exec", "-f", profile, RbConfig.ruby, "-e", "true")
    end
  end
end
