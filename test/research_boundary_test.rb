# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/source_boundary_audit'

# tamoz-research is reached only through its facade, and it stays pure. A caller naming an inner constant ties
# itself to the gem's internals, and a file write or socket inside it would put I/O where only rules belong.
class ResearchBoundaryTest < Minitest::Test
  include SourceBoundaryAudit

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
end
