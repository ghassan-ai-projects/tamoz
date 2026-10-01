# frozen_string_literal: true

require_relative 'test_helper'

# Tamoz::Core::AtomicFile is the one place a gem stages a temp file and renames or links it into place.
# A second hand-rolled copy drifts from its fsync and mode guarantees.
class AtomicFileBoundaryTest < Minitest::Test
  STAGING = /\bFile\.(?:rename|link)\b|\bTempfile\.|\bFileUtils\.(?:mv|move)\b/
  OWNER = 'gems/tamoz-core/lib/tamoz/core/atomic_file.rb'
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

  def test_every_exception_still_needs_its_exemption
    stale = EXCEPTIONS.keys.reject { |relative| File.read(File.join(ROOT, relative)).match?(STAGING) }

    assert_empty stale
  end
end
