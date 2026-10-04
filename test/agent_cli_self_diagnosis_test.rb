# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/durable_record_builder'
require 'digest'
require 'tamoz/agent_cli'

class AgentCLISelfDiagnosisTest < Minitest::Test
  MODEL_FAILURE = { 'class' => 'Tamoz::Agent::ModelCallError', 'code' => 'insufficient_balance',
                    'message' => '402' }.freeze
  ANALYSIS = {
    'summary' => 'The provider account ran out of balance.', 'hypothesis' => 'insufficient_balance',
    'confidence' => 'high', 'gaps' => [], 'proposals' => [],
    'findings' => [{ 'statement' => 'Three plan calls failed with 402', 'evidence' => ['call_1'] }]
  }.freeze

  def test_diagnose_reads_a_worker_runtime_directory_in_markdown
    with_runtime do |directory|
      status, out, = cli('--runtime-dir', directory, 'diagnose')

      assert_equal 0, status
      assert_includes out, '# Tamoz self-diagnosis'
      assert_includes out, 'Tamoz::Agent::ModelCallError · insufficient_balance'
    end
  end

  def test_diagnose_reads_a_worker_runtime_directory_in_json
    with_runtime do |directory|
      status, out, = cli('--runtime-dir', directory, 'diagnose', '--json', '--since', '1h')
      report = JSON.parse(out)

      assert_equal 0, status
      assert_includes report.fetch('findings').map { |finding| finding.fetch('rule_id') }, 'effect.outcome_unknown'
      assert_equal(['runtime.sqlite3'], report.fetch('sources').map { |source| source.fetch('name') })
    end
  end

  def test_diagnose_reads_every_database_of_a_session_directory
    with_session_databases do |directory|
      status, out, = cli('--session-dir', directory, 'diagnose', '--json')
      report = JSON.parse(out)

      assert_equal 0, status
      assert_equal(%w[thread-one.sqlite3 thread-two.sqlite3], report.fetch('sources').map do |source|
        source.fetch('name')
      end)
      assert_equal 2, report.fetch('findings').find { |finding|
        finding.fetch('rule_id') == 'request.failed'
      }.fetch('count')
    end
  end

  def test_explain_attributes_the_effect_failure
    with_explanation do |status, record|
      effect = record.fetch('executions').first.fetch('effects').first

      assert_equal 0, status
      assert_equal 'insufficient_balance', effect.fetch('attempts').first.fetch('failure').fetch('code')
    end
  end

  def test_explain_attributes_policy_and_actor_and_marks_unanswered_approval
    with_explanation do |_status, record|
      approvals = record.fetch('approvals')
      decisions = approvals.fetch('decisions')
      answered = decisions.find { |entry| entry.fetch('decision') == 'approve' }

      assert_equal 'database', approvals.fetch('link')
      assert_equal %w[approve policy_deny unanswered], decisions.map { |entry| entry.fetch('decision') }.sort
      assert_equal %w[rev.7 cli_tty], answered.values_at('policy_rev', 'actor_evidence')
    end
  end

  def test_postmortem_writes_files_and_embeds_an_analysis
    with_postmortem do |status, paths, _out_dir|
      document = JSON.parse(File.read(paths.fetch('json'), encoding: Encoding::UTF_8))

      assert_equal 0, status
      assert_equal 'insufficient_balance', document.dig('analysis', 'hypothesis')
      assert_equal 'investigation-1', document.dig('analysis', 'thread_id')
    end
  end

  def test_postmortem_markdown_names_the_failure_and_writes_only_in_out
    with_postmortem do |_status, paths, out_dir|
      markdown = File.read(paths.fetch('markdown'), encoding: Encoding::UTF_8)

      assert_includes markdown, '# Postmortem: Provider outage'
      assert_includes markdown, 'model.generate.plan failed — Tamoz::Agent::ModelCallError/insufficient_balance'
      assert_equal [paths.fetch('json'), paths.fetch('markdown')].sort, Dir.glob(File.join(out_dir, '*'))
    end
  end

  def test_commands_never_change_the_database
    with_runtime do |directory|
      database = File.join(directory, 'runtime.sqlite3')
      before = Digest::SHA256.file(database).hexdigest
      cli('--runtime-dir', directory, 'diagnose', '--json')
      cli('--runtime-dir', directory, 'explain', 'thread.a', '--json')
      cli('--runtime-dir', directory, 'postmortem', '--title', 't', '--out', File.join(directory, 'pm'))

      assert_equal before, Digest::SHA256.file(database).hexdigest
    end
  end

  def test_a_missing_database_is_a_typed_error
    Dir.mktmpdir('tamoz-empty') do |directory|
      File.chmod(0o700, directory)
      status, _out, err = cli('--runtime-dir', directory, 'diagnose')

      assert_equal 1, status
      assert_includes err, 'no Tamoz database found'
    end
  end

  def test_bad_thread_and_command_arguments_end_typed
    with_runtime do |directory|
      assert_equal 1, cli('--runtime-dir', directory, 'explain', 'thread.missing').first
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR,
                   cli('--runtime-dir', directory, 'diagnose', '--since', 'yesterday').first
      assert_equal Tamoz::Agent::CLI::USAGE_ERROR, cli('--runtime-dir', directory, 'explain').first
    end
  end

  def test_invalid_analysis_documents_end_typed
    with_runtime do |directory|
      bad = File.join(directory, 'bad.json')
      ['{}', '[]', JSON.generate(ANALYSIS.merge('findings' => ['x']))].each do |content|
        File.write(bad, content)
        status, _out, err = cli('--runtime-dir', directory, 'postmortem', '--title', 't', '--out', directory,
                                '--analysis', bad)

        assert_equal 1, status, content
        assert_includes err, 'not a findings report'
      end
    end
  end

  def test_postmortem_leaves_an_existing_out_directory_mode_alone
    with_runtime do |directory|
      out_dir = File.join(directory, 'shared')
      Dir.mkdir(out_dir)
      File.chmod(0o755, out_dir)
      status, = cli('--runtime-dir', directory, 'postmortem', '--title', 't', '--out', out_dir)

      assert_equal 0, status
      assert_equal 0o755, File.stat(out_dir).mode & 0o777
      assert_equal 1, cli('--runtime-dir', directory, 'postmortem', '--title', 't', '--out', '/proc/none/x').first
    end
  end

  def test_explain_declares_when_an_independent_row_limit_is_reached
    with_runtime do |directory|
      observation = Tamoz::Agent::SelfObservation.open(runtime_dir: directory, limit: 2)
      explained = observation.explain(thread: 'thread.a', now_ms: (Time.now.to_f * 1000).to_i)

      assert_includes explained.fetch('truncated'), 'effects'
    end
  end

  def test_a_request_specific_explanation_uses_its_own_approval_window
    records = { 'requests' => [{ 'thread_id' => 't', 'request_id' => 'r1', 'created_at_ms' => 10,
                                 'updated_at_ms' => 20, 'status' => 'completed' }],
                'effects' => [], 'effect_attempts' => [], 'checkpoints' => [],
                'approval_decisions' => [{ 'decision_id' => 'other', 'created_at_ms' => 30 }] }
    record = Tamoz::Observability::Explanation.build(records, thread: 't', request: 'r1', approval_link: :database)

    assert_empty record.dig('approvals', 'decisions')
    assert_equal 'time_window', record.dig('approvals', 'link')
  end

  def test_an_unreadable_journal_is_a_typed_error
    with_runtime do |directory|
      journal = File.join(directory, 'worker-1.ndjson')
      File.write(journal, "{}\n")
      File.chmod(0o000, journal)
      status, _out, err = cli('--runtime-dir', directory, 'diagnose')

      assert_equal 1, status
      assert_includes err, 'cannot be read'
    ensure
      File.chmod(0o600, journal) if journal && File.exist?(journal)
    end
  end

  def test_an_approval_answered_during_a_resume_or_asked_while_running_is_kept
    resume = { 'thread_id' => 't', 'request_id' => 'resume', 'created_at_ms' => 50, 'updated_at_ms' => 60,
               'status' => 'completed' }
    running = { 'thread_id' => 't', 'request_id' => 'running', 'created_at_ms' => 70, 'updated_at_ms' => 71,
                'status' => 'running' }
    decisions = [{ 'decision_id' => 'answered', 'verdict' => 'ask', 'answer' => 'approve', 'created_at_ms' => 40,
                   'resolved_at_ms' => 55 },
                 { 'decision_id' => 'pending', 'verdict' => 'ask', 'created_at_ms' => 90 }]
    records = { 'requests' => [resume, running], 'effects' => [], 'effect_attempts' => [], 'checkpoints' => [],
                'approval_decisions' => decisions }
    build = lambda do |request|
      Tamoz::Observability::Explanation.build(records, thread: 't', request:, approval_link: :time_window, now_ms: 100)
                                       .dig('approvals', 'decisions').map { |entry| entry.fetch('decision_id') }
    end

    assert_equal ['answered'], build.call('resume')
    assert_equal ['pending'], build.call('running')
  end

  def test_request_specific_effects_do_not_include_a_later_request_in_the_same_execution
    records = { 'requests' => [{ 'thread_id' => 't', 'request_id' => 'r1', 'execution_id' => 'shared',
                                 'created_at_ms' => 10, 'updated_at_ms' => 20, 'status' => 'completed' }],
                'effects' => [{ 'effect_key' => 'first', 'execution_id' => 'shared', 'request_id' => 'r1',
                                'created_at_ms' => 11 },
                              { 'effect_key' => 'later', 'execution_id' => 'shared', 'request_id' => 'r2',
                                'created_at_ms' => 30 }],
                'effect_attempts' => [], 'checkpoints' => [], 'approval_decisions' => [] }
    record = Tamoz::Observability::Explanation.build(records, thread: 't', request: 'r1', approval_link: :database)

    assert_equal(['first'], record.fetch('executions').first.fetch('effects').map { |row| row.fetch('effect_key') })
    assert_equal 'r1', record.fetch('executions').first.fetch('effects').first.fetch('request_id')
  end

  private

  def with_session_databases
    Dir.mktmpdir('tamoz-sessions') do |directory|
      File.chmod(0o700, directory)
      %w[thread-one thread-two].each do |thread|
        DurableRecordBuilder.open(File.join(directory, "#{thread}.sqlite3")) { |builder| builder.failed_turn(thread:) }
      end
      yield directory
    end
  end

  def with_explanation
    Dir.mktmpdir('tamoz-explain') do |directory|
      File.chmod(0o700, directory)
      DurableRecordBuilder.open(File.join(directory, 'thread-x.sqlite3')) do |builder|
        turn = builder.completed_turn(thread: 'thread-x', request: 'request.1')
        builder.effect(thread: 'thread-x', execution_id: turn.execution_id, operation: 'model.generate.plan',
                       outcome: :failed, error: MODEL_FAILURE)
        builder.approval(verdict: 'ask', answer: 'approve', policy_rev: 'rev.7')
        builder.approval(verdict: 'ask')
        builder.approval(verdict: 'deny')
      end
      status, out, = cli('--session-dir', directory, 'explain', 'thread-x', '--json')
      yield status, JSON.parse(out)
    end
  end

  def with_postmortem
    with_runtime do |directory|
      analysis = File.join(directory, 'analysis.json')
      File.write(analysis, JSON.generate('thread_id' => 'investigation-1', 'report' => ANALYSIS))
      out_dir = File.join(directory, 'postmortems')
      status, out, = cli('--runtime-dir', directory, 'postmortem', '--title', 'Provider outage', '--out', out_dir,
                         '--analysis', analysis, '--json')
      yield status, JSON.parse(out), out_dir
    end
  end

  def with_runtime
    Dir.mktmpdir('tamoz-runtime') do |directory|
      File.chmod(0o700, directory)
      DurableRecordBuilder.open(File.join(directory, 'runtime.sqlite3')) do |builder|
        turn = builder.completed_turn(thread: 'thread.a')
        builder.effect(thread: 'thread.a', execution_id: turn.execution_id, operation: 'model.generate.plan',
                       outcome: :succeeded)
        3.times do
          builder.effect(thread: 'thread.a', execution_id: turn.execution_id, operation: 'model.generate.plan',
                         outcome: :failed, error: MODEL_FAILURE)
        end
        builder.effect(thread: 'thread.a', execution_id: turn.execution_id, operation: 'tool.mcp.write',
                       outcome: :unknown)
      end
      yield directory
    end
  end

  def cli(*argv)
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(argv, out:, err:, env: {})
    [status, out.string, err.string]
  end
end
