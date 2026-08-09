# frozen_string_literal: true

require_relative "test_helper"

# P15-D — the dependency, licence and provenance review is a GATE, not a
# snapshot. Supply-chain facts that are only true on the day someone writes
# them down are not facts a release can rest on.
class DependencyReviewTest < Minitest::Test
  REPORT = ROOT.join("docs", "dependency-review.json")
  MARKDOWN = ROOT.join("docs", "DEPENDENCY_REVIEW.md")

  def report = @report ||= read_json(REPORT)

  def test_the_review_regenerates_from_the_gemspecs_and_the_lockfile
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-S", "bundle", "exec", "ruby",
      ROOT.join("script", "generate_dependency_review").to_s,
      chdir: ROOT.to_s
    )

    assert status.success?, "#{stdout}#{stderr}"
    dirty = Open3.capture2(
      "git", "status", "--porcelain", "docs/dependency-review.json",
      "docs/DEPENDENCY_REVIEW.md", chdir: ROOT.to_s
    ).first.lines.reject { |line| line.start_with?("A ", "??") }.join
    diff = dirty.empty? ? "" : Open3.capture2("git", "diff", "--", "docs/", chdir: ROOT.to_s).first

    assert_empty dirty,
                 "the committed dependency review is out of date; regenerate it\n#{diff}"
  end

  # No copyleft dependency may enter a production process without an explicit
  # owner decision. This is the assertion that turns that from an intention
  # into a gate.
  def test_no_runtime_dependency_carries_a_non_permissive_licence
    allowed = report.fetch("permissive_licenses")
    offenders = report.fetch("runtime").reject do |row|
      row.fetch("licenses").all? { |license| allowed.include?(license) }
    end

    assert_empty offenders.map { |row| [row.fetch("name"), row.fetch("licenses")] },
                 "a runtime dependency has a licence outside the permissive allowlist"
    assert_empty report.fetch("license_violations")
  end

  # An UNDECLARED licence is worse than a wrong one: nobody can review what a
  # gem does not state.
  def test_every_runtime_dependency_declares_a_licence
    undeclared = report.fetch("runtime").select do |row|
      row.fetch("licenses").include?("UNDECLARED")
    end

    assert_empty undeclared.map { |row| row.fetch("name") }
  end

  # The runtime closure must match what the gemspecs actually declare — this is
  # what stops the report describing a dependency graph the product does not
  # have.
  def test_the_direct_runtime_dependencies_match_the_gemspecs
    declared = GEM_ROOTS.keys.flat_map do |name|
      path = ROOT.join("gems", name, "#{name}.gemspec")
      spec = Dir.chdir(File.dirname(path)) { Gem::Specification.load(path.to_s) }
      spec.dependencies.select { |dep| dep.type == :runtime }
          .map(&:name).reject { |dep| dep.start_with?("tamoz-") }
    end.uniq.sort

    reported = report.fetch("runtime").select { |row| row.fetch("direct") }
                     .map { |row| row.fetch("name") }.sort

    assert_equal declared, reported
  end

  # Development gems must never appear in the runtime closure. `minitest` and
  # `rake` reaching a production process would be a real finding.
  def test_development_gems_are_not_in_the_runtime_closure
    runtime = report.fetch("runtime").map { |row| row.fetch("name") }

    %w[minitest rake].each do |name|
      refute_includes runtime, name, "#{name} must never ship"
    end
  end

  def test_the_published_report_states_the_provenance_controls
    body = File.read(MARKDOWN, encoding: Encoding::UTF_8)

    assert_includes body, "rubygems_mfa_required"
    assert_includes body, "Tamoz fetches no code at runtime"
  end

  # …and that last claim must still be TRUE. A gem-install or plugin-load path
  # appearing in production code would make the provenance statement a lie.
  def test_no_production_code_installs_or_loads_code_at_runtime
    offenders = Dir[ROOT.join("gems", "*", "lib", "**", "*.rb")].select do |path|
      source = File.read(path, encoding: Encoding::UTF_8)
      source.match?(/Gem::Installer|Gem::DependencyInstaller|\bgem\s+install\b/) ||
        source.match?(/Kernel\.load\(|^\s*load\s+["']/)
    end

    assert_empty offenders,
                 "production code must not install or load code at runtime"
  end
end
