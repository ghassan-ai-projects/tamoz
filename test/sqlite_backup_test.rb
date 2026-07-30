# frozen_string_literal: true

require_relative "test_helper"

class SQLiteBackupTest < Minitest::Test
  def test_online_backup_is_secure_consistent_and_reopenable
    Dir.mktmpdir("tamoz-backup") do |directory|
      source = File.join(directory, "source.sqlite3")
      destination = File.join(directory, "backup.sqlite3")
      adapter = Tamoz::SQLite::Adapter.new(path: source)
      adapter.store.put("memory", "answer", {"value" => 42})

      report = adapter.backup(destination)
      assert_equal destination, report.destination
      assert_operator report.pages, :>, 0
      assert_operator report.bytes, :>, 0
      assert_equal 0, File.stat(destination).mode & 0o077

      restored = Tamoz::SQLite::Adapter.new(path: destination)
      assert_equal(
        {"value" => 42},
        restored.store.get("memory", "answer").value
      )
      assert restored.integrity_check.fetch("ok")
    ensure
      restored&.close
      adapter&.close
    end
  end

  def test_backup_never_implicitly_overwrites_or_follows_symlinks
    Dir.mktmpdir("tamoz-backup") do |directory|
      source = File.join(directory, "source.sqlite3")
      destination = File.join(directory, "backup.sqlite3")
      adapter = Tamoz::SQLite::Adapter.new(path: source)
      File.write(destination, "keep")

      assert_raises(Tamoz::SQLite::PermissionError) do
        adapter.backup(destination)
      end
      assert_equal "keep", File.read(destination)

      File.delete(destination)
      target = File.join(directory, "target")
      File.write(target, "keep")
      File.symlink(target, destination)
      assert_raises(Tamoz::SQLite::PermissionError) do
        adapter.backup(destination)
      end
      assert_equal "keep", File.read(target)
    ensure
      adapter&.close
    end
  end

  def test_failure_before_publication_leaves_no_destination_or_temporary_file
    Dir.mktmpdir("tamoz-backup") do |directory|
      source = File.join(directory, "source.sqlite3")
      destination = File.join(directory, "backup.sqlite3")
      injector = lambda do |point, _metadata|
        raise "injected backup failure" if point == :before_backup_publish
      end
      adapter = Tamoz::SQLite::Adapter.new(path: source, fault_injector: injector)

      assert_raises(RuntimeError) { adapter.backup(destination) }
      refute File.exist?(destination)
      assert_empty Dir.children(directory).grep(/\\.tmp\\z/)
    ensure
      adapter&.close
    end
  end
end
