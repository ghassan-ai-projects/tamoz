# frozen_string_literal: true

require_relative 'test_helper'

# tamoz-research is reached only through its facade, and it stays pure. A caller naming an inner constant ties
# itself to the gem's internals, and a file write or socket inside it would put I/O where only rules belong.
class ResearchBoundaryTest < Minitest::Test
  OWNER = 'gems/tamoz-research/'
  # The facade module and its error are the whole public surface.
  INNER_CONSTANT = /Tamoz::Research::(?!Error\b|VERSION\b)[A-Z]/
  IO = /\b(?:File\.(?:write|open|binwrite)|IO\.|Net::|Socket|TCPSocket|Kernel\.(?:system|spawn)|system\(|`|Open3|Dir\.)/
  DATA_LOADER = 'gems/tamoz-research/lib/tamoz/research/budgets.rb'
  ALLOWED_REQUIRES = %w[tamoz/core json uri].freeze

  def test_no_file_outside_the_gem_names_an_inner_constant
    leaks = production_files.reject { |path| path.start_with?(OWNER) }.flat_map { |path| matches(path, INNER_CONSTANT) }

    assert_empty leaks
  end

  def test_the_gem_requires_only_core_and_the_stdlib
    requires = gem_files.flat_map do |path|
      File.read(ROOT.join(path), encoding: Encoding::UTF_8).scan(/^\s*require\s+['"]([^'"]+)['"]/).flatten
    end

    assert_empty requires.uniq - ALLOWED_REQUIRES
  end

  def test_the_gem_does_no_io_outside_its_data_loader
    io = gem_files.flat_map { |path| matches(path, IO) }
    reads = gem_files.reject { |path| path == DATA_LOADER }.flat_map { |path| matches(path, /File\.read/) }

    assert_empty io
    assert_empty reads
  end

  private

  def production_files
    Dir[ROOT.join('{gems/*/lib,gems/*/exe,apps,bin,script,agenteval/lib,agenteval/adapters,agenteval/research}/**/*')
          .to_s]
      .select { |path| File.file?(path) }.map { |path| path.delete_prefix("#{ROOT}/") }
  end

  def gem_files = Dir[ROOT.join(OWNER, 'lib/**/*.rb').to_s].map { |path| path.delete_prefix("#{ROOT}/") }

  def matches(path, pattern)
    File.readlines(ROOT.join(path), encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
      next unless line.valid_encoding? && !line.match?(/\A\s*#/)

      "#{path}:#{index + 1}: #{line.strip}" if line.match?(pattern)
    end
  rescue ArgumentError
    []
  end
end
