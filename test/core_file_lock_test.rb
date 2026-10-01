# frozen_string_literal: true

require_relative 'test_helper'

class CoreFileLockTest < Minitest::Test
  FileLock = Tamoz::Core::FileLock

  def setup = @dir = Dir.mktmpdir('tamoz-lock')
  def teardown = FileUtils.remove_entry(@dir)

  def path = File.join(@dir, 'registry.lock')

  def blocked?
    File.open(path) { |other| !other.flock(File::LOCK_EX | File::LOCK_NB) }
  end

  def test_the_lock_is_held_inside_the_block_and_released_after_it
    inside = FileLock.exclusive(path) { blocked? }

    assert inside
    refute_predicate self, :blocked?
  end

  def test_the_lock_is_released_when_the_block_raises
    assert_raises(ArgumentError) { FileLock.exclusive(path) { raise ArgumentError } }
    refute_predicate self, :blocked?
  end

  def test_the_lock_file_is_owner_only
    FileLock.exclusive(path) { nil }

    assert_equal 0o600, File.stat(path).mode & 0o777
  end

  def test_the_block_value_is_returned
    assert_equal :done, FileLock.exclusive(path) { :done }
  end
end
