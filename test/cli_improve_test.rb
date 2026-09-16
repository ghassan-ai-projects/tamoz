# frozen_string_literal: true

require_relative "test_helper"

# `tamoz improve` — proves the improvement gem is now reachable from a real
# production entry point (the CLI), running the actual generator over a corpus.
class CLIImproveTest < Minitest::Test
  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    code = Tamoz::Agent::CLI.run(argv, out:, err:)
    [code, out.string, err.string]
  end

  def write_corpus(dir, trajectories)
    trajectories.each_with_index do |steps, index|
      File.write(File.join(dir, "t#{index}.json"),
                 JSON.generate("verified" => true, "partition" => "train", "steps" => steps))
    end
  end

  def read_then_patch(path)
    [{"tool" => "read_file", "arguments" => {"path" => path}},
     {"tool" => "apply_patch", "arguments" => {"path" => path}}]
  end

  def test_missing_corpus_is_a_usage_error
    code, _out, err = run_cli(["improve"])
    assert_equal 2, code
    assert_match(/--corpus/, err)
  end

  def test_generator_runs_and_reports_no_candidate
    Dir.mktmpdir("tamoz-improve") do |dir|
      write_corpus(dir, [[{"tool" => "apply_patch", "arguments" => {"path" => "a.rb"}}]])
      code, out, _err = run_cli(["improve", "--corpus", dir])
      assert_equal 0, code
      assert_match(/No candidate/, out)
    end
  end

  def test_generator_emits_a_candidate_from_verified_trajectories
    Dir.mktmpdir("tamoz-improve") do |dir|
      write_corpus(dir, Array.new(3) { read_then_patch("a.rb") })
      code, out, _err = run_cli(["improve", "--corpus", dir, "--json"])
      assert_equal 0, code
      payload = JSON.parse(out)
      candidate = payload.fetch("candidate")
      refute_nil candidate, "three verified read_file→apply_patch trajectories clear the floor"
      assert_equal "read_file", candidate.fetch("precursor_tool")
      assert_equal "apply_patch", candidate.fetch("subject_tool")
    end
  end
end
