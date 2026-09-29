# frozen_string_literal: true

require_relative 'test_helper'

# Memory's storage and scope rules stay inside tamoz-agent-memory (and its SQLite store):
# every other gem goes through Memory::Engine#access or the published services. A leak
# here means two places deciding what a record is or who may see it.
class MemoryBoundaryTest < Minitest::Test
  INTERNALS = [
    /\b(?:engine|memory)\.(?:repository|store|index_for|namespace)\b/,
    /Memory::(?:Surface\.project_scope|ExperienceGroups|Access\.new)/,
    /tamoz_memory_(?:index|fts)/,
    %r{["'](?:knowledge|experience)/}
  ].freeze
  OWNERS = %w[gems/tamoz-agent-memory/ gems/tamoz-sqlite/].freeze
  # The DR-3 harness seeds fixture records below the admission policy on purpose.
  SEEDERS = %w[gems/tamoz-evals-runner/lib/tamoz/evals/harness/memory_repository_adapter.rb].freeze

  def test_no_gem_outside_memory_reaches_into_its_storage_or_scopes
    leaks = Dir[File.join(ROOT, 'gems/*/lib/**/*.rb')].flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      next [] if OWNERS.any? { |owner| relative.start_with?(owner) } || SEEDERS.include?(relative)

      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if INTERNALS.any? { |pattern| line.match?(pattern) }
      end
    end

    assert_empty leaks
  end
end
