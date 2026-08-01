# frozen_string_literal: true

require_relative "test_helper"

class DocumentationTest < Minitest::Test
  MARKDOWN_LINK = /\[[^\]]+\]\(([^)]+)\)/

  def test_local_markdown_links_resolve
    markdown_files.each do |path|
      text = path.read(encoding: Encoding::UTF_8)
      text.scan(MARKDOWN_LINK).flatten.each do |target|
        next if target.start_with?("http://", "https://", "#", "mailto:")

        relative = target.split("#", 2).first
        next if relative.nil? || relative.empty?

        assert path.dirname.join(relative).exist?, "#{path}: broken local link #{target}"
      end
    end
  end

  def test_design_source_and_contract_counts_are_pinned
    source = ROOT.join("docs", "design-v0.1", "SOURCE").read(encoding: Encoding::UTF_8)
    invariants = ROOT.join("docs", "design-v0.1", "INVARIANTS.md").read(encoding: Encoding::UTF_8)
    decisions = ROOT.join("docs", "design-v0.1", "DECISIONS.md").read(encoding: Encoding::UTF_8)

    assert_includes source, "source_commit=c123605"
    assert_equal (1..55).to_a,
                 invariants.scan(/^\| (\d+) \| \*\*/).flatten.map(&:to_i)
    assert_equal (1..40).to_a,
                 decisions.scan(/^### ADR-(\d{3}) /).flatten.map(&:to_i)
  end

  def test_design_validation_passes_without_a_utf8_locale
    stdout, stderr, status = Open3.capture3(
      {"LC_ALL" => "C", "LANG" => "C"},
      RbConfig.ruby,
      ROOT.join("docs", "design-v0.1", "validate_design.rb").to_s
    )

    assert status.success?, "#{stdout}\n#{stderr}"
    assert_match(/\Adesign validation passed \(\d+ documents, 55 invariants, 40 ADRs\)\n\z/, stdout)
  end

  private

  def markdown_files
    ROOT.glob("**/*.md").reject do |path|
      path.each_filename.any? { |part| %w[.git vendor tmp].include?(part) }
    end
  end
end
