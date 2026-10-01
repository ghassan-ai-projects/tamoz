# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../script/adr_validate'
require_relative '../script/adr_verify'

class AdrToolingTest < Minitest::Test
  BODY_C = <<~MD
    ## Context

    Forces.

    ## Decision

    The rule.

    ## Consequences

    **Cost:** some.

    ## Rejected alternatives

    | Rejected | Why it lost |
    |---|---|
    | Other | Worse |

    ## Reopen when

    Never.

    ## Verification

    Checked 2026-10-01.
  MD

  def adr(num, title: 'A rule holds', tier: 'C', extra: '', body: BODY_C)
    <<~MD
      # ADR-#{num} — #{title}

      **Status:** Accepted 2026-10-01
      **Date:** 2026-10-01
      **Tier:** #{tier}
      **Implementation:** Complete
      #{extra}
      One sentence.

      #{body}
    MD
  end

  def with_corpus(files)
    Dir.mktmpdir do |dir|
      { 'RETIRED.md' => "| **000** |\n", 'README.md' => index(files) }.merge(files).each do |name, text|
        File.write(File.join(dir, name), text)
      end
      File.write(AdrCatalog.path(dir), AdrCatalog.json(dir))
      yield dir
    end
  end

  def index(files)
    files.keys.filter_map { |name| name[/\Aadr-(\d{3})-/, 1] }.uniq.map { |num| "| [#{num}](./README.md) | x |\n" }.join
  end

  def problems_in(files) = with_corpus(files) { |dir| AdrValidate.run(dir) }

  def test_a_minimal_valid_record_passes
    assert_empty problems_in('adr-001-a.md' => adr('001'))
  end

  def test_a_tier_f_record_without_invariants_or_threat_model_fails
    assert_equal ["ADR-001: missing '## Invariants'", "ADR-001: missing '## Threat model'"],
                 problems_in('adr-001-a.md' => adr('001', tier: 'F'))
  end

  def test_two_files_sharing_a_number_are_a_duplicate
    assert_includes problems_in('adr-001-a.md' => adr('001'), 'adr-001-b.md' => adr('001')),
                    'duplicate ADR number 001'
  end

  def test_a_retirement_must_name_a_successor_or_say_withdrawn
    ledger = { 'RETIRED.md' => "| **002** |\n" }
    retired = ->(status) { "# ADR-002 — Old\n\n**Status:** #{status}\n**Date:** 2026-07-30\n" }

    corpus = ->(status) { ledger.merge('adr-001-a.md' => adr('001'), 'adr-002-b.md' => retired.call(status)) }

    assert_empty problems_in(corpus.call('Retired 2026-10-01 — withdrawn'))
    assert_includes problems_in(corpus.call('Retired 2026-10-01')),
                    'ADR-002: Status "Retired 2026-10-01" is not a bar §2 value'
  end

  def test_an_amendment_needs_its_reverse_edge
    amending = adr('002', extra: "**Amends:** [ADR-001](./adr-001-a.md)\n")

    assert_includes problems_in('adr-001-a.md' => adr('001'), 'adr-002-b.md' => amending),
                    "ADR-002: Amends ADR-001, but ADR-001 has no 'Amended by ADR-002'"
  end

  def test_boilerplate_and_numbered_sections_fail
    body = "Current version: `0.1`\n\n#{BODY_C.sub('## Context', '## 1. Context')}"

    assert_includes problems_in('adr-001-a.md' => adr('001', body:)), 'ADR-001: contains release-version boilerplate'
    assert_includes problems_in('adr-001-a.md' => adr('001', body:)), 'ADR-001: contains a numbered section heading'
  end

  def test_a_dead_anchor_fails
    body = BODY_C.sub('Forces.', 'See [the rule](#no-such-heading).')

    assert_includes problems_in('adr-001-a.md' => adr('001', body:)), 'adr-001-a.md: dead anchor #no-such-heading'
  end

  def test_a_stale_catalog_fails
    stale = with_corpus('adr-001-a.md' => adr('001')) do |dir|
      File.write(File.join(dir, 'adr-001-a.md'), adr('001', title: 'A changed rule'))
      AdrValidate.run(dir)
    end

    assert_equal ['catalog.json is stale — run: ruby script/adr_catalog.rb'], stale
  end

  def test_a_cited_test_name_must_be_defined_in_the_cited_file
    row = ->(name) { "| Claim | seam | `test/adr_tooling_test.rb` — `#{name}` | — |\n" }
    real = adr('001', body: "#{BODY_C}\n#{row.call('test_a_stale_catalog_fails')}")
    fake = adr('001', body: "#{BODY_C}\n#{row.call('test_that_was_never_written')}")

    assert_empty(with_corpus('adr-001-a.md' => real) { |dir| AdrVerify.run(dir) })
    assert_equal ['adr-001-a.md: `test_that_was_never_written` is not defined in test/adr_tooling_test.rb'],
                 with_corpus('adr-001-a.md' => fake) { |dir| AdrVerify.run(dir) }
  end

  def mutated(old, new) = problems_in('adr-001-a.md' => adr('001').sub(old, new))

  def test_each_record_rule_names_its_failure
    {
      ['**Date:** 2026-10-01', '**Date:** soon'] => 'ADR-001: Date must be YYYY-MM-DD',
      ['**Tier:** C', '**Tier:** B'] => 'ADR-001: Tier must be C or F',
      ['**Implementation:** Complete', '**Implementation:** Partial'] =>
        'ADR-001: Implementation must be Complete, Partial — <gap>, or Not built',
      ['**Cost:** some.', 'Cheap.'] => 'ADR-001: Consequences must state a **Cost:**',
      ['Forces.', "Forces.\n\n## Notes\n"] => "ADR-001: unexpected section '## Notes'",
      ['Forces.', 'enola: 34 dependents'] => 'ADR-001: contains a fan-in count as evidence',
      ['Forces.', 'Recommended follow-up: cite it'] => 'ADR-001: contains an open TODO in the record',
      ['Forces.', 'See [gone](./gone.md).'] => 'adr-001-a.md: broken link ./gone.md',
      ['**Date:** 2026-10-01', "**Date:** 2026-10-01\n**Date:** 2026-10-02"] =>
        "ADR-001: header 'Date' appears more than once",
      ['One sentence.', "**Relates to:** ADR-002 (unlinked)\n\nOne sentence."] =>
        'ADR-001: Relates to names ADR-002 without linking it'
    }.each do |(old, new), message|
      assert_includes mutated(old, new), message, "#{old} -> #{new}"
    end
  end

  def test_sections_out_of_order_fail
    swapped = BODY_C.sub("## Context\n\nForces.\n\n## Decision\n\nThe rule.",
                         "## Decision\n\nThe rule.\n\n## Context\n\nForces.")

    assert_includes problems_in('adr-001-a.md' => adr('001', body: swapped)), 'ADR-001: sections are out of order'
  end

  def test_a_numbering_gap_and_an_unindexed_record_fail
    assert_includes problems_in('adr-001-a.md' => adr('001'), 'adr-003-c.md' => adr('003')),
                    'no file for ADR-002 (every number keeps a file or tombstone)'
    assert_includes problems_in('adr-001-a.md' => adr('001'), 'README.md' => "none\n"),
                    'ADR-001 is not listed in the README index'
  end

  TOMBSTONE = "# ADR-002 — Old\n\n**Status:** Retired 2026-10-01 — superseded by [ADR-001](./adr-001-a.md)\n" \
              "**Date:** 2026-07-30\n"

  def test_a_retirement_needs_a_ledger_row_a_reverse_edge_and_no_sections
    problems = problems_in('adr-001-a.md' => adr('001'), 'adr-002-b.md' => "#{TOMBSTONE}\n## Decision\n")

    assert_includes problems, 'ADR-002: retired but has no RETIRED.md row'
    assert_includes problems, 'ADR-002: a tombstone keeps no sections'
    assert_includes problems, "ADR-002: superseded by ADR-001, but ADR-001 has no 'Supersedes ADR-002'"
  end

  def test_a_retirement_names_a_successor_that_exists
    orphan = TOMBSTONE.sub('[ADR-001](./adr-001-a.md)', '[ADR-009](./adr-009-x.md)')

    assert_includes problems_in('adr-001-a.md' => adr('001'), 'adr-002-b.md' => orphan),
                    'ADR-002: successor ADR-009 has no file'
  end

  def test_the_verifier_checks_paths_and_scopes_absence_to_its_cell
    missing = "| Claim | `gems/no_such_gem/x.rb` | source inspection | — |\n"
    exempt = "| Claim | `gems/no_such_gem/x.rb` | `docs/no_such.md` was removed | — |\n"
    orphan = "| Claim | seam | `test_a_stale_catalog_fails` | — |\n"
    verify = ->(row) { with_corpus('adr-001-a.md' => adr('001', body: "#{BODY_C}\n#{row}")) { AdrVerify.run(_1) } }
    gone = ['adr-001-a.md: Verification cites `gems/no_such_gem/x.rb`, which does not exist']

    assert_equal gone, verify.call(missing)
    assert_equal gone, verify.call(exempt)
    assert_equal ['adr-001-a.md: `test_a_stale_catalog_fails` is cited with no test file on the same row'],
                 verify.call(orphan)
  end
end
