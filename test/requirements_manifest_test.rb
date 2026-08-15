# frozen_string_literal: true

require_relative "test_helper"

# P15-A (docs/P15_RELEASE_PLAN.md §3) — the requirements manifest is the
# machine-readable basis of release status, so the gate protects it:
#
# - it regenerates byte-identically from the authoritative sources (a design
#   document cannot gain an invariant, an ADR, a CLI verb or a migration
#   without the manifest gaining its row);
# - it never claims a passing status (only the audit, which RUNS the tests,
#   may do that);
# - every named test it cites exists and defines the case it names.
#
# The audit itself is NOT run here: it executes 200+ test cases in their own
# processes and belongs to the release gate, not to `rake ci`.
class RequirementsManifestTest < Minitest::Test
  MANIFEST_PATH = ROOT.join("docs", "requirements-manifest.json")
  AUDIT_PATH = ROOT.join("docs", "requirements-audit.json")

  # T8.3: INV-44..51 were the P14 stream engine's invariants; they are
  # retired with it (mirrors the generator's RETIRED_STREAM_CLAUSES).
  RETIRED_STREAM_CLAUSES = (44..51).freeze

  def manifest = @manifest ||= read_json(MANIFEST_PATH)

  def requirements = manifest.fetch("requirements")

  def by_id = @by_id ||= requirements.to_h { |row| [row.fetch("id"), row] }

  def test_manifest_regenerates_from_the_authoritative_sources
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, ROOT.join("script", "generate_requirements_manifest").to_s,
      chdir: ROOT.to_s
    )

    assert status.success?,
           "the committed manifest diverges from a fresh generation:\n#{stderr}#{stdout}"
  end

  # Every invariant clause has a row. A clause cannot be
  # silently dropped from release consideration. T8.3: INV-44..51 are retired
  # with the P14 stream engine (mirrors the generator's RETIRED_STREAM_CLAUSES).
  def test_every_invariant_clause_has_a_row
    expected = (1..61).reject { |number| RETIRED_STREAM_CLAUSES.cover?(number) }
                      .map { |number| format("INV-%02d", number) }

    assert_equal expected, requirements.filter_map { |row|
      row.fetch("id") if row.fetch("category") == "invariant"
    }.sort
  end

  def test_every_accepted_adr_has_a_row
    adr_ids = File.read(
      ROOT.join("docs", "design-v0.1", "DECISIONS.md"), encoding: Encoding::UTF_8
    ).scan(/^### (ADR-\d+) —/).flatten

    refute_empty adr_ids
    assert_equal adr_ids.sort, requirements.filter_map { |row|
      row.fetch("id") if row.fetch("category") == "adr"
    }.sort
  end

  def test_every_cli_subcommand_and_migration_has_a_row
    verbs = Tamoz::Agent::CLI::SUBCOMMANDS.map do |name|
      {"follow_up" => "follow-up", "followup" => "follow-up"}.fetch(name, name)
    end.uniq

    assert_equal verbs.sort, requirements.filter_map { |row|
      row.fetch("id").delete_prefix("CLI-") if row.fetch("category") == "cli_command"
    }.sort

    # MIGRATION_13 is a %w[] literal (T8.3) — both literal styles count.
    ordinals = File.read(
      ROOT.join("gems", "tamoz-sqlite", "lib", "tamoz", "sqlite", "migrator.rb"),
      encoding: Encoding::UTF_8
    ).scan(/^\s*MIGRATION_(\d+)\s*=\s*(?:\[|%w\[)/).flatten.map(&:to_i).sort.uniq

    assert_equal ordinals.map { |ordinal| "MIG-#{ordinal}" }.sort, requirements.filter_map { |row|
      row.fetch("id") if row.fetch("category") == "migration"
    }.sort
  end

  def test_every_public_api_entry_has_a_row
    documented = read_json(ROOT.join("docs", "public-api.json")).fetch("packages")
    expected = documented.flat_map do |package, entries|
      entries.keys.map { |entry| "API-#{package}-#{entry}" }
    end

    assert_equal expected.sort, requirements.filter_map { |row|
      row.fetch("id") if row.fetch("category") == "public_api"
    }.sort
  end

  # The manifest is an input, not a verdict. Only the audit — which runs the
  # named tests — may write a passing status, so a row can never be
  # hand-marked as passing.
  def test_the_manifest_never_claims_a_status
    assert_equal ["unverified"], requirements.map { |row| row.fetch("status") }.uniq
  end

  # Evidence cannot name a test that does not exist. The generator enforces
  # this; the gate makes it non-bypassable.
  def test_every_named_test_exists_and_defines_its_case
    references = requirements.flat_map do |row|
      [row["named_test"], *row.fetch("supporting_tests", [])].compact
    end.uniq

    refute_empty references
    references.each do |reference|
      file, _separator, case_name = reference.partition("#")

      refute_empty case_name, "#{reference} must name a case"
      path = ROOT.join(file)

      assert_path_exists path
      assert_includes File.read(path, encoding: Encoding::UTF_8), "def #{case_name}",
                      "#{file} does not define #{case_name}"
    end
  end

  # A release-blocking row carries direct evidence, or names the gap. Two kinds
  # of gap are legitimate while the phase runs: one the owner must decide
  # (`pending-owner-residual`) and one a named work package will close
  # (`missing` with a rationale). `indirect` never carries a release-blocking
  # row — "no direct proof is available" cannot be a release position.
  def test_release_blocking_rows_are_direct_or_name_their_gap
    requirements.each do |row|
      next unless row.fetch("release_blocking")

      classification = row.fetch("classification")

      assert_includes %w[direct pending-owner-residual missing], classification,
                      "#{row.fetch("id")} is release-blocking with classification " \
                      "#{classification.inspect}"
      next if classification == "direct"

      refute_nil row["rationale"],
                 "#{row.fetch("id")} must state the exact gap and what closes it"
    end
  end

  # The deferred set is enumerated by the invariants document itself, never
  # free-form (plan §3, correction 2).
  def test_deferred_clauses_match_the_invariants_document
    matrix = manifest.fetch("promotion_matrix")

    assert_equal %w[INV-29 INV-30 INV-31 INV-41 INV-42 INV-43], matrix.fetch("deferred_v0_2")
    assert_equal %w[INV-28 INV-32 INV-33 INV-34], matrix.fetch("deferred_v0_3")
    matrix.fetch("deferred_v0_2").concat(matrix.fetch("deferred_v0_3")).each do |id|
      refute by_id.fetch(id).fetch("release_blocking"),
             "#{id} is deferred by the invariants document and cannot be release-blocking"
    end
  end

  # A promoted optional package makes its conditional clauses release-blocking:
  # a shipped feature never dodges the clauses it is supposed to satisfy.
  def test_promoted_packages_make_their_conditional_clauses_release_blocking
    matrix = manifest.fetch("promotion_matrix")
    promoted = matrix.fetch("promoted_packages")

    assert_equal %w[tamoz-mcp tamoz-scheduler tamoz-stream], promoted
    promoted.each do |package|
      matrix.fetch("conditional_clauses").fetch(package).each do |id|
        # T8.3: the retired stream clauses (INV-44..51) are no longer rows.
        next if id.match?(/\AINV-(4[4-9]|5[01])\z/)

        assert by_id.fetch(id).fetch("release_blocking"),
               "#{package} ships, so #{id} must be release-blocking"
      end
    end
  end

  # The committed audit must describe the committed manifest. A manifest row
  # added without regenerating the audit would otherwise leave a requirement
  # with no recorded verdict at all.
  def test_the_committed_audit_covers_every_manifest_row
    audit = read_json(AUDIT_PATH)

    assert_equal requirements.map { |row| row.fetch("id") }.sort,
                 audit.fetch("requirements").map { |row| row.fetch("id") }.sort
    audit.fetch("requirements").each do |row|
      refute_equal "unverified", row.fetch("status"),
                   "#{row.fetch("id")} has no audited status"
    end
  end
end
