# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/durable_record_builder'

class SelfDiagnosisTest < Minitest::Test
  Diagnosis = Tamoz::Observability::Diagnosis
  HOUR_MS = 3_600_000
  NO_JOURNAL = { documents: [], drops: {}, unreadable: [] }.freeze

  def test_clean_runtime_has_no_findings
    report = diagnose { |builder| healthy_activity(builder) }

    assert_empty report.findings
    refute_predicate report, :degraded?
  end

  def test_unknown_effect_is_a_critical_finding_with_its_row_as_evidence
    report = diagnose do |builder|
      execution = healthy_activity(builder)
      builder.effect(thread: 'thread.a', execution_id: execution, operation: 'tool.mcp.write',
                     outcome: :unknown, error: { 'class' => 'Tamoz::MCP::TransportError', 'code' => 'transport_timeout',
                                                 'message' => 'timeout' })
    end
    finding = finding(report, 'effect.outcome_unknown')

    assert_equal 'critical', finding.severity
    assert_equal(['tool.mcp.write'], finding.evidence.map { |entry| entry.fetch('operation') })
    assert_equal({ 'class' => 'Tamoz::MCP::TransportError', 'code' => 'transport_timeout' },
                 finding.evidence.first.fetch('failure'))
    write = report.summary.fetch('operations').find { |line| line.fetch('operation') == 'tool.mcp.write' }
    assert_equal [0, 1], write.values_at('failed', 'unknown')
    assert_equal report.findings.first, finding
  end

  def test_model_failure_rate_and_repeated_failure_name_the_error_class
    report = diagnose do |builder|
      execution = healthy_activity(builder)
      3.times do
        builder.effect(thread: 'thread.a', execution_id: execution, operation: 'model.generate.plan',
                       outcome: :failed, error: { 'class' => 'Tamoz::Agent::ModelCallError',
                                                  'code' => 'rate_limited', 'message' => '429' })
      end
    end
    rate = finding(report, 'model.failure_rate')

    assert_equal({ 'settled' => 5, 'failed' => 3, 'by_operation' => { 'model.generate.plan' => 3 } }, rate.detail)
    group = finding(report, 'effect.repeated_failure')

    assert_equal({ 'failure' => 'Tamoz::Agent::ModelCallError/rate_limited' }, group.detail)
    assert_equal 3, group.count
  end

  def test_age_rules_fire_only_past_their_threshold_on_the_injected_clock
    records = records_for do |builder|
      execution = healthy_activity(builder)
      builder.effect(thread: 'thread.a', execution_id: execution, operation: 'tool.shell', outcome: :running)
      builder.approval(verdict: 'ask')
    end
    now = (Time.now.to_f * 1000).to_i

    assert_empty diagnose_records(records, now_ms: now).findings
    later = diagnose_records(records, now_ms: now + (5 * HOUR_MS))

    assert_equal %w[approval.waiting effect.stuck], later.findings.map(&:rule_id).sort
  end

  def test_an_unreadable_health_file_marks_the_report_degraded
    records = records_for { |builder| healthy_activity(builder) }
    report = diagnose_records(records, journal: NO_JOURNAL.merge(unreadable: ['worker-2.ndjson.health.json']))

    assert_predicate report, :degraded?
    assert_includes report.degraded_reasons.join, 'worker-2.ndjson.health.json cannot be read'
  end

  def test_an_answered_approval_is_not_waiting
    records = records_for { |builder| builder.approval(verdict: 'ask', answer: 'approve') }
    later = diagnose_records(records, now_ms: (Time.now.to_f * 1000).to_i + (5 * HOUR_MS))

    refute_includes later.findings.map(&:rule_id), 'approval.waiting'
  end

  def test_detectors_never_classify_by_free_text
    report = diagnose do |builder|
      execution = healthy_activity(builder)
      ['socket closed', 'connection reset by peer', 'EOF'].each do |message|
        builder.effect(thread: 'thread.a', execution_id: execution, operation: 'tool.mcp.query',
                       outcome: :failed, error: { 'class' => 'Tamoz::MCP::TransportError', 'message' => message })
      end
      builder.effect(thread: 'thread.a', execution_id: execution, operation: 'tool.mcp.query', outcome: :failed,
                     error: { 'class' => 'Tamoz::MCP::ProtocolError', 'message' => 'socket closed' })
    end
    groups = report.findings.select { |finding| finding.rule_id == 'effect.repeated_failure' }

    assert_equal [{ 'failure' => 'Tamoz::MCP::TransportError' }], groups.map(&:detail)
  end

  def test_telemetry_loss_marks_the_report_degraded
    records = records_for { |builder| healthy_activity(builder) }
    drops = { 'tamoz.model.call:queue_full:bulk' => 3 }
    report = diagnose_records(records, journal: NO_JOURNAL.merge(drops:))

    assert_predicate report, :degraded?
    assert_equal ['the telemetry journal counted 3 dropped signals'], report.degraded_reasons
    assert_equal 3, finding(report, 'telemetry.loss').count
  end

  def test_journal_errors_become_findings_within_the_window
    now = (Time.now.to_f * 1000).to_i
    documents = [
      { 'name' => 'tamoz.worker.error', 'observed_at_ms' => now - 1000, 'attributes' => { 'reason' => 'claim' } },
      { 'name' => 'tamoz.worker.error', 'observed_at_ms' => now - (48 * HOUR_MS) },
      { 'name' => 'tamoz.worker.started', 'observed_at_ms' => now - 1000 }
    ]
    records = records_for { |builder| healthy_activity(builder) }
    report = diagnose_records(records, now_ms: now, journal: { documents:, drops: {}, unreadable: [] })

    assert_equal 1, finding(report, 'worker.errors').count
  end

  def test_row_limit_marks_the_report_degraded
    records = records_for { |builder| healthy_activity(builder) }
    source = Diagnosis::Source.new(name: 'runtime.sqlite3', records:, limit: 1)
    report = Diagnosis.run(sources: [source], journal: NO_JOURNAL, now_ms: (Time.now.to_f * 1000).to_i, since_ms: 0)

    assert_predicate report, :degraded?
    assert_includes report.degraded_reasons, 'runtime.sqlite3: effects reached the row limit 1'
  end

  def test_timeline_puts_a_question_before_its_answer
    now = (Time.now.to_f * 1000).to_i
    approval = { 'decision_id' => 'd1', 'tool' => 'write_file', 'verdict' => 'ask', 'answer' => 'approve',
                 'created_at_ms' => now, 'resolved_at_ms' => now }
    records = Tamoz::Observability::TelemetryReader::KINDS.to_h { |kind| [kind.to_s, []] }
                                                          .merge('approval_decisions' => [approval])
    timeline = Tamoz::Observability::Timeline.build(records, journal_documents: [], journal_names: [],
                                                             since_ms: now - HOUR_MS, until_ms: now + HOUR_MS)

    assert_equal(['write_file ask', 'write_file approve'], timeline.fetch('events').map { |event| event.fetch('what') })
  end

  def test_rows_after_the_window_end_are_not_counted
    records = records_for do |builder|
      execution = healthy_activity(builder)
      3.times do
        builder.effect(thread: 'thread.a', execution_id: execution, operation: 'tool.mcp.query',
                       outcome: :failed, error: { 'class' => 'Tamoz::MCP::TransportError' })
      end
    end
    report = diagnose_records(records, now_ms: (Time.now.to_f * 1000).to_i - (2 * HOUR_MS))

    assert_empty report.findings
    assert_empty report.summary.fetch('effects')
  end

  def test_report_is_deterministic
    records = records_for do |builder|
      execution = healthy_activity(builder)
      builder.effect(thread: 'thread.a', execution_id: execution, operation: 'tool.x', outcome: :unknown)
    end
    now = (Time.now.to_f * 1000).to_i

    assert_equal diagnose_records(records, now_ms: now).to_json, diagnose_records(records, now_ms: now).to_json
  end

  def test_a_requested_event_does_not_claim_a_later_failure
    records = Tamoz::Observability::TelemetryReader::KINDS.to_h { |kind| [kind.to_s, []] }
    records['requests'] = [{ 'thread_id' => 'later', 'request_id' => 'r', 'operation' => 'turn',
                             'status' => 'failed', 'created_at_ms' => 100, 'updated_at_ms' => 300,
                             'failure' => { 'class' => 'Error' } }]
    timeline = Tamoz::Observability::Timeline.build(records, journal_documents: [], journal_names: [],
                                                             since_ms: 0, until_ms: 200)

    assert_empty timeline.fetch('threads_with_failures')
    refute timeline.fetch('events').first.key?('failure')
  end

  def test_age_findings_ignore_rows_created_after_the_window_end
    records = Tamoz::Observability::TelemetryReader::KINDS.to_h { |kind| [kind.to_s, []] }
    records['approval_decisions'] = [{ 'decision_id' => 'later', 'verdict' => 'ask', 'created_at_ms' => 100 }]
    report = diagnose_records(records, now_ms: 0)

    assert_empty report.findings
  end

  def test_terminal_failures_and_latencies_belong_to_the_completion_window
    records = delayed_completion_records
    earlier = diagnosis_window(records, 0, 200)
    later = diagnosis_window(records, 200, 400)

    assert_empty earlier.findings
    assert_empty earlier.summary.fetch('operations')
    assert_equal [1, 200], [later.findings.find { |entry| entry.rule_id == 'model.call_failed' }.count,
                            later.summary.fetch('operations').first.fetch('p95_ms')]
  end

  private

  def delayed_completion_records
    records = Tamoz::Observability::TelemetryReader::KINDS.to_h { |kind| [kind.to_s, []] }
    records['effect_attempts'] = [{ 'effect_key' => 'delayed', 'attempt_number' => 1, 'status' => 'failed',
                                    'prepared_at_ms' => 100, 'started_at_ms' => 100, 'completed_at_ms' => 300,
                                    'failure' => { 'class' => 'Error', 'code' => 'provider_error' } }]
    records['effects'] = [{ 'effect_key' => 'delayed', 'thread_id' => 't', 'operation' => 'model.generate.plan',
                            'status' => 'failed', 'updated_at_ms' => 300 }]
    records
  end

  def diagnosis_window(records, since_ms, now_ms)
    source = Diagnosis::Source.new(name: 'runtime.sqlite3', records:, limit: 1_000)
    Diagnosis.run(sources: [source], journal: NO_JOURNAL, now_ms:, since_ms:)
  end

  def healthy_activity(builder)
    turn = builder.completed_turn(thread: 'thread.a')
    2.times do
      builder.effect(thread: 'thread.a', execution_id: turn.execution_id, operation: 'model.generate.plan',
                     outcome: :succeeded)
    end
    builder.effect(thread: 'thread.a', execution_id: turn.execution_id, operation: 'tool.read_file',
                   outcome: :succeeded)
    builder.approval(verdict: 'ask', answer: 'approve')
    turn.execution_id
  end

  def diagnose(&)
    diagnose_records(records_for(&))
  end

  def diagnose_records(records, now_ms: (Time.now.to_f * 1000).to_i, journal: NO_JOURNAL)
    source = Diagnosis::Source.new(name: 'runtime.sqlite3', records:, limit: 1_000)
    Diagnosis.run(sources: [source], journal:, now_ms:, since_ms: now_ms - (24 * HOUR_MS))
  end

  def records_for(&block)
    Dir.mktmpdir('tamoz-diagnosis') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      DurableRecordBuilder.open(path, &block)
      reader = Tamoz::SQLite::RecordReader.open(path:)
      Tamoz::Observability::TelemetryReader::KINDS.to_h { |kind| [kind.to_s, reader.public_send(kind)] }
    ensure
      reader&.close
    end
  end

  def finding(report, rule_id)
    report.findings.find do |entry|
      entry.rule_id == rule_id
    end || flunk("no #{rule_id} in #{report.findings.map(&:rule_id)}")
  end
end
