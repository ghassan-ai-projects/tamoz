# frozen_string_literal: true

require_relative "test_helper"
require "yaml"

class CIConfigurationTest < Minitest::Test
  def test_ci_workflow_and_permissions_match_the_m0_gate
    workflow = YAML.safe_load(
      ROOT.join(".github", "workflows", "ci.yml").read(encoding: Encoding::UTF_8),
      aliases: false
    )
    job = workflow.fetch("jobs").fetch("test")

    # 57ca1d1 pinned CI to a single precompiled-gem Ruby; the workflow no
    # longer carries a version matrix. The workflow reads .ruby-version by
    # name: the sealed-build fingerprint binds the exact Ruby version and
    # patchlevel, so a floating "3.3" would regenerate the committed protocol
    # pins under a different Ruby than the one that produced them.
    setup = job.fetch("steps").find { |step| step.fetch("uses", "").start_with?("ruby/setup-ruby@") }
    assert_equal ".ruby-version", setup.dig("with", "ruby-version")
    assert_nil job["strategy"]
    assert_equal 15, job.fetch("timeout-minutes")
    assert_equal({"contents" => "read"}, workflow.fetch("permissions"))
    assert_equal true, workflow.dig("concurrency", "cancel-in-progress")
    checkout = job.fetch("steps").find { |step| step.fetch("uses", "").start_with?("actions/checkout@") }
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
