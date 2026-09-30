# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/research_fixtures'

# The research rules after the children: the ledger's statuses and stop reason, the report and the run's files.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize -- each case reads one research value from several sides.
class ResearchLedgerTest < Minitest::Test
  include ResearchFixtures

  def setup
    @budgets = R.budgets
  end

  def test_one_non_primary_source_leaves_a_sub_question_open
    one_host = R.ledger(brief: plan, children: [child(1, %w[Q1], sources_doc)])

    assert_equal 'open', one_host.statuses.fetch('Q1')
    primary = R.ledger(brief: plan, children: [child(1, %w[Q1], sources_doc(primary: true))])

    assert_equal 'answered', primary.statuses.fetch('Q1')
  end

  def test_two_hosts_answer_a_sub_question_and_claims_are_numbered
    two_hosts = R.ledger(brief: plan, children: [child(1, %w[Q1], sources_doc),
                                                 child(1, %w[Q1], sources_doc(url: 'https://oslo.kommune.no/x'))])

    assert_equal 'answered', two_hosts.statuses.fetch('Q1')
    assert_equal %w[C1 C2], two_hosts.claims.map(&:id)
  end

  def test_conflicting_and_not_found_become_contested_and_unanswerable
    conflicting = sources_doc(status: 'conflicting', claims: 2)
    missing = { 'summary' => 'Nothing.', 'findings' => [{ 'sub_question' => 'Q2', 'status' => 'not_found',
                                                          'note' => '', 'claims' => [] }] }
    ledger = R.ledger(brief: plan, children: [child(1, %w[Q1], conflicting), child(1, %w[Q2], missing)])

    assert_equal({ 'Q1' => 'contested', 'Q2' => 'unanswerable' }, ledger.statuses)
    assert_equal 'coverage', R.stop_reason(ledger, budgets: @budgets)
  end

  def test_the_run_stops_on_budget_or_when_a_wave_adds_nothing
    standard = plan('depth' => 'standard')
    open_ledger = R.ledger(brief: standard, children: [child(1, %w[Q1], sources_doc)])

    assert_nil R.stop_reason(open_ledger, budgets: @budgets)
    nothing = R.ledger(brief: standard, children: [child(1, %w[Q1], sources_doc), child(2, %w[Q1 Q2], nil)])

    assert_equal 'budget', R.stop_reason(nothing, budgets: @budgets)
    tight = R.budgets(override: { 'depths' => { 'standard' => { 'waves' => 2 } } })
    first_wave_empty = R.ledger(brief: standard, children: [child(1, %w[Q1 Q2], nil)])

    assert_equal 'saturation', R.stop_reason(first_wave_empty, budgets: tight)
  end

  def test_a_report_numbers_sources_and_generates_the_list
    ledger = R.ledger(brief: plan, children: [child(1, %w[Q1], sources_doc(primary: true))])
    report = R.report({ 'summary' => 'Oslo has about 718,000 people.',
                        'body' => 'Oslo had 717,710 residents in 2025 [C1]. It grew [C1].' },
                      ledger:, stop_reason: 'budget')

    assert_includes report.markdown, 'Oslo had 717,710 residents in 2025 [1]. It grew [1].'
    assert_includes report.markdown, '[1] SSB Oslo. https://www.ssb.no/oslo. Published 2025-02-01.'
    assert_includes report.markdown, 'Research stopped at its budget.'
    assert_includes report.markdown, 'Is Oslo growing?: not established within the budget'
    assert_includes report.reply('/runs/x/report.md'), 'The full report is saved at /runs/x/report.md'
  end

  def test_a_report_refuses_unknown_cites_and_flags_unconfirmed_ones
    ledger = R.ledger(brief: plan, children: [child(1, %w[Q1], sources_doc(primary: true))])

    assert_raises(Tamoz::Research::Error) do
      R.report({ 'summary' => 'x', 'body' => 'Made up [C9].' }, ledger:, stop_reason: 'coverage')
    end
    assert_raises(Tamoz::Research::Error) do
      R.report({ 'summary' => 'x', 'body' => 'No citations at all.' }, ledger:, stop_reason: 'coverage')
    end
    flagged = R.report({ 'summary' => 'x', 'body' => 'Claim [C1].' }, ledger:, stop_reason: 'coverage',
                                                                      unsupported: %w[C1])

    assert_includes flagged.markdown, 'Claim [unverified].'
    assert_equal [['Claim [C1].', %w[C1]], ['Two [C1, C2].', %w[C1 C2]]], R.citations("Claim [C1].\nTwo [C1, C2].")
  end

  def test_the_run_folder_holds_the_report_notes_sources_and_record
    files, report = run_files

    assert_equal %w[brief.md notes/1.md notes/2.md report.md run.json sources.jsonl], files.keys.sort
    assert_equal "#{report.markdown}\n", files.fetch('report.md')
    assert_equal 1, JSON.parse(files.fetch('run.json')).fetch('plan_edits')
    assert_includes files.fetch('notes/2.md'), 'No accepted sources.'
    source = JSON.parse(files.fetch('sources.jsonl').lines.first)

    assert_equal '2025-02-01', source.fetch('published')
    assert_equal '2025-02-01T12:00:00Z', source.fetch('read_at')
  end

  def test_the_run_folder_is_named_by_date_and_question
    assert_equal '2026-09-30-how-large-is-oslo-0f3a9c2e',
                 R.run_folder_name(date: '2026-09-30', question: 'How large is Oslo?!', run_id: '0f3a9c2e-77aa-4c1d')
    assert_equal '2026-09-30-كم-عدد-سكان-أوسلو-12345678',
                 R.run_folder_name(date: '2026-09-30', question: 'كم عدد سكان أوسلو؟', run_id: '12345678')
  end

  def test_a_run_whose_page_reads_are_spent_stops_on_budget
    read_out = { 'wave' => 1, 'sub_questions' => %w[Q1], 'sources' => sources_doc, 'searches' => 1,
                 'page_reads' => 30 }
    ledger = R.ledger(brief: plan('depth' => 'standard'), children: [read_out])

    assert_equal 'budget', R.stop_reason(ledger, budgets: @budgets)
    assert_raises(Tamoz::Research::Error) { R.wave({ 'assignments' => [assignment(%w[Q2])] }, ledger:, budgets: @budgets) }
  end

  def test_a_wave_that_adds_claims_only_to_settled_sub_questions_is_saturated
    standard = plan('depth' => 'deep')
    settled = child(1, %w[Q1], sources_doc(primary: true))
    fresh = child(2, %w[Q2], sources_doc(sub_question: 'Q2'))

    assert_nil R.stop_reason(R.ledger(brief: standard, children: [settled, fresh]), budgets: @budgets)
    again = child(2, %w[Q1], sources_doc(primary: true, url: 'https://oslo.kommune.no/x'))

    assert_equal 'saturation', R.stop_reason(R.ledger(brief: standard, children: [settled, again]), budgets: @budgets)
  end

  def test_not_found_needs_enough_searches_to_mean_unanswerable
    missing = { 'summary' => 'Nothing.', 'findings' => [{ 'sub_question' => 'Q2', 'status' => 'not_found',
                                                          'note' => '', 'claims' => [] }] }
    hasty = child(1, %w[Q2], missing).merge('searches' => 1)

    assert_equal 'open', R.ledger(brief: plan, children: [hasty]).statuses.fetch('Q2')
  end

  def test_two_sources_are_numbered_in_order_of_first_citation
    two = [child(1, %w[Q1], sources_doc), child(1, %w[Q1], sources_doc(url: 'https://oslo.kommune.no/x'))]
    ledger = R.ledger(brief: plan, children: two)
    report = R.report({ 'summary' => 'S [C2].', 'body' => 'First [C2]. Second [C1]. Both [C1; C2].' },
                      ledger:, stop_reason: 'budget')

    assert_includes report.markdown, 'First [1]. Second [2]. Both [2, 1].'
    assert_includes report.summary, 'S [1].'
    assert_raises(Tamoz::Research::Error) do
      R.report({ 'summary' => 'x', 'body' => 'Range [C1-C2].' }, ledger:, stop_reason: 'budget')
    end
  end

  def test_a_source_backed_only_by_unconfirmed_claims_is_not_listed
    ledger = R.ledger(brief: plan, children: [child(1, %w[Q1], sources_doc(primary: true))])
    report = R.report({ 'summary' => 'x', 'body' => 'Claim [C1].' }, ledger:, stop_reason: 'coverage',
                                                                     unsupported: %w[C1])

    assert_includes report.markdown, 'No source was cited.'
    assert_includes report.markdown, '1 cited claim(s) could not be confirmed'
  end

  def test_contested_sub_questions_get_a_disagreement_section
    conflicting = sources_doc(status: 'conflicting', claims: 2, second_url: 'https://other.org/y')
    ledger = R.ledger(brief: plan, children: [child(1, %w[Q1], conflicting)])
    report = R.report({ 'summary' => 'x', 'body' => 'Sources differ [C1].' }, ledger:, stop_reason: 'budget')

    assert_includes report.markdown, "## Where sources disagree\n\n- How many people live in Oslo?: "
    assert_includes report.markdown, '[2] SSB Oslo. https://other.org/y.'
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize
