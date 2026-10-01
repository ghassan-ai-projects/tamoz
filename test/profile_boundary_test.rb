# frozen_string_literal: true

require_relative 'test_helper'

class ProfileBoundaryTest < Minitest::Test
  INTERNALS = [/\bProfile::[A-Z_]{2,}\b/].freeze
  OWNERS = %w[gems/tamoz-agent-profile/].freeze

  def test_no_gem_outside_profile_reads_its_policy_constants
    leaks = Dir[File.join(ROOT, 'gems/*/lib/**/*.rb')].flat_map do |path|
      relative = path.delete_prefix("#{ROOT}/")
      next [] if OWNERS.any? { |owner| relative.start_with?(owner) }

      File.readlines(path, encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
        "#{relative}:#{index + 1}: #{line.strip}" if INTERNALS.any? { |pattern| line.match?(pattern) }
      end
    end

    assert_empty leaks
  end
end
