# frozen_string_literal: true

require_relative 'test_helper'

# Tamoz::Core::AtomicFile: a reader sees old or new bytes, never a torn file, and no temp file outlives a write.
class CoreAtomicFileTest < Minitest::Test
  AtomicFile = Tamoz::Core::AtomicFile

  def setup = @dir = Dir.mktmpdir('tamoz-atomic')
  def teardown = FileUtils.remove_entry(@dir)

  def path(name = 'file.txt') = File.join(@dir, name)
  def leftovers = Dir.children(@dir).grep(/\.tmp\z/)

  def test_replace_swaps_the_bytes_and_sets_the_mode
    File.write(path, "old\n")
    AtomicFile.replace(path, "new\n", mode: 0o640)

    assert_equal "new\n", File.read(path)
    assert_equal 0o640, File.stat(path).mode & 0o777
    assert_empty leftovers
  end

  def test_create_refuses_an_existing_name_and_leaves_it_untouched
    File.write(path, "keep\n")

    assert_raises(Errno::EEXIST) { AtomicFile.create(path, "new\n", mode: 0o644) }
    assert_equal "keep\n", File.read(path)
    assert_empty leftovers
  end

  def test_create_publishes_only_after_the_last_check_passes
    refused = Class.new(StandardError)

    assert_raises(refused) { AtomicFile.create(path, "x\n", mode: 0o644, before_publish: -> { raise refused }) }
    refute_path_exists path
    assert_empty leftovers
    AtomicFile.create(path, "x\n", mode: 0o600)

    assert_equal 0o600, File.stat(path).mode & 0o777
  end

def test_the_temp_file_keeps_the_name_the_staging_reaper_recognizes
  seen = []
  AtomicFile.create(path, "x\n", mode: 0o644, before_publish: -> { seen.concat(leftovers) })

  assert_equal 1, seen.length
  assert_match Tamoz::Tools::StagingReaper::PATTERN, seen.first
end

  def test_a_directory_that_cannot_be_fsynced_is_not_an_error
    assert_nil AtomicFile.fsync_directory(File.join(@dir, 'missing'))
  end
end
