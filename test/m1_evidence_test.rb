# frozen_string_literal: true

require_relative "test_helper"

class M1EvidenceTest < Minitest::Test
  def test_fixed_runner_emits_four_verified_results
    unless RUBY_PLATFORM.include?("darwin") && File.executable?("/usr/bin/sandbox-exec")
      skip "this host has no supported OS network sandbox"
    end

    Dir.mktmpdir("tamoz-m1-evidence") do |directory|
      stdout, stderr, status = Open3.capture3(
        {"TAMOZ_ALLOW_DIRTY_EVIDENCE" => "1"},
        RbConfig.ruby,
        ROOT.join("script", "run_m1_conformance").to_s,
        directory
      )
      assert status.success?, "#{stdout}\n#{stderr}"

      summary = JSON.parse(stdout)
      assert_empty summary.fetch("failures")
      assert_equal "macos-seatbelt", summary.fetch("sandbox")
      expected_behavior = summary.fetch("dirty") ? "m1.core.dirty-test" : "m1.core"
      results = Pathname.new(directory).glob("*.result.json").sort
      assert_equal 4, results.length

      results.each do |path|
        verification = Tamoz::Evals.verify(path)
        document = verification.document
        assert_equal "pass", verification.decision
        assert_equal "sandbox", document.dig("environment", "isolation")
        assert_equal "denied", document.dig("environment", "network")
        assert_equal expected_behavior, document.dig("subject", "behavior_version")
        assert_equal 0, document.dig("provenance", "seed")
        assert_equal ["evaluator", "scorer", "gate"],
                     document.dig("provenance", "components").map { |entry| entry.fetch("role") }
        assert_equal 1, verification.references.length
        assert_equal "passed", document.dig("provenance", "attempts", 0, "status")
      end
    end
  end

  def test_runner_uses_only_fixed_source_controlled_selections
    source = ROOT.join("script", "run_m1_conformance").read

    assert_includes source, "SELECTIONS = {"
    assert_includes source, "(deny network*)"
    assert_includes source, "BUNDLE_IGNORE_CONFIG"
    assert_includes source, "Process.kill(\"TERM\", -wait_thread.pid)"
    assert_includes source, "\"--seed\""
    refute_match(/input.*(?:command|test_file)|system\s*\(|shell|sh\s+-c/i, source)
  end
end
