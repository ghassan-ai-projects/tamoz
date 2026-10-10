# frozen_string_literal: true

require_relative 'test_helper'

class ChannelDependencyTest < Minitest::Test
  ADAPTERS = %w[tamoz-telegram tamoz-talk].freeze
  REFERENCE = %r{['"]tamoz/(?:telegram|talk)(?:/[^'"]*)?['"]|(?<![\w:])(?:::)?(?:Tamoz::)?(?:Telegram|Talk)::|
                 Tamoz::(?:Telegram|Talk)\b|const_get\(\s*[:'"](?:Tamoz::)?(?:Telegram|Talk)\b}x
  # Lines that load or name an adapter outside it: only the registry's one line per kind.
  EXPECTED = { 'gems/tamoz-agent-cli/lib/tamoz/agent/channel_kinds.rb' => 2 }.freeze

  def test_only_the_registry_loads_or_names_an_adapter
    actual = Dir[ROOT.join('gems/*/lib/**/*.rb')].filter_map do |path|
      relative = Pathname(path).relative_path_from(ROOT).to_s
      next if ADAPTERS.any? { |gem| relative.start_with?("gems/#{gem}/") }

      count = File.readlines(path, encoding: 'UTF-8').count { |line| line.match?(REFERENCE) }
      [relative, count] if count.positive?
    end.to_h

    assert_equal EXPECTED, actual
  end

  def test_no_gem_depends_on_an_adapter
    dependents = Dir[ROOT.join('gems/*/*.gemspec')].filter_map do |path|
      gem = File.basename(path, '.gemspec')
      next if ADAPTERS.include?(gem)

      gem if File.read(path).match?(/['"](?:#{ADAPTERS.join('|')})['"]/o)
    end

    assert_empty dependents
  end
end
