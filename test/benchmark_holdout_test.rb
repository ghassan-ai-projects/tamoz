# frozen_string_literal: true

require_relative "test_helper"

# P7 (docs/new-design/PHASE_P7_BENCHMARK.md): holdout mechanics. Cases are
# generated AFTER the protocol freeze with opaque ids and a temporal cutoff on
# every input; the model-visible bytes are scanned for truth leaks; the truth
# lives in a separate file (scorer credentials) from the manifest (worker
# credentials). These tests pin the mechanics: a seeded leak in the visible
# bytes must be detected, the ids must be opaque, and every observation must
# predate the cutoff.
class BenchmarkHoldoutTest < Minitest::Test
  HOLD_OUT_SCRIPT = ROOT.join("script", "benchmark_holdout")

  def run_holdout(cases: 12, seed: 23)
    dir = Dir.mktmpdir("tamoz-holdout")
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, HOLD_OUT_SCRIPT.to_s, "--cases", cases.to_s, "--seed", seed.to_s,
      "--out", dir, chdir: ROOT.to_s
    )
    assert status.success?, "holdout generation failed:\n#{stderr}#{stdout}"
    {
      "manifest" => read_json(File.join(dir, "holdout-manifest.json")),
      "truth" => read_json(File.join(dir, "holdout-truth.json")),
      "leak_scan" => read_json(File.join(dir, "leak-scan.json")),
      "dir" => dir
    }
  end

  def test_manifest_and_truth_are_separate_files_with_matching_opaque_ids
    output = run_holdout
    manifest_ids = output.fetch("manifest").fetch("cases").map { |entry| entry.fetch("id") }
    truth_ids = output.fetch("truth").fetch("truths").map { |entry| entry.fetch("id") }

    assert_equal manifest_ids.sort, truth_ids.sort
    assert_empty manifest_ids.grep(/low_dissolved_oxygen|overheated/),
                 "case ids must be opaque (no truth encoding)"
    refute_includes manifest_ids, "pilot"
  end

  def test_every_observation_predates_the_cutoff
    output = run_holdout
    cutoff = Time.parse(output.fetch("manifest").fetch("cutoff"))
    output.fetch("manifest").fetch("cases").each do |entry|
      assert_operator Time.parse(entry.fetch("observed_at")), :<, cutoff,
                      "#{entry.fetch("id")} must predate the cutoff"
    end
  end

  def test_the_manifest_binds_the_frozen_protocol
    output = run_holdout
    protocol_sha256 = Digest::SHA256.hexdigest(
      File.binread(ROOT.join("docs", "benchmark", "BENCHMARK_PROTOCOL.json"))
    )
    assert_equal protocol_sha256, output.fetch("manifest").fetch("protocol_sha256")
    assert_equal "1.0.0", output.fetch("manifest").fetch("benchmark_protocol_version")
  end

  def test_a_forbidden_token_in_the_visible_bytes_is_detected
    # A truth-bearing case (the word "answer" embedded in a fact) must trip
    # the leak scan. We inject it by generating and mutating the model-visible
    # bytes, then re-running the scan.
    output = run_holdout(cases: 4)
    leaked = output.fetch("manifest").fetch("cases").first.merge("facts" => {"leak" => "the answer is 42"})
    scan = Tamoz::Evals::Benchmark::LeakScan.new([leaked]).call
    refute_empty scan.fetch("violations")
    assert_match(/forbidden_token/, scan.fetch("violations").first)
  end

  def test_generation_is_seed_deterministic
    first = run_holdout(cases: 6, seed: 7)
    second = run_holdout(cases: 6, seed: 7)
    assert_equal first.fetch("manifest"), second.fetch("manifest")
    assert_equal first.fetch("truth"), second.fetch("truth")
  ensure
    FileUtils.remove_entry(first.fetch("dir")) if first
    FileUtils.remove_entry(second.fetch("dir")) if second
  end
end
