# frozen_string_literal: true

require_relative 'test_helper'

# Atomic writes, owner-only directories and flock live in tamoz-core's facades; a second hand-rolled copy
# drifts from their fsync, mode and release guarantees.
class FileFacadesBoundaryTest < Minitest::Test
  CORE = 'gems/tamoz-core/lib/tamoz/core'
  STAGING = /\bFile\.(?:rename|link)\b|\bTempfile\.|\bFileUtils\.(?:mv|move)\b/
  PRIVATE_DIRECTORY = /\bFile\.chmod\(0o700\b/
  LOCK = /\.flock\(/
  STAGING_EXCEPTIONS = {
    'gems/tamoz-sqlite/lib/tamoz/sqlite/backup.rb' => 'SQLite streams the backup into its own staged file',
    'gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb' => 'log rotation renames, never replaces',
    'gems/tamoz-agent-cli/lib/tamoz/agent/skill_installation.rb' => 'a directory swap, guarded by a tree digest'
  }.freeze
  DIRECTORY_EXCEPTIONS = %w[
    gems/tamoz-sqlite/
    gems/tamoz-evals-runner/lib/tamoz/evals/harness/sqlite_selector_control.rb
  ].freeze

  def test_no_gem_stages_and_renames_a_file_outside_atomic_file
    assert_empty leaks(STAGING, ["#{CORE}/atomic_file.rb", *STAGING_EXCEPTIONS.keys])
  end

  def test_no_gem_hand_rolls_an_owner_only_directory
    assert_empty leaks(PRIVATE_DIRECTORY, ["#{CORE}/private_directory.rb", *DIRECTORY_EXCEPTIONS])
  end

  def test_no_gem_locks_a_file_outside_file_lock
    assert_empty leaks(LOCK, ["#{CORE}/file_lock.rb"])
  end

  def test_every_staging_exception_still_needs_its_exemption
    stale = STAGING_EXCEPTIONS.keys.reject { |relative| File.read(File.join(ROOT, relative)).match?(STAGING) }

    assert_empty stale
  end

  private

  def leaks(pattern, owners)
    Dir[File.join(ROOT, 'gems/*/lib/**/*.rb')].flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      next [] if owners.any? { |owner| relative.start_with?(owner) }

      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(pattern)
      end
    end
  end
end
