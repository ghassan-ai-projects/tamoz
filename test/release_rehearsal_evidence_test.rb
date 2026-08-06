# frozen_string_literal: true

require_relative "test_helper"

# P15-H — the committed rehearsal evidence must stay honest.
#
# A rehearsal log is the kind of artifact that rots quietly: it can record a
# failure, or a commit nobody can find, or a toolchain nobody pinned, and still
# sit in the repository looking like proof. These assertions are what make it
# proof rather than decoration.
class ReleaseRehearsalEvidenceTest < Minitest::Test
  REPORT_PATH = ROOT.join("docs", "release-rehearsal.json")
  MARKDOWN_PATH = ROOT.join("docs", "RELEASE_REHEARSAL.md")

  def report = @report ||= read_json(REPORT_PATH)

  def test_the_rehearsal_evidence_exists_in_both_forms
    assert_path_exists REPORT_PATH
    assert_path_exists MARKDOWN_PATH
    assert_includes File.read(MARKDOWN_PATH, encoding: Encoding::UTF_8),
                    "# Release rehearsal (P15-H)"
  end

  # A recorded failure must never be committed as if it were evidence.
  def test_the_recorded_rehearsal_passed
    assert report.fetch("ok"), "the committed rehearsal did not pass"
    failed = report.fetch("steps").reject { |step| step.fetch("ok") }

    assert_empty failed, "failed steps: #{failed.map { |step| step.fetch("step") }.inspect}"
  end

  # The candidate must be a real commit in THIS repository — a log naming a
  # commit nobody can check out proves nothing.
  def test_the_candidate_commit_is_resolvable
    candidate = report.fetch("candidate_commit")

    assert_match(/\A[0-9a-f]{40}\z/, candidate)
    _stdout, _stderr, status = Open3.capture3(
      "git", "cat-file", "-e", "#{candidate}^{commit}", chdir: ROOT.to_s
    )

    assert status.success?, "candidate #{candidate} is not a commit in this repository"
  end

  # The toolchain must be the PINNED one, not whatever the machine had loaded.
  def test_the_rehearsal_ran_on_the_pinned_toolchain
    toolchain = report.fetch("toolchain")

    assert_equal File.read(ROOT.join(".ruby-version"), encoding: Encoding::UTF_8).strip,
                 toolchain.fetch("pinned_ruby")
    assert_equal toolchain.fetch("pinned_ruby"), toolchain.fetch("ruby")
    assert_equal toolchain.fetch("lockfile_bundler"), toolchain.fetch("bundler")
  end

  # The steps the release plan §10 names must all be present: a rehearsal that
  # silently stopped covering the isolated gem install would still say "pass".
  def test_every_required_step_is_present
    required = %w[
      provisioning clean-clone bundle-install gate-lc-c gate-lc-utf8
      gate-locale-agreement scorecard packaged-gem-isolation durable-kill-resume
      backup-restore requirements-audit
    ]

    assert_equal [], required - report.fetch("steps").map { |step| step.fetch("step") }
  end

  # Both locales must have produced IDENTICAL totals: a locale-dependent gate is
  # the defect class this project opened with (D-1).
  def test_both_locales_agree
    totals = report.fetch("gate_totals")

    assert_equal 2, totals.length
    assert_equal 1, totals.values.uniq.length, totals.inspect
    assert_match(/0 failures, 0 errors, 0 skips/, totals.values.first)
  end

  # A passing rehearsal is NOT a release. If release-blocking gaps remain, the
  # published markdown has to say so where a reader will see it.
  def test_remaining_gaps_are_disclosed_in_the_published_report
    audit = report.fetch("requirements_audit")
    gaps = audit.fetch("release_blocking_gaps")
    markdown = File.read(MARKDOWN_PATH, encoding: Encoding::UTF_8)

    if gaps.empty?
      assert audit.fetch("definition_of_done_met")
      assert_includes markdown, "No release-blocking gaps."
    else
      refute audit.fetch("definition_of_done_met")
      assert_includes markdown, "Release-blocking gaps remaining"
      assert_includes markdown, "does not make"
      gaps.each { |gap| assert_includes markdown, gap }
    end
  end
end
