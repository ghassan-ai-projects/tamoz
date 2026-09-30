# frozen_string_literal: true

require 'tamoz/mcp/websearch'
require_relative 'subagent_fixtures'

load ROOT.join('script', 'websearch_adapter').to_s unless defined?(WebsearchAdapter)

# Deep research through the real work route, over the real websearch adapter code serving a fixture web in-process.
# The models are scripted: this proves the plan checkpoint, the web refs, the citation checks and the files, never
# that a model researches well.
module ResearchSpec
  include SubagentFixtures

  WEB = ROOT.join('test', 'fixtures', 'research', 'spec_web.json').to_s
  QUESTION = 'How many people live in Oslo, and is it growing?'
  FLAGS = %w[TAMOZ_WEBSEARCH_GRANT TAMOZ_WEBSEARCH_EGRESS TAMOZ_WEBSEARCH_PROVIDER].freeze
  SSB = 'https://www.ssb.no/en/befolkning/oslo'
  EGRESS = { 'allowlisted_hosts' => ['api.search.brave.com'], 'schemes' => ['https'], 'deny_private_ranges' => true,
             'max_request_bytes' => 2048, 'max_response_bytes' => 65_536, 'connect_timeout_s' => 10,
             'redirect_max_hops' => 3, 'circuit' => { 'threshold' => 3, 'scope_type' => 'egress',
                                                      'budget_breach' => true },
             'credential_refs' => ['TAMOZ_BRAVE_API_KEY'], 'page_reads' => 'public' }.freeze

  # The websearch MCP source, answered by the adapter's own search and read_page over the fixture web.
  class FixtureWebsearch
    Invocation = Tamoz::Mcp::Invocation
    TOOLS = { 'mcp:websearch/search' => 'search', 'mcp:websearch/read_page' => 'read_page' }.freeze

    attr_reader :calls, :descriptors
    attr_accessor :failing_reads

    def initialize
      @calls = []
      @descriptors = TOOLS.map do |id, name|
        Invocation::Descriptor.new(id:, name:, source_id: 'websearch', definition_digest: "sha256:#{name}",
                                   input_schema: {}, output_schema: nil, effect_class: :read_only,
                                   protocol_profile: 'fixture')
      end
      WebsearchAdapter.reset!
    end

    def names = TOOLS.keys
    def read_only_names = TOOLS.keys
    def name?(name) = TOOLS.key?(String(name))
    def read_only?(name) = name?(name)
    def catalogs = {}
    def mcp_catalogs = {}
    def mcp_source_digests = {}
    def empty? = false
    def close = nil
    def descriptor_for(name) = @descriptors.find { |descriptor| descriptor.id == String(name) }
    def descriptor_for!(name) = descriptor_for(name) || raise(Tamoz::Agent::ToolError, "unknown tool #{name}")
    def source_id_for(_name) = 'websearch'
    def validate(_name, arguments) = arguments
    def effect_intent(_name, _arguments) = {}
    def preview(name, arguments) = "#{name} #{JSON.generate(arguments)}"
    def maximum_effect_output_bytes(_name) = 65_536

    def execute(_context, name, arguments)
      @calls << [name, arguments]
      failed = failing_reads && name.end_with?('read_page')
      raise Tamoz::Tools::ToolArgumentError, 'the page answered HTTP 503' if failed

      response = if name == 'mcp:websearch/search'
                   WebsearchAdapter.search_response(arguments['query'], arguments.fetch('max_results', 5))
                 else
                   WebsearchAdapter.read_page_response(arguments['url'])
                 end
      text = response.content.first.fetch(:text)
      raise Tamoz::Tools::ToolArgumentError, text if response.error?

      observation = Invocation::Observation.new(server_id: 'websearch', content_blocks: [], text:,
                                                structured_content: nil, truncated: false)
      Invocation::Outcome.new(status: :succeeded, observation:, interrupt: nil, denial: nil, effect_key: 'fixture')
    end
  end

  def with_research(lead:, children: [], reviews: [{ 'unsupported' => [] }], budgets: nil, subagents: [], &)
    with_fixture_web { research_workspace(lead:, children:, reviews:, budgets:, subagents:, &) }
  end

  def with_fixture_web
    saved = ENV.to_h.slice(*FLAGS)
    ENV['TAMOZ_WEBSEARCH_GRANT'] = '1'
    ENV['TAMOZ_WEBSEARCH_EGRESS'] = JSON.generate(EGRESS)
    ENV['TAMOZ_WEBSEARCH_PROVIDER'] = JSON.generate('search' => 'fixture', 'reader' => 'fixture', 'web' => WEB)
    yield
  ensure
    FLAGS.each { |name| ENV.delete(name) }
    saved&.each { |name, value| ENV[name] = value }
  end

  def research_workspace(lead:, children:, reviews:, budgets:, subagents:)
    with_work_workspace do |root, adapter|
      Dir.mktmpdir('tamoz-research-out') do |out|
        web = FixtureWebsearch.new
        model = ScriptedTeam.new(parent: lead, child: children, reviews:)
        harness = { research_dir: out, research_budgets: budgets }.compact
        session = subagent_session(model:, root:, adapter:, subagents:, harness:, mcp: web)
        yield session, model, web, out
      end
    end
  end

  def start_research(session) = session.research(QUESTION, thread: 'research', request_id: 'r1')

  # Answers the paused plan with the user's reply; returns the outcome.
  def reply(session, text, request_id: "reply-#{text.hash.abs}")
    task_id = session.view(thread: 'research').interrupts.first.task_id
    session.resume({ task_id => { 0 => text } }, thread: 'research', request_id:)
  end

  def plan_call(depth: 'quick', texts: ['How many people live in Oslo?', 'Is Oslo growing?'])
    ['propose_research_plan', { 'question' => QUESTION, 'depth' => depth,
                                'sub_questions' => texts.map do |text|
                                  { 'text' => text, 'perspective' => 'a statistician' }
                                end }]
  end

  def wave_call(*groups)
    ['research_wave', { 'assignments' => groups.map do |ids|
      { 'sub_questions' => ids, 'objective' => 'Find the latest official figures.' }
    end }]
  end

  def sources_call(sub_question, page, excerpt, primary: true, status: 'found')
    claims = page ? [{ 'claim' => excerpt, 'page' => page, 'excerpt' => excerpt, 'primary' => primary }] : []
    ['report_sources', { 'summary' => 'Done.', 'findings' => [{ 'sub_question' => sub_question, 'status' => status,
                                                                'claims' => claims }] }]
  end

  # A child that searches, reads the first hit and reports it.
  def reading_child(sub_question, query, excerpt)
    [{ calls: [['web_search', { 'query' => query }]] }, { calls: [['read_page', { 'ref' => 'S1-1' }]] },
     { calls: [sources_call(sub_question, 'P1', excerpt)] }]
  end

  def report_call(body, summary: 'Oslo had about 718,000 residents in 2025 and is growing.')
    ['write_report', { 'summary' => summary, 'body' => body }]
  end

  def web_calls(web) = web.calls.map(&:first)
end
