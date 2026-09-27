# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Minitest/MultipleAssertions

require_relative 'test_helper'
require_relative 'support/work_loop_fixtures'
require_relative 'support/probe_fixture'

# The work loop investigating with operator probes and finishing with a findings report. Scripted model and a
# stand-in MCP server: plumbing only, never evidence that a model reasons.
class WorkLoopInvestigationTest < Minitest::Test
  include WorkLoopFixtures

  LOG = '02:10 aerator-2 tripped: motor overcurrent'
  PROBE = ['probe_pond_log', { 'filter' => 'aerator', 'target' => 'pond-07', 'lookback_minutes' => 60 }].freeze

  HEADER_TOOLS_AT_HEAD = '64bd09e189c92c3b800eed54cb8f56435393e9d4ea9be50c840ff5bef5690feb'
  HEADER_SYSTEM_AT_HEAD = '6eeda4bcba4edccc92422ac2caadb8ca546dd70042f3501ed954ec986c22b367'

  def investigate(turns, profile: 'plan', answers: [LOG], harness: {})
    with_work_workspace do |root, adapter|
      probes, server = ProbeFixture.source(answers)
      model = ScriptedConversationModel.new(turns:)
      session = Tamoz::Agent::Session.new(
        model:, toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: false), checkpointer: adapter,
        routing: :work, approval_engine: Tamoz::Agent.build_approval_engine(profile_name: profile),
        approval_session_id: 'work-test', artifact_store: adapter.bind_artifact_store(tenant: 'work-test'),
        artifact_tenant: 'work-test', mcp: probes, harness:
      )
      outcome = session.start('Why is pond 7 low on oxygen?', thread: 'work', request_id: 'work-1')
      yield outcome, model, server
    end
  end

  def report(evidence: ['call_1_0'], **overrides)
    ['report_findings', {
      'summary' => 'Oxygen fell after aerator-2 tripped.', 'hypothesis' => 'Aerator-2 overcurrent trip.',
      'confidence' => 'medium',
      'findings' => [{ 'statement' => 'Aerator-2 tripped at 02:10.', 'evidence' => evidence }],
      'gaps' => [{ 'datum' => 'aerator-2 current draw', 'why' => 'confirms the overcurrent' }],
      'proposals' => [{ 'action' => 'Reset aerator-2', 'rationale' => 'restores aeration', 'evidence' => evidence }]
    }.merge(overrides)]
  end

  def tools_offered(model)
    JSON.parse(model.requests.first).fetch('tools').map do |tool|
      tool.dig('function', 'name') || tool['name']
    end
  end

  def test_a_probe_then_a_grounded_report_ends_the_turn_with_the_rendered_report
    investigate([{ calls: [PROBE] }, { calls: [report] }]) do |outcome, model, server|
      verification = outcome.state.fetch(:verification)

      assert_includes tools_offered(model), 'probe_pond_log'
      assert_includes tools_offered(model), 'report_findings'
      assert_equal 'reported', outcome.state.fetch(:terminal_reason)
      assert verification.fetch('satisfied')
      assert_includes verification.fetch('answer'), 'Aerator-2 tripped at 02:10. [from probe_pond_log]'
      assert_includes verification.fetch('answer'), 'not executed'
      assert_equal 'medium', verification.fetch('report').fetch('confidence')
      assert_equal 'pond=07', server.calls.first.last.fetch('selector')
    end
  end

  def test_a_report_citing_an_ungathered_call_goes_back_to_the_model
    investigate([{ calls: [PROBE] }, { calls: [report(evidence: ['call_9_9'])] },
                 { calls: [report] }]) do |outcome, model, _|
      assert_equal 'reported', outcome.state.fetch(:terminal_reason)
      assert_match(/not a probe call that answered/, tool_results(model).last)
    end
  end

  def test_a_failed_probe_cannot_be_cited
    investigate([{ calls: [PROBE] }, { calls: [report] }, { content: 'The probe failed; nothing to report.' }],
                answers: [Tamoz::Agent::ToolError]) do |outcome, model, _|
      assert_match(/Report not accepted/, tool_results(model).last)
      refute_equal 'reported', outcome.state.fetch(:terminal_reason)
    end
  end

  def test_a_probe_turn_answering_in_free_text_is_reminded_once
    investigate([{ calls: [PROBE] }, { content: 'Aerator tripped.' },
                 { content: 'Aerator tripped.' }]) do |outcome, model, _|
      reminders = JSON.parse(model.requests.last).fetch('messages').count do |message|
        message['content'].to_s.include?('Finish with report_findings')
      end

      assert_equal 1, reminders
      assert_equal 3, model.requests.length
      assert_equal 'answered', outcome.state.fetch(:terminal_reason)
    end
  end

  def test_the_review_profile_also_allows_probes_without_asking
    investigate([{ calls: [PROBE] }, { calls: [report] }], profile: 'review') do |outcome, _, server|
      assert_equal 'reported', outcome.state.fetch(:terminal_reason)
      assert_equal 1, server.calls.length
    end
  end

  def test_without_probes_the_work_header_is_byte_identical_to_before
    with_work_workspace do |root, adapter|
      model = ScriptedConversationModel.new(turns: [{ content: 'Done.' }])
      work_session(model:, root:, adapter:).start('Hello', thread: 'work', request_id: 'work-1')
      request = JSON.parse(model.requests.first)

      assert_equal HEADER_TOOLS_AT_HEAD, Digest::SHA256.hexdigest(Tamoz::Core.jcs(request.fetch('tools')))
      assert_equal HEADER_SYSTEM_AT_HEAD, Digest::SHA256.hexdigest(request.fetch('messages').first.fetch('content'))
    end
  end

  def test_a_turn_that_may_change_files_is_not_offered_the_report
    with_work_workspace do |root, adapter|
      probes, = ProbeFixture.source([LOG])
      model = ScriptedConversationModel.new(turns: [{ calls: [PROBE] }, { content: 'Probed.' }])
      Tamoz::Agent::Session.new(
        model:, toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: true, checks: { 'test' => ['true'] }),
        checkpointer: adapter, routing: :work,
        approval_engine: Tamoz::Agent.build_approval_engine(profile_name: 'auto'),
        approval_session_id: 'work-test', artifact_store: adapter.bind_artifact_store(tenant: 'work-test'),
        artifact_tenant: 'work-test', mcp: probes
      ).start('Look, then fix it', thread: 'work', request_id: 'work-1')

      assert_includes tools_offered(model), 'probe_pond_log'
      refute_includes tools_offered(model), 'report_findings'
      assert_equal 2, model.requests.length, 'no report reminder on a turn that may change files'
    end
  end

  def test_the_report_must_be_the_last_call_of_its_step
    turns = [{ calls: [PROBE] }, { calls: [report, PROBE] }, { calls: [report] }]
    investigate(turns) do |outcome, model, server|
      assert_equal 'reported', outcome.state.fetch(:terminal_reason)
      assert_includes JSON.parse(model.requests.last).fetch('messages').map { |message| message['content'].to_s },
                      'Error: call report_findings alone, as the last call of its step.'
      assert_equal 2, server.calls.length
    end
  end

  def test_a_chat_turn_gets_the_same_probe_surface
    investigate([{ calls: [PROBE] }, { calls: [report] }], harness: { surface: :chat }) do |outcome, model, _|
      assert_includes tools_offered(model), 'probe_pond_log'
      assert_equal 'reported', outcome.state.fetch(:terminal_reason)
    end
  end

  def test_no_shipped_tool_name_can_be_mistaken_for_a_probe
    with_work_workspace do |root, _adapter|
      names = Tamoz::Agent::Toolbox.new(root:, allow_changes: true).names + Tamoz::Harness::PromptPack.tool_names +
              [Tamoz::Harness::PromptPack.report_tool.name]

      assert_empty(names.grep(/\Aprobe_/))
    end
  end
end
# rubocop:enable Metrics/AbcSize, Minitest/MultipleAssertions
