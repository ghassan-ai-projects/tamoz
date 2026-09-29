# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/research_fixtures'

# The research rules before the ledger, through the facade the session uses: budgets, a plan, a wave, web
# results and a child's cited sources.
# rubocop:disable Minitest/MultipleAssertions -- each case reads one research value from several sides.
class ResearchTest < Minitest::Test
  include ResearchFixtures

  def setup
    @budgets = R.budgets
  end

  def test_shipped_budgets_keep_every_depth_under_its_ceilings
    %w[quick standard deep].each do |name|
      depth = @budgets.depth(name)

      assert_operator depth.searches, :<=, @budgets.ceilings.fetch('searches')
      assert_operator depth.children_per_wave, :<=, @budgets.ceilings.fetch('children_per_wave')
    end
  end

  def test_an_override_may_lower_a_number_but_never_raise_one
    narrowed = R.budgets(override: { 'depths' => { 'standard' => { 'searches' => 15 } } })

    assert_equal 15, narrowed.depth('standard').searches
    error = assert_raises(Tamoz::Research::Error) do
      R.budgets(override: { 'ceilings' => { 'searches' => 500 } })
    end
    assert_match(/may only lower/, error.message)
    assert_raises(Tamoz::Research::Error) { R.budgets(override: { 'depths' => { 'huge' => { 'waves' => 1 } } }) }
  end

  def test_a_plan_numbers_its_sub_questions_and_reads_plainly
    brief = plan

    assert_equal %w[Q1 Q2], brief.ids
    text = R.plan_text(brief, budgets: @budgets)

    assert_includes text, 'How many people live in Oslo?'
    assert_includes text, 'seen as a statistician'
    assert_includes text, 'Leaving out: tourism numbers'
    assert_includes text, 'about 3 minutes'
    assert_includes text, 'Reply "go" to start'
    %w[subagent wave tool Q1 C1].each { |internal| refute_includes text, internal }
  end

  def test_a_plan_refuses_an_unknown_depth_and_repeated_sub_questions
    assert_raises(Tamoz::Research::Error) { plan('depth' => 'forever') }
    same = [{ 'text' => 'A?', 'perspective' => 'x' }, { 'text' => 'a?', 'perspective' => 'y' }]

    assert_raises(Tamoz::Research::Error) { plan('sub_questions' => same) }
    assert_equal plan.to_h, R.restore_brief(plan.to_h).to_h
  end

  def test_a_wave_splits_the_budget_and_briefs_each_child_on_its_own_sub_questions
    ledger = R.ledger(brief: plan, children: [])
    wave = R.wave({ 'assignments' => [assignment(%w[Q1]), assignment(%w[Q2])] }, ledger:, budgets: @budgets)

    assert_equal [5, 5], wave.assignments.map(&:searches)
    task = wave.child_task(wave.assignments.first)

    assert_includes task, 'Q1: How many people live in Oslo? Look at it as a statistician.'
    assert_includes task, 'at most 5 searches'
    refute_includes task, 'Q2'
  end

  def test_a_wave_refuses_closed_or_doubled_sub_questions
    ledger = R.ledger(brief: plan, children: [])

    assert_raises(Tamoz::Research::Error) do
      R.wave({ 'assignments' => [assignment(%w[Q1]), assignment(%w[Q1])] }, ledger:, budgets: @budgets)
    end
    assert_raises(Tamoz::Research::Error) do
      R.wave({ 'assignments' => [assignment(%w[Q9])] }, ledger:, budgets: @budgets)
    end
  end

  def test_a_quick_run_refuses_a_second_wave
    ledger = R.ledger(brief: plan, children: [child(1, %w[Q1], nil)])

    error = assert_raises(Tamoz::Research::Error) do
      R.wave({ 'assignments' => [assignment(%w[Q2])] }, ledger:, budgets: @budgets)
    end
    assert_match(/write the report/, error.message)
  end

  def test_search_hits_carry_refs_and_render_without_the_raw_json
    hits = R.search_hits(JSON.generate('results' => [
      { 'title' => 'Oslo facts', 'url' => 'https://ssb.no/oslo', 'snippet' => 'Oslo  has', 'age' => '2025' }
    ]), ordinal: 2)

    assert_equal 'S2-1', hits.first.ref
    assert_includes R.render_hits(hits, ordinal: 2), "S2-1 Oslo facts (2025)\n  https://ssb.no/oslo\n  Oslo has"
    assert_equal 'Search S3 found nothing.', R.render_hits([], ordinal: 3)
    assert_raises(Tamoz::Research::Error) { R.search_hits('not json', ordinal: 1) }
  end

  def test_sources_keep_the_page_each_claim_quotes
    accepted = R.sources(report_arguments, pages: pages, assigned: %w[Q1])

    assert_equal 'found', accepted.findings.first.status
    assert_equal 'https://www.ssb.no/oslo', accepted.findings.first.claims.first.url
  end

  def test_sources_are_refused_when_an_excerpt_is_not_on_a_page_the_child_read
    invented = report_arguments(excerpt: 'The population of Oslo is exactly one million people today.')
    error = assert_raises(Tamoz::Research::Error) { R.sources(invented, pages: pages, assigned: %w[Q1]) }
    assert_match(/not in P1/, error.message)
    unread = report_arguments(page: 'P7')
    assert_raises(Tamoz::Research::Error) { R.sources(unread, pages: pages, assigned: %w[Q1]) }
    assert_raises(Tamoz::Research::Error) { R.sources(report_arguments, pages: pages, assigned: %w[Q1 Q2]) }
  end

  def test_an_excerpt_matches_across_whitespace_and_case
    loose = report_arguments(excerpt: "a population of 717,710\n   RESIDENTS on 1 January 2025")

    assert R.sources(loose, pages: pages, assigned: %w[Q1])
  end

  def test_lowering_a_ceiling_pulls_every_depth_under_it
    tight = R.budgets(override: { 'ceilings' => { 'searches' => 15 } })

    assert_equal([10, 15, 15], %w[quick standard deep].map { |name| tight.depth(name).searches })
  end

  def test_a_wave_keeps_a_share_of_the_budget_for_later_waves
    ledger = R.ledger(brief: plan('depth' => 'standard'), children: [])
    wave = R.wave({ 'assignments' => [assignment(%w[Q1])] }, ledger:, budgets: @budgets)

    assert_equal [20, 15], [wave.assignments.first.searches, wave.assignments.first.page_reads]
  end

  def test_excerpts_outside_their_length_bounds_are_refused
    [19, 401].each do |length|
      text = 'x' * length
      page = { 'P1' => R.page(JSON.generate('url' => 'https://a.org', 'title' => 'A', 'text' => text), ref: 'P1') }

      assert_raises(Tamoz::Research::Error) do
        R.sources(report_arguments(excerpt: text), pages: page, assigned: %w[Q1])
      end
    end
  end

  def test_restored_sources_read_back_the_same
    accepted = R.sources(report_arguments, pages: pages, assigned: %w[Q1])

    assert_equal accepted.to_h, R.restore_sources(accepted.to_h).to_h
    assert_predicate R.restore_sources(accepted.to_h).findings.first.claims, :frozen?
  end
end
# rubocop:enable Minitest/MultipleAssertions
