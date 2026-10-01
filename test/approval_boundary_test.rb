# frozen_string_literal: true

require_relative 'test_helper'

class ApprovalBoundaryTest < Minitest::Test
  INTERNALS = [/\.(?:decision_log|grant_store)\b/].freeze
  OWNERS = %w[gems/tamoz-approval/ gems/tamoz-sqlite/].freeze
  EXEMPT = %w[gems/tamoz-agent/lib/tamoz/agent/worker.rb].freeze

  def test_no_gem_outside_approval_reads_its_stores
    leaks = Dir[File.join(ROOT, 'gems/*/lib/**/*.rb')].flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      next [] if OWNERS.any? { |owner| relative.start_with?(owner) } || EXEMPT.include?(relative)

      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if INTERNALS.any? { |pattern| line.match?(pattern) }
      end
    end

    assert_empty leaks
  end
end
