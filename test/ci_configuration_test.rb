# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class CIConfigurationTest < Minitest::Test
  def test_ci_matrix_and_permissions_match_m0_contract
    workflow = YAML.safe_load(
      ROOT.join(".github", "workflows", "ci.yml").read,
      aliases: false
    )
    job = workflow.fetch("jobs").fetch("test")

    assert_equal ["3.3", "3.4", "4.0"], job.dig("strategy", "matrix", "ruby")
    assert_equal false, job.dig("strategy", "fail-fast")
    assert_equal({"contents" => "read"}, workflow.fetch("permissions"))
    assert(
      job.fetch("steps").any? { |step| step["run"] == "bundle exec rake ci" },
      "CI must execute the same local M0 gate"
    )
  end

  def test_lockfile_has_a_portable_platform
    lockfile = ROOT.join("Gemfile.lock").read

    assert_match(/^  ruby$/, lockfile)
    assert_match(/^BUNDLED WITH\n +4\.0\.12$/, lockfile)
  end
end
