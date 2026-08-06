# frozen_string_literal: true

require_relative "test_helper"

# P15-E (docs/P15_RELEASE_PLAN.md §7, correction 8) — the benchmark report is
# held to the same standard as the numbers in it.
#
# The failure mode a benchmark test must prevent is not a slow build; it is a
# DISHONEST report: one that gates a number it cannot reproduce, quietly drops
# a counter, or publishes a ratio without the context that stops a reader
# misusing it. The benchmark itself runs in the rehearsal, not in `rake ci` —
# 20 durable turns is not something to pay for on every test run.
class BenchmarkReportTest < Minitest::Test
  REPORT = ROOT.join("docs", "benchmark.json")
  MARKDOWN = ROOT.join("docs", "BENCHMARK.md")

  def report = @report ||= read_json(REPORT)

  # The report is hard-wrapped prose, so a claim can straddle a line break.
  # Assertions are made against whitespace-normalized text: the property is
  # "the report says this", not "it says it on one line".
  def markdown
    @markdown ||= File.read(MARKDOWN, encoding: Encoding::UTF_8).gsub(/\s+/, " ")
  end

  def test_the_benchmark_evidence_exists_in_both_forms
    assert_path_exists REPORT
    assert_path_exists MARKDOWN
  end

  # The numbers must come from an offline model. A live provider is not
  # seed-controlled, so a committed number measured against one would not be
  # reproducible — correction 8's central requirement.
  def test_the_numbers_are_offline_and_seed_free
    assert_includes report.fetch("model"), "offline scripted"
    assert_includes report.fetch("model"), "no network"
    assert_includes report.fetch("not_attempted").join(" "), "live-provider"
  end

  # Every gated counter must be present. A counter that vanishes takes its gate
  # with it, and the report would still say "PASSED".
  def test_every_gated_counter_is_present
    gated = report.fetch("gated")

    %w[repetitions warmup model_calls_per_ephemeral_turn
       model_calls_per_durable_turn durable_checkpoints_per_turn
       file_descriptor_growth thread_growth].each do |counter|
      assert gated.key?(counter), "the gated counter #{counter} is missing"
    end
    assert_operator gated.fetch("repetitions"), :>=, 20
    assert_operator gated.fetch("warmup"), :>=, 1
  end

  # Resource growth is the one thing gated absolutely: a leak is a defect
  # whatever the pin says.
  def test_the_recorded_run_leaked_nothing
    gated = report.fetch("gated")

    assert_equal 0, gated.fetch("file_descriptor_growth")
    assert_equal 0, gated.fetch("thread_growth")
  end

  # The durable path really is doing durable work — a benchmark that recorded
  # zero checkpoints would be measuring the wrong thing entirely.
  def test_the_durable_scenario_actually_checkpoints
    assert_operator report.fetch("gated").fetch("durable_checkpoints_per_turn"), :>, 0
    assert_equal report.fetch("gated").fetch("model_calls_per_ephemeral_turn"),
                 report.fetch("gated").fetch("model_calls_per_durable_turn"),
                 "both scenarios must do the SAME model work, or the overhead " \
                 "ratio is measuring something else"
  end

  # Latency is reported at three percentiles, and the machine is recorded, so a
  # number from a different machine is recognisably not a regression.
  def test_latency_is_reported_with_its_environment
    %w[ephemeral_turn_ms durable_turn_ms].each do |scenario|
      row = report.fetch("measured").fetch(scenario)

      %w[p50 p95 p99].each { |p| assert_operator row.fetch(p), :>=, 0 }
      assert_operator row.fetch("p99"), :>=, row.fetch("p50")
    end
    environment = report.fetch("environment")

    refute_nil environment.fetch("ruby")
    refute_nil environment.fetch("platform")
    refute_nil environment.fetch("measured_at")
  end

  # The overhead ratio must be published WITH the context that stops it being
  # misread. "243x slower" without "the baseline touches no disk and calls no
  # network" is a number that misleads a reader who trusts it.
  def test_the_overhead_ratio_is_published_with_its_context
    assert_includes markdown, "Durability overhead"
    assert_includes markdown, "needs its context or it will mislead"
    assert_includes markdown, "touches no disk"
    assert_includes markdown, "not \"Tamoz versus another agent framework\""
    assert_includes markdown, "the real price"
  end

  # What was NOT measured has to be stated, not implied by absence.
  def test_the_report_states_what_it_did_not_attempt
    assert_includes markdown, "## Not attempted"
    refute_empty report.fetch("not_attempted")
    assert_includes markdown, "would measure the harness rather than the systems"
  end

  # The gated/reported split must be explained in the published report, because
  # a reader who cannot see which numbers are gated cannot judge the gate.
  def test_the_gated_and_reported_split_is_explained
    assert_includes markdown, "| **Gated** |"
    assert_includes markdown, "| Reported |"
    assert_includes markdown, "a gate that fails for noise is a gate people learn to ignore"
  end
end
