# frozen_string_literal: true

require_relative 'test_helper'

class CorePrivateDirectoryTest < Minitest::Test
  PrivateDirectory = Tamoz::Core::PrivateDirectory

  def setup = @dir = Dir.mktmpdir('tamoz-private')
  def teardown = FileUtils.remove_entry(@dir)

  def mode(path) = File.stat(path).mode & 0o777

  def test_a_new_directory_is_owner_only_and_its_missing_parents_are_created
    path = File.join(@dir, 'a', 'b')

    PrivateDirectory.secure(path)

    assert_equal 0o700, mode(path)
  end

  def test_an_existing_directory_with_looser_bits_is_tightened
    path = File.join(@dir, 'loose')
    Dir.mkdir(path, 0o755)
    PrivateDirectory.secure(path)

    assert_equal 0o700, mode(path)
  end
end
