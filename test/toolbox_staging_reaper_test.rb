# frozen_string_literal: true

require_relative "test_helper"

# P15-C (ledger §5.5) — the stale staging reaper.
#
# Atomic publication stages into a private `.tamoz-*.tmp` beside its target and
# unlinks it in an `ensure`. SIGKILL runs no `ensure`, so a crash between
# "staged" and "published" leaves the file behind; the kill matrix has tolerated
# these since P6 and recorded them as residual risk. This is the sweep.
#
# The tests that matter here are the REFUSALS. An agent that deletes files is
# the thing this project spends most of its effort preventing, so every
# narrowing rule is proven by planting something the sweep must not touch.
class ToolboxStagingReaperTest < Minitest::Test
  ANCIENT = Time.now - 3600

  def test_a_stale_orphan_is_removed_at_action_capable_construction
    with_workspace do |root|
      orphan = plant(root, ".tamoz-20260915-4242-abc123.tmp", mtime: ANCIENT)
      create_orphan = plant(root, ".tamoz-create-20260915-4242-def456.tmp", mtime: ANCIENT)

      toolbox = Tamoz::Tools::Toolbox.new(root:, allow_changes: true)

      refute_path_exists orphan
      refute_path_exists create_orphan
      assert_equal [".tamoz-20260915-4242-abc123.tmp", ".tamoz-create-20260915-4242-def456.tmp"],
                   toolbox.reaped_staging.sort
    end
  end

  # Orphans appear wherever a patch or a create ran, not only at the root.
  def test_orphans_are_swept_from_nested_directories
    with_workspace do |root|
      FileUtils.mkdir_p(File.join(root, "lib", "deep"))
      nested = plant(root, File.join("lib", "deep", ".tamoz-20260915-4242-nested.tmp"), mtime: ANCIENT)

      Tamoz::Tools::Toolbox.new(root:, allow_changes: true)

      refute_path_exists nested
    end
  end

  # A sibling session publishing RIGHT NOW must not have its staging file pulled
  # out from under it. Publication takes milliseconds; the floor is 60 seconds.
  def test_a_fresh_staging_file_is_left_alone
    with_workspace do |root|
      fresh = plant(root, ".tamoz-20260915-4242-inflight.tmp", mtime: Time.now)

      toolbox = Tamoz::Tools::Toolbox.new(root:, allow_changes: true)

      assert_path_exists fresh
      assert_empty toolbox.reaped_staging
    end
  end

  # A read-only session stages nothing, so it has nothing to clean — and no
  # business deleting a file.
  def test_a_read_only_toolbox_never_sweeps
    with_workspace do |root|
      orphan = plant(root, ".tamoz-20260915-4242-abc123.tmp", mtime: ANCIENT)

      toolbox = Tamoz::Tools::Toolbox.new(root:)

      assert_path_exists orphan
      assert_empty toolbox.reaped_staging
    end
  end

  # The narrowing rules, each proven by planting something the sweep must skip.
  def test_the_sweep_refuses_everything_that_is_not_its_own_staging_file
    with_workspace do |root|
      user_file = plant(root, "notes.tmp", mtime: ANCIENT)
      near_miss = plant(root, ".tamoz-20260915-4242-abc123.tmp.bak", mtime: ANCIENT)
      prefix_only = plant(root, ".tamozzz.tmp", mtime: ANCIENT)
      # A regular file wearing the prefix but NOT the date-pid-random shape the
      # publisher stages under: it is the operator's, and provenance keeps it.
      operator_file = plant(root, ".tamoz-notes.tmp", mtime: ANCIENT)
      directory = File.join(root, ".tamoz-20260915-4242-dir.tmp")
      FileUtils.mkdir_p(directory)

      # A symlink WEARING a real staging name, pointing at something precious. The
      # sweep must neither follow it nor remove it.
      secret = File.join(root, "secret.txt")
      File.write(secret, "keep me\n")
      link = File.join(root, ".tamoz-20260915-4242-evil.tmp")
      File.symlink(secret, link)
      File.utime(ANCIENT, ANCIENT, root)

      toolbox = Tamoz::Tools::Toolbox.new(root:, allow_changes: true)

      assert_empty toolbox.reaped_staging
      [user_file, near_miss, prefix_only, operator_file, directory].each { |p| assert_path_exists p }
      assert File.symlink?(link), "a symlink wearing the staging name must survive"
      assert_equal "keep me\n", File.read(secret), "the symlink target must be untouched"
    end
  end

  def test_ignored_directories_are_not_traversed
    with_workspace do |root|
      %w[.git vendor node_modules].each do |ignored|
        FileUtils.mkdir_p(File.join(root, ignored))
        plant(root, File.join(ignored, ".tamoz-20260915-4242-vendored.tmp"), mtime: ANCIENT)
      end

      toolbox = Tamoz::Tools::Toolbox.new(root:, allow_changes: true)

      assert_empty toolbox.reaped_staging
      %w[.git vendor node_modules].each do |ignored|
        assert_path_exists File.join(root, ignored, ".tamoz-20260915-4242-vendored.tmp")
      end
    end
  end

  # The sweep is best-effort: a file that vanishes between the scan and the
  # unlink is skipped, never raised, because a housekeeping failure must not
  # fail a session.
  def test_a_vanishing_file_does_not_fail_construction
    with_workspace do |root|
      plant(root, ".tamoz-20260915-4242-racing.tmp", mtime: ANCIENT)
      toolbox = Tamoz::Tools::Toolbox.new(root:, reap_staging: false, allow_changes: true)
      File.unlink(File.join(root, ".tamoz-20260915-4242-racing.tmp"))

      assert_empty toolbox.reap_stale_staging
    end
  end

  def test_stale_staging_files_inspects_without_removing
    with_workspace do |root|
      orphan = plant(root, ".tamoz-20260915-4242-inspect.tmp", mtime: ANCIENT)
      toolbox = Tamoz::Tools::Toolbox.new(root:, allow_changes: true, reap_staging: false)

      assert_equal [Pathname.new(orphan)], toolbox.stale_staging_files
      assert_path_exists orphan
    end
  end

  def test_the_sweep_is_bounded
    with_workspace do |root|
      total = Tamoz::Tools::Toolbox::MAX_REAPED_STAGING_FILES + 25
      total.times { |index| plant(root, format(".tamoz-20260915-4242-%04d.tmp", index), mtime: ANCIENT) }

      toolbox = Tamoz::Tools::Toolbox.new(root:, allow_changes: true)

      assert_equal Tamoz::Tools::Toolbox::MAX_REAPED_STAGING_FILES,
                   toolbox.reaped_staging.length
      # The rest survive to the next sweep rather than being deleted in one
      # unbounded pass.
      assert_equal 25, Dir.children(root).count { |name| name.start_with?(".tamoz-") }
    end
  end

  # The end-to-end claim: after a crash leaves an orphan, the next action-capable
  # session starts from a clean workspace and the ordinary tools still work.
  def test_a_swept_workspace_still_publishes_correctly
    with_workspace do |root|
      File.write(File.join(root, "app.rb"), "value = 1\n")
      plant(root, ".tamoz-20260915-4242-crashed.tmp", mtime: ANCIENT)

      toolbox = Tamoz::Tools::Toolbox.new(root:, allow_changes: true)

      assert_equal [".tamoz-20260915-4242-crashed.tmp"], toolbox.reaped_staging
      toolbox.execute(
        "apply_patch",
        {"path" => "app.rb",
         "expected_sha256" => Digest::SHA256.hexdigest("value = 1\n"),
         "before" => "value = 1", "after" => "value = 2"}
      )

      assert_equal "value = 2\n", File.read(File.join(root, "app.rb"))
      assert_empty Dir.children(root).grep(/\A\.tamoz-/),
                   "a completed publication leaves no staging file behind"
    end
  end

  private

  def with_workspace
    Dir.mktmpdir("tamoz-reaper") { |directory| yield File.realpath(directory) }
  end

  def plant(root, relative, mtime:)
    path = File.join(root, relative)
    File.write(path, "staged\n")
    File.utime(mtime, mtime, path)
    path
  end
end
