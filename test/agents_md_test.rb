# frozen_string_literal: true

require_relative 'test_helper'

# AGENTS.md is loaded into every agent session: it stays small and names only what exists.
class AgentsMdTest < Minitest::Test
  TEXT = ROOT.join('AGENTS.md').read(encoding: Encoding::UTF_8)
  MAX_LINES = 150
  SEAM = /`(?:\w+::)*([A-Z][a-z]\w*)(?:[#.](\w+))?`/
  PATH = %r{`([\w.-]+/[\w.*/-]+)`}

  def test_stays_within_its_context_budget
    assert_operator TEXT.lines.length, :<=, MAX_LINES
  end

  def test_every_link_and_named_path_exists
    named = TEXT.scan(/\]\(([^)]+)\)/).flatten + TEXT.scan(PATH).flatten
    missing = named.reject { |path| ROOT.glob(path).any? }

    assert_empty missing
  end

  def test_every_named_class_and_method_exists
    sources = ROOT.glob('gems/*/lib/**/*.rb').map { |path| path.read(encoding: Encoding::UTF_8) }
    missing = TEXT.scan(SEAM).reject do |owner, method|
      sources.any? do |source|
        source.match?(/\b(?:class|module) (?:\w+::)*#{owner}\b/) &&
          (method.nil? || source.match?(/\bdef (?:self\.)?#{method}\b/))
      end
    end

    assert_empty missing
  end
end
