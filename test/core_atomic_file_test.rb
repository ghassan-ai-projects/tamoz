# frozen_string_literal: true

require_relative 'test_helper'

# No temp file outlives a write, whatever stops it.
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

  def test_create_publishes_nothing_when_the_last_check_refuses
    refused = Class.new(StandardError)

    assert_raises(refused) { AtomicFile.create(path, "x\n", mode: 0o644, before_publish: -> { raise refused }) }
    refute_path_exists path
    assert_empty leftovers
  end

  def test_create_sets_the_mode
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

  def test_an_interrupt_mid_write_leaves_no_temp_file
    interrupting = Object.new
    def interrupting.to_s = raise(Interrupt)

    assert_raises(Interrupt) { AtomicFile.replace(path, interrupting) }
    assert_raises(Interrupt) { AtomicFile.create(path('new.txt'), interrupting, mode: 0o644) }
    assert_empty leftovers
  end

  def test_a_failed_rename_leaves_no_temp_file
    FileUtils.mkdir_p(File.join(path, 'occupied'))

    assert_raises(SystemCallError) { AtomicFile.replace(path, "x\n") }
    assert_empty leftovers
  end
end
