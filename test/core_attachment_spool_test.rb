# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class CoreAttachmentSpoolTest < Minitest::Test
  NAME = 'a' * 64

  def with_spool
    Dir.mktmpdir { |root| yield Tamoz::Core::AttachmentSpool.new(File.join(root, 'attachments')), root }
  end

  def test_a_handoff_is_private_read_back_exactly_and_gone_once_deleted
    with_spool do |spool, root|
      bytes = "%PDF-1.4\x00\xFF".b
      digest = spool.put(NAME, bytes)

      assert_equal bytes, spool.read(NAME, digest:)
      assert_equal 0o700, File.stat(File.join(root, 'attachments')).mode & 0o777
      assert_equal 0o600, File.stat(File.join(root, 'attachments', NAME)).mode & 0o777
      spool.delete(NAME)

      assert_nil spool.read(NAME, digest:)
      assert_empty Dir.children(File.join(root, 'attachments'))
    end
  end

  def test_bytes_that_no_longer_match_their_digest_are_refused
    with_spool do |spool, root|
      digest = spool.put(NAME, 'original')
      File.binwrite(File.join(root, 'attachments', NAME), 'tampered')

      assert_raises(Tamoz::ConfigurationError) { spool.read(NAME, digest:) }
    end
  end

  def test_a_name_cannot_leave_the_folder
    with_spool do |spool, _root|
      assert_raises(Tamoz::ConfigurationError) { spool.put('../escape', 'x') }
    end
  end

  def test_a_sweep_removes_only_what_waited_too_long
    with_spool do |spool, root|
      spool.put(NAME, 'old')
      spool.put('b' * 64, 'new')
      File.utime(Time.now - 90_000, Time.now - 90_000, File.join(root, 'attachments', NAME))

      spool.sweep(older_than: 86_400)

      assert_equal ['b' * 64], Dir.children(File.join(root, 'attachments'))
    end
  end
end
