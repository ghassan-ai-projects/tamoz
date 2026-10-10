# frozen_string_literal: true

require_relative 'test_helper'

class ChannelDependencyTest < Minitest::Test
  KINDS = Tamoz::Agent::CHANNEL_KINDS.values
  ADAPTERS = KINDS.map { |kind| kind.library.tr('/', '-') }.freeze
  LIBRARIES = KINDS.map { |kind| Regexp.escape(kind.library) }.join('|')
  MODULES = KINDS.map { |kind| kind.namespace.delete_prefix('Tamoz::') }.join('|')
  REFERENCE = %r{['"](?:#{LIBRARIES})(?:/[^'"]*)?['"]|(?<![\w:])(?:::)?(?:Tamoz::)?(?:#{MODULES})::|
                 Tamoz::(?:#{MODULES})\b|const_get\(\s*[:'"](?:Tamoz::)?(?:#{MODULES})\b}x
  # Lines that load or name an adapter outside it: only the registry's one line per kind.
  EXPECTED = { 'gems/tamoz-agent-cli/lib/tamoz/agent/channel_kinds.rb' => KINDS.length }.freeze

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
