# frozen_string_literal: true

require_relative "test_helper"

# The public documentation tree is a checked surface, like the CLI and the
# limitations page. A documentation set nobody can navigate is worse than no
# documentation: broken relative links strand a reader mid-path, and a file
# that is not reachable from the index might as well not exist.
#
# So this test proves four properties of the curated set:
#   1. every relative link in `documentation/**` and the root README resolves
#      to a real file (or to an existing directory's README);
#   2. every `.md` file under `documentation/` is reachable from the index
#      `documentation/README.md` by following relative links (no orphans);
#   3. the root README points at the documentation index;
#   4. `docs/README.md` still marks that directory as the internal archive.
class DocumentationTreeTest < Minitest::Test
  DOC_ROOT = ROOT.join("documentation")
  INDEX = DOC_ROOT.join("README.md")
  README = ROOT.join("README.md")
  ARCHIVE_MARKER = ROOT.join("docs", "README.md")

  # Root-level pages are part of the public surface too: their links must
  # resolve and they must stay free of internal-environment leaks.
  ROOT_MD = [
    ROOT.join("README.md"),
    ROOT.join("CONTRIBUTING.md"),
    ROOT.join("SECURITY.md"),
    ROOT.join("SUPPORT.md"),
    ROOT.join("CHANGELOG.md"),
    ROOT.join("CODE_OF_CONDUCT.md")
  ].freeze

  # Internal-environment leakage that must never appear in public docs.
  # `~/.tamoz` is public surface (the operator runtime directory) and is fine.
  # The patterns match filesystem-style paths (`~/ai-projects/...`,
  # `/Users/...`), not the `ghassan-ai-projects` GitHub org name that legitimately
  # appears in clone URLs; only private-address ranges count as IP leaks, so
  # loopback examples like 127.0.0.1 remain legal in public docs.
  INTERNAL_PATTERNS = [
    %r{/Users/},
    %r{/home/},
    %r{[/~]ai-projects},
    %r{[/~]external-projects},
    %r{data-machine},
    %r{\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b},
    %r{\b192\.168\.\d{1,3}\.\d{1,3}\b},
    %r{\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b}
  ].freeze

  def text(path) = File.read(path, encoding: Encoding::UTF_8)

  def md_files_under(dir)
    Dir[dir.join("**", "*.md")].sort.map { |path| Pathname.new(path) }
  end

  # Strip fenced code blocks so command examples cannot masquerade as links.
  def link_targets(body)
    body.gsub(/```.*?```|~~~.*?~~~/m, "")
        .scan(/\[[^\]]*\]\(([^)]+)\)/)
        .flatten
        .map { |target| target.split(/["']/, 2).first.to_s.strip }
        .reject { |target| target.empty? || target.start_with?("#", "http://", "https://", "mailto:") }
        .map { |target| target.sub(/#.*\z/, "") }
        .reject(&:empty?)
        .uniq
  end

  def resolve(path, target)
    if target.end_with?("/")
      path.dirname.join(target, "README.md")
    else
      path.dirname.join(target)
    end
  end

  def test_the_index_and_archive_marker_exist
    assert_path_exists INDEX
    assert_path_exists ARCHIVE_MARKER
    assert_includes text(ARCHIVE_MARKER), "documentation",
                    "docs/README.md must mark the directory as the internal archive " \
                    "and point at the public set"
  end

  def test_every_relative_link_resolves
    (md_files_under(DOC_ROOT) + ROOT_MD).each do |path|
      link_targets(text(path)).each do |target|
        resolved = resolve(path, target)
        assert_path_exists resolved,
                           "#{path.relative_path_from(ROOT)} links to #{target.inspect} " \
                           "but #{resolved.relative_path_from(ROOT)} does not exist"
      end
    end
  end

  def test_every_documentation_file_is_reachable_from_the_index
    reachable = Set.new([INDEX])
    frontier = [INDEX]
    until frontier.empty?
      current = frontier.shift
      link_targets(text(current)).each do |target|
        resolved = resolve(current, target)
        next unless resolved.extname == ".md" && resolved.to_s.start_with?(DOC_ROOT.to_s)
        next if reachable.include?(resolved)

        reachable << resolved
        frontier << resolved
      end
    end

    orphans = md_files_under(DOC_ROOT) - reachable.to_a.sort
    assert_empty orphans,
                 "documentation files not reachable from documentation/README.md: " \
                 "#{orphans.map { |p| p.relative_path_from(DOC_ROOT) }.join(", ")}"
  end

  def test_the_root_readme_points_at_the_documentation_index
    assert_includes text(README), "documentation/README.md",
                    "the root README must link the public documentation index"
  end

  def test_public_docs_contain_no_internal_environment_leaks
    (md_files_under(DOC_ROOT) + ROOT_MD).each do |path|
      body = text(path)
      INTERNAL_PATTERNS.each do |pattern|
        refute_match pattern, body,
                     "#{path.relative_path_from(ROOT)} leaks an internal path/address " \
                     "(#{pattern.inspect})"
      end
    end
  end

  def test_documentation_files_are_substantive
    # A title-only stub passes the link and reachability checks; it must not
    # pass the documentation bar. Every page needs a heading and real content.
    md_files_under(DOC_ROOT).each do |path|
      body = text(path)
      assert_match %r{\A# }, body,
                   "#{path.relative_path_from(DOC_ROOT)} has no H1 heading"
      assert_operator body.length, :>=, 200,
                      "#{path.relative_path_from(DOC_ROOT)} looks like a stub " \
                      "(#{body.length} characters)"
    end
  end

  def test_consistency_pins_hold
    # Cross-page numbers the reviewers of the release pinned; if the product
    # legitimately moves past them, update these pins with the change.
    assert_includes text(DOC_ROOT.join("design", "README.md")), "61-clause"
    assert_includes text(DOC_ROOT.join("architecture", "invariants.md")), "61"
    assert_includes text(DOC_ROOT.join("overview", "compatibility.md")), "61"
    assert_includes text(DOC_ROOT.join("operations", "operations.md")), "thirteen"
    assert_includes text(DOC_ROOT.join("architecture", "data-model.md")), "13 checksummed"
  end
end
