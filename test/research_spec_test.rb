# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/research_spec'

# Quality-bar rows P, B, C and I of docs/deep-research-2026-09-30 through the real work route. Scripted models: this
# is plumbing and authority, never evidence that a model researches well.
# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions -- each row reads one research run from several sides.
class ResearchSpecTest < Minitest::Test
  include ResearchSpec

  INTERNALS = [/subagent/i, /\bwave\b/i, /research_wave|write_report|propose_research_plan|report_sources/,
               /\[C\d+\]/, /\bS\d+-\d+\b/, /\bP\d+\b/, /token/i, /sha256/].freeze

  def test_a_research_run_plans_asks_researches_and_writes_its_report
    with_research(lead: happy_lead, children: happy_children) do |session, model, web, out|
      paused = start_research(session)

      assert_equal :paused, paused.status
      assert_empty web.calls
      question = session.view(thread: 'research').interrupts.first.descriptor.fetch('question')

      assert_includes question, 'How many people live in Oslo?'
      outcome = reply(session, 'go')

      assert_equal :completed, outcome.status, outcome.inspect[0, 800]
      report = Dir[File.join(out, '*', 'report.md')].first

      refute_nil report
      text = File.read(report)

      assert_includes text, 'Oslo had 717,710 residents at the start of 2025 [1].'
      assert_includes text, "[1] Population of Oslo - Statistics Norway. #{SSB}."
      assert_includes web_calls(web), 'mcp:websearch/read_page'
      refute_empty model.child_requests
    end
  end

  def test_p1_no_search_runs_before_the_user_accepts_a_plan
    lead = [{ calls: [wave_call(%w[Q1])] }, { content: 'Waiting.' }, { content: 'Still waiting.' }]
    with_research(lead:) do |session, model, web, _out|
      start_research(session)

      assert_empty web.calls
      assert_includes tool_messages(model.parent_requests[1]).join, 'has not accepted a plan'
    end
  end

  def test_p1_the_lead_has_no_web_tool_and_a_child_has_only_web_tools_and_its_finish
    with_research(lead: happy_lead, children: happy_children) do |session, model, _web, _out|
      start_research(session)
      reply(session, 'go')

      assert_empty wire_names(model.parent_requests.first) & %w[web_search read_page delegate read_file]
      assert_equal %w[read_page recall_output report_sources web_search], wire_names(model.child_requests.first)
    end
  end

  def test_p2_an_edit_in_words_changes_the_brief_the_children_receive
    revised = plan_call(texts: ['How many people live in Oslo?'])
    lead = [{ calls: [plan_call] }, { calls: [revised] }, { calls: [wave_call(%w[Q1])] },
            { calls: [report_call('Oslo had 717,710 residents at the start of 2025 [C1].')] }]
    with_research(lead:,
                  children: reading_child('Q1', 'Oslo population statistics',
                                          SSB_EXCERPT)) do |session, model, _web, out|
      start_research(session)
      reply(session, 'drop the growth question')

      assert_includes tool_messages(model.parent_requests[1]).join, 'drop the growth question'
      outcome = reply(session, 'go')

      assert_equal :completed, outcome.status
      opening = JSON.parse(model.child_requests.first).fetch('messages').map { |message| message['content'] }.join

      assert_includes opening, 'How many people live in Oslo?'
      refute_includes opening, 'Is Oslo growing?'
      assert_equal 1, JSON.parse(File.read(Dir[File.join(out, '*', 'run.json')].first)).fetch('plan_edits')
    end
  end

  def test_p3_stop_at_the_checkpoint_ends_the_turn_with_nothing_searched
    with_research(lead: [{ calls: [plan_call] }]) do |session, _model, web, out|
      start_research(session)
      outcome = reply(session, 'stop')

      assert_equal :completed, outcome.status
      assert_equal 'cancelled_by_user', session.view(thread: 'research').state.fetch(:terminal_reason)
      assert_empty web.calls
      assert_empty Dir.children(out)
    end
  end

  def test_b2_a_made_up_excerpt_is_refused_until_the_child_quotes_the_page
    invented = sources_call('Q1', 'P1', 'Oslo has exactly one million residents according to this page.')
    child = reading_child('Q1', 'Oslo population statistics', SSB_EXCERPT).insert(2, { calls: [invented] })
    lead = [{ calls: [plan_call(texts: ['How many people live in Oslo?'])] }, { calls: [wave_call(%w[Q1])] },
            { calls: [report_call('Oslo had 717,710 residents [C1].')] }]
    with_research(lead:, children: child) do |session, model, _web, out|
      start_research(session)
      reply(session, 'go')

      assert_includes tool_messages(model.child_requests[3]).join, 'the excerpt is not in P1'
      refute_includes File.read(Dir[File.join(out, '*', 'report.md')].first), 'one million'
    end
  end

  def test_s1_a_page_read_names_a_search_result_never_a_url
    child = [{ calls: [['read_page', { 'ref' => 'S9-9' }]] },
             { calls: [['web_search', { 'query' => 'Oslo population' }]] },
             { calls: [['read_page', { 'ref' => 'S1-1' }]] }, { calls: [sources_call('Q1', 'P1', SSB_EXCERPT)] }]
    lead = [{ calls: [plan_call(texts: ['How many people live in Oslo?'])] }, { calls: [wave_call(%w[Q1])] },
            { calls: [report_call('Oslo had 717,710 residents [C1].')] }]
    with_research(lead:, children: child) do |session, model, web, _out|
      start_research(session)
      reply(session, 'go')

      assert_includes tool_messages(model.child_requests[1]).join, 'is not a result of your searches'
      assert_equal([['mcp:websearch/read_page', { 'url' => SSB }]], web.calls.select do |name, _|
        name.end_with?('read_page')
      end)
    end
  end

  def test_b1_b3_a_report_citing_an_unknown_claim_is_refused_and_the_sources_list_is_generated
    lead = happy_lead.dup
    lead[2] = { calls: [report_call('Made up [C9].')] }
    lead << { calls: [report_call('Oslo had 717,710 residents [C1]; see https://evil.example/x for more [C2].')] }
    with_research(lead:, children: happy_children) do |session, model, _web, out|
      start_research(session)
      reply(session, 'go')

      assert_includes tool_messages(model.parent_requests.last).join, 'cites claims that do not exist: C9'
      sources = File.read(Dir[File.join(out, '*', 'report.md')].first).split('## Sources').last

      refute_includes sources, 'evil.example'
      assert_equal 2, sources.scan(/^\[\d\]/).length
    end
  end

  def test_b4_a_claim_the_check_finds_unsupported_is_flagged_and_loses_its_source
    with_research(lead: happy_lead, children: happy_children,
                  reviews: [{ 'unsupported' => ['C2'] }]) do |session, _model, _web, out|
      start_research(session)
      reply(session, 'go')
      text = File.read(Dir[File.join(out, '*', 'report.md')].first)

      assert_includes text, 'It grew by about 8,700 in 2024 [unverified].'
      assert_includes text, '1 cited claim(s) could not be confirmed'
      refute_includes text, 'oslo.kommune.no'
    end
  end

  def test_c2_the_report_is_refused_while_a_sub_question_is_open_and_budget_remains
    lead = [{ calls: [plan_call(depth: 'standard', texts: ['How many people live in Oslo?'])] },
            { calls: [wave_call(%w[Q1])] }, { calls: [report_call('Early [C1].')] }, { calls: [wave_call(%w[Q1])] },
            { calls: [report_call('Oslo had 717,710 residents [C1].')] }]
    weak = sources_call('Q1', 'P1', SSB_EXCERPT, primary: false)
    children = [{ calls: [['web_search', { 'query' => 'Oslo population' }]] },
                { calls: [['read_page', { 'ref' => 'S1-1' }]] },
                { calls: [weak] }] + reading_child('Q1', 'Oslo population statistics', SSB_EXCERPT)
    with_research(lead:, children:) do |session, model, _web, out|
      start_research(session)
      reply(session, 'go')

      assert_includes tool_messages(model.parent_requests[3]).join, 'Still open: Q1'
      refute_empty Dir[File.join(out, '*', 'report.md')]
    end
  end

  def test_c4_a_child_cannot_search_past_its_share_of_the_budget
    budgets = { 'depths' => { 'quick' => { 'searches' => 2 } } }
    searches = Array.new(3) { |index| { calls: [['web_search', { 'query' => "Oslo population #{index}" }]] } }
    child = searches + [{ calls: [['read_page', { 'ref' => 'S1-1' }]] },
                        { calls: [sources_call('Q1', 'P1', SSB_EXCERPT)] }]
    lead = [{ calls: [plan_call(texts: ['How many people live in Oslo?'])] }, { calls: [wave_call(%w[Q1])] },
            { calls: [report_call('Oslo had 717,710 residents [C1].')] }]
    with_research(lead:, children: child, budgets:) do |session, model, web, _out|
      start_research(session)
      reply(session, 'go')

      assert_equal 2, web_calls(web).count('mcp:websearch/search')
      assert_includes tool_messages(model.child_requests[3]).join, 'searches budget is spent'
    end
  end

  def test_i1_the_plan_and_the_reply_show_no_internals
    with_research(lead: happy_lead, children: happy_children) do |session, _model, _web, _out|
      start_research(session)
      plan = session.view(thread: 'research').interrupts.first.descriptor.fetch('question')
      reply(session, 'go')
      answer = session.view(thread: 'research').state.fetch(:verification).fetch('answer')

      [plan, answer].each do |text|
        INTERNALS.each { |word| refute_match(word, text) }
      end
    end
  end

  # A pretend child graph that records how many children each call ran at once.
  class CountingApp
    attr_reader :sizes

    def initialize = @sizes = []

    def call(input, _context)
      @sizes << 1
      { task: input.fetch(:task) }
    end

    def call_many(inputs, _context)
      @sizes << inputs.length
      inputs.map { |input| { task: input.fetch(:task) } }
    end
  end

  def test_c5_children_run_in_batches_no_larger_than_the_route_allows
    app = CountingApp.new
    child = Tamoz::Agent::SubagentApps::App.new(role: Tamoz::Harness::SubagentRoles.shipped.fetch('research'), app:)
    delegation = Tamoz::Agent::WorkDelegation.new(services: nil, work: nil)
    outputs = delegation.run_inputs(child, (1..5).map { |index| { task: "t#{index}" } }, nil, batch: 2)

    assert_equal [2, 2, 1], app.sizes
    assert_equal(%w[t1 t2 t3 t4 t5], outputs.map { |output| output.fetch(:task) })
    assert_equal 3, Tamoz::Agent::ModelWindows.max_concurrent_requests(provider: 'zai', model: 'glm-5.3-flash') - 1
  end

  def test_an_ordinary_turn_cannot_delegate_to_the_research_role
    lead = [{ calls: [['delegate', { 'role' => 'research', 'brief' => 'Search the web.' }]] }, { content: 'No.' }]
    with_research(lead:, subagents: %w[explore]) do |session, model, web, _out|
      session.start('Look around.', thread: 'research', request_id: 'r1')
      delegate = JSON.parse(model.parent_requests.first).fetch('tools').find do |tool|
        tool.dig('function', 'name') == 'delegate'
      end

      assert_equal %w[explore], delegate.dig('function', 'parameters', 'properties', 'role', 'enum')
      assert_includes tool_messages(model.parent_requests.last).join, 'unknown subagent role; one of explore'
      assert_empty web.calls
    end
  end

  def test_a_finishing_call_must_come_alone_and_go_with_punctuation_is_accepted
    child = [{ calls: [['web_search', { 'query' => 'Oslo population' }]] },
             { calls: [['read_page', { 'ref' => 'S1-1' }]] },
             { calls: [sources_call('Q1', 'P1', SSB_EXCERPT), ['web_search', { 'query' => 'again' }]] },
             { calls: [sources_call('Q1', 'P1', SSB_EXCERPT)] }]
    lead = [{ calls: [plan_call(texts: ['How many people live in Oslo?'])] }, { calls: [wave_call(%w[Q1])] },
            { calls: [report_call('Oslo had 717,710 residents [C1].')] }]
    with_research(lead:, children: child) do |session, model, _web, out|
      start_research(session)

      assert_equal :completed, reply(session, 'Go!').status
      assert_includes tool_messages(model.child_requests[3]).join, 'call it alone'
      refute_empty Dir[File.join(out, '*', 'report.md')]
    end
  end

  def test_the_plan_cannot_change_once_research_has_run
    lead = [{ calls: [plan_call(texts: ['How many people live in Oslo?'])] }, { calls: [wave_call(%w[Q1])] },
            { calls: [plan_call(texts: ['Something else?'])] },
            { calls: [report_call('Oslo had 717,710 residents [C1].')] }]
    children = reading_child('Q1', 'Oslo population statistics', SSB_EXCERPT)
    with_research(lead:, children:) do |session, model, _web, _out|
      start_research(session)

      assert_equal :completed, reply(session, 'go').status
      assert_includes tool_messages(model.parent_requests[3]).join, 'the plan can no longer change'
    end
  end

  def test_a_failed_page_read_still_spends_the_budget
    budgets = { 'depths' => { 'quick' => { 'page_reads' => 1 } } }
    child = [{ calls: [['web_search', { 'query' => 'Oslo population' }]] },
             { calls: [['read_page', { 'ref' => 'S1-1' }]] }, { calls: [['read_page', { 'ref' => 'S1-2' }]] },
             { calls: [sources_call('Q1', nil, nil, status: 'not_found')] }]
    lead = [{ calls: [plan_call(texts: ['How many people live in Oslo?'])] }, { calls: [wave_call(%w[Q1])] },
            { calls: [report_call('Nothing was found.')] }]
    with_research(lead:, children: child, budgets:) do |session, model, web, _out|
      web.failing_reads = true
      start_research(session)
      reply(session, 'go')

      assert_equal 1, web_calls(web).count('mcp:websearch/read_page')
      assert_includes tool_messages(model.child_requests[3]).join, 'page reads budget is spent'
    end
  end

  def test_the_batch_follows_the_routes_pinned_concurrency
    route = Struct.new(:provider, :model)

    assert_equal 3, Tamoz::Agent::WorkResearch.batch_for(route.new('zai', 'glm-5.3-flash'))
    assert_equal 1, Tamoz::Agent::WorkResearch.batch_for(route.new('deepseek', 'deepseek-flash'))
    assert_equal 1, Tamoz::Agent::WorkResearch.batch_for(Object.new)
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
