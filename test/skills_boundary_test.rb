# frozen_string_literal: true

require_relative 'test_helper'

# tamoz-skills is reached only through its facade: the Tamoz::Skills functions and its value types.
class SkillsBoundaryTest < Minitest::Test
  OWNER = 'gems/tamoz-skills/'
  INNER_CONSTANT = /Tamoz::Skills::(?:Compiler|Walk|Frontmatter|FrontmatterScanner|Rejected)\b/
  ALLOWED_REQUIRES = %w[digest fileutils json psych time tamoz/core].freeze

  def test_no_file_outside_the_gem_names_an_inner_constant
    leaks = (production_files + test_files).reject { |path| path.start_with?(OWNER) }
                                           .flat_map { |path| matches(path, INNER_CONSTANT) }

    assert_empty leaks
  end

  def test_the_inner_constants_are_private
    public_names = Tamoz::Skills.constants

    %i[Compiler Walk Frontmatter FrontmatterScanner Rejected].each { |name| refute_includes public_names, name }
  end

  def test_the_gem_requires_only_core_and_the_stdlib
    requires = gem_files.flat_map do |path|
      File.read(ROOT.join(path), encoding: Encoding::UTF_8).scan(/^\s*require\s+['"]([^'"]+)['"]/).flatten
    end

    assert_empty requires.uniq - ALLOWED_REQUIRES
  end

  def test_every_gem_that_names_the_facade_declares_it
    GEM_ROOTS.each do |name, root|
      next if name == 'tamoz-skills'

      named = files("gems/#{name}/lib/**/*.rb").any? { |path| matches(path, /Tamoz::Skills\b/).any? }
      next unless named

      spec = Gem::Specification.load(root.join("#{name}.gemspec").to_s)

      assert_includes spec.runtime_dependencies.map(&:name), 'tamoz-skills', name
    end
  end

  private

  def production_files = files('{gems/*/lib,gems/*/exe,apps,bin,script,agenteval/lib,agenteval/adapters}/**/*')
  def test_files = files('test/**/*.rb')
  def gem_files = files("#{OWNER}lib/**/*.rb")

  def files(pattern)
    Dir[ROOT.join(pattern).to_s].select { |path| File.file?(path) }.map { |path| path.delete_prefix("#{ROOT}/") }
  end

  def matches(path, pattern)
    File.readlines(ROOT.join(path), encoding: Encoding::UTF_8).each_with_index.filter_map do |line, index|
      next unless line.valid_encoding? && !line.match?(/\A\s*#/)

      "#{path}:#{index + 1}: #{line.strip}" if line.match?(pattern)
    end
  rescue ArgumentError
    []
  end
end
