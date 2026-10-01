# frozen_string_literal: true

require_relative 'test_helper'

# Tamoz::Core::AtomicFile is the one place a gem stages a temp file and renames or links it into place.
# A second hand-rolled copy drifts from its fsync and mode guarantees.
class AtomicFileBoundaryTest < Minitest::Test
  STAGING = /\bFile\.(?:rename|link)\b|\bTempfile\.|\bFileUtils\.(?:mv|move)\b/
  OWNER = 'gems/tamoz-core/lib/tamoz/core/atomic_file.rb'
  OWNER_DIRECTORY = 'gems/tamoz-core/lib/tamoz/core/private_directory.rb'
  OWNER_ONLY = /\bFile\.chmod\(0o700\b/
  DIRECTORY_EXCEPTIONS = %w[
    gems/tamoz-sqlite/
    gems/tamoz-evals-runner/lib/tamoz/evals/harness/sqlite_selector_control.rb
  ].freeze
  EXCEPTIONS = {
    'gems/tamoz-sqlite/lib/tamoz/sqlite/backup.rb' => 'SQLite streams the backup into its own staged file',
    'gems/tamoz-observability/lib/tamoz/observability/recorder_journal.rb' => 'log rotation renames, never replaces',
    'gems/tamoz-agent-cli/lib/tamoz/agent/skill_installation.rb' => 'a directory swap, guarded by a tree digest'
  }.freeze

  def test_no_gem_stages_and_renames_a_file_outside_atomic_file
    leaks = Dir[File.join(ROOT, 'gems/*/lib/**/*.rb')].flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      next [] if relative == OWNER || EXCEPTIONS.key?(relative)

      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(STAGING)
      end
    end

    assert_empty leaks
  end

  def test_no_gem_hand_rolls_an_owner_only_directory
    leaks = Dir[File.join(ROOT, 'gems/*/lib/**/*.rb')].flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      next [] if relative == OWNER_DIRECTORY || DIRECTORY_EXCEPTIONS.any? { |exempt| relative.start_with?(exempt) }

      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if line.match?(OWNER_ONLY)
      end
    end

    assert_empty leaks
  end

  def test_every_exception_still_needs_its_exemption
    stale = EXCEPTIONS.keys.reject { |relative| File.read(File.join(ROOT, relative)).match?(STAGING) }

    assert_empty stale
  end
end
