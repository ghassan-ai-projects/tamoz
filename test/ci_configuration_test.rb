# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class CIConfigurationTest < Minitest::Test
  def test_ci_matrix_and_permissions_match_m0_contract
    workflow = YAML.safe_load(
      ROOT.join(".github", "workflows", "ci.yml").read(encoding: Encoding::UTF_8),
      aliases: false
    )
    job = workflow.fetch("jobs").fetch("test")

    assert_equal ["3.3", "3.4", "4.0"], job.dig("strategy", "matrix", "ruby")
    assert_equal false, job.dig("strategy", "fail-fast")
    assert_equal 15, job.fetch("timeout-minutes")
    assert_equal({"contents" => "read"}, workflow.fetch("permissions"))
    assert_equal true, workflow.dig("concurrency", "cancel-in-progress")
    checkout = job.fetch("steps").find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
    setup = job.fetch("steps").find { |step| step.fetch("uses", "").start_with?("ruby/setup-ruby@") }
    assert_match(/actions\/checkout@[0-9a-f]{40}\z/, checkout.fetch("uses"))
    assert_equal false, checkout.dig("with", "persist-credentials")
    assert_match(/ruby\/setup-ruby@[0-9a-f]{40}\z/, setup.fetch("uses"))
    assert(
      job.fetch("steps").any? { |step| step["run"] == "bundle exec rake ci" },
      "CI must execute the same local M0 gate"
    )
  end

  def test_lockfile_has_a_portable_platform
    lockfile = ROOT.join("Gemfile.lock").read(encoding: Encoding::UTF_8)

    assert_match(/^  ruby$/, lockfile)
    assert_match(/^BUNDLED WITH\n +4\.0\.12$/, lockfile)
  end
end
