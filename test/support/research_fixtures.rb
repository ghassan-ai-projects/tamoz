# frozen_string_literal: true

require 'tamoz/research'

# Shared inputs for the research tests: a two-question plan about Oslo, one page, and child records.
module ResearchFixtures
  R = Tamoz::Research
  PAGE_TEXT = 'The Oslo municipality reported a population of 717,710 residents on 1 January 2025, ' \
              'up from 709,037 a year earlier.'
  SOURCE = { 'url' => 'https://www.ssb.no/oslo', 'status' => 'found', 'claims' => 1, 'sub_question' => 'Q1',
             'primary' => false, 'second_url' => nil }.freeze

  private

  def run_files
    ledger = R.ledger(brief: plan, children: [child(1, %w[Q1], sources_doc(primary: true)), child(1, %w[Q2], nil)])
    report = R.report({ 'summary' => 'Summary.', 'body' => 'Fact [C1].' }, ledger:, stop_reason: 'budget')
    record = R.run_record(ledger:, report:, stop_reason: 'budget', extra: { 'plan_edits' => 1 })
    [R.run_folder_files(ledger:, report:, record:), report]
  end

  def plan(overrides = {})
    R.brief({ 'question' => 'How large is Oslo?', 'depth' => 'quick', 'left_out' => ['tourism numbers'],
              'sub_questions' => [{ 'text' => 'How many people live in Oslo?', 'perspective' => 'a statistician' },
                                  { 'text' => 'Is Oslo growing?', 'perspective' => 'a city planner' }] }
              .merge(overrides), budgets: @budgets)
  end

  def assignment(ids) = { 'sub_questions' => ids, 'objective' => 'Find the latest official figure.' }

  def pages
    { 'P1' => R.page(JSON.generate('url' => 'https://www.ssb.no/oslo', 'title' => 'SSB Oslo',
                                   'published' => '2025-02-01', 'text' => PAGE_TEXT), ref: 'P1') }
  end

  def report_arguments(excerpt: 'a population of 717,710 residents on 1 January 2025', page: 'P1')
    { 'summary' => 'Oslo had 717,710 residents at the start of 2025.',
      'findings' => [{ 'sub_question' => 'Q1', 'status' => 'found',
                       'claims' => [{ 'claim' => 'Oslo had 717,710 residents on 1 January 2025.',
                                      'page' => page, 'excerpt' => excerpt }] }] }
  end

  def sources_doc(**options)
    given = SOURCE.merge(options.transform_keys(&:to_s))
    claim = { 'text' => 'Oslo had 717,710 residents.', 'excerpt' => 'a population of 717,710 residents',
              'primary' => given.fetch('primary'), 'url' => given.fetch('url'), 'title' => 'SSB Oslo',
              'published' => '2025-02-01' }
    second = given.fetch('second_url')
    list = Array.new(given.fetch('claims')) { |index| index.positive? && second ? claim.merge('url' => second) : claim }
    { 'summary' => 'Found it.', 'findings' => [{ 'sub_question' => given.fetch('sub_question'),
                                                 'status' => given.fetch('status'), 'note' => '', 'claims' => list }] }
  end

  def child(wave, ids, sources)
    { 'wave' => wave, 'sub_questions' => ids, 'sources' => sources, 'searches' => 3, 'page_reads' => 2 }
  end
end
