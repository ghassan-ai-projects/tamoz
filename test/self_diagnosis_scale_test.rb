# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/durable_record_builder'
require 'tamoz/agent_cli'

class SelfDiagnosisScaleTest < Minitest::Test
  EFFECTS = 20_000
  BUDGET_SECONDS = 3.0

  def test_diagnose_reads_and_judges_twenty_thousand_effects_within_budget
    Dir.mktmpdir('tamoz-scale') do |directory|
      File.chmod(0o700, directory)
      path = File.join(directory, 'runtime.sqlite3')
      seed_effects(path)
      report, elapsed = measured_diagnosis(directory)

      assert_equal EFFECTS, report.sources.first.fetch('rows').fetch('effects')
      assert_equal EFFECTS, report.findings.find { |finding| finding.rule_id == 'effect.repeated_failure' }.count
      assert_operator elapsed, :<, BUDGET_SECONDS
    end
  end

  private

  def measured_diagnosis(directory)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    now = (Time.now.to_f * 1000).to_i
    report = Tamoz::Agent::SelfObservation.open(runtime_dir: directory).diagnose(now_ms: now,
                                                                                 since_ms: now - 3_600_000)
    [report, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def seed_effects(path)
    DurableRecordBuilder.open(path) do |builder|
      turn = builder.completed_turn(thread: 'thread.a')
      builder.effect(thread: 'thread.a', execution_id: turn.execution_id, operation: 'model.generate.plan',
                     outcome: :failed, error: { 'class' => 'Tamoz::Agent::ModelCallError', 'code' => 'rate_limited' })
    end
    multiply_effects(path)
  end

  def multiply_effects(path)
    database = SQLite3::Database.new(path)
    database.transaction do
      (EFFECTS - 1).times do |index|
        database.execute(<<~SQL, ["copy.#{index}"])
          INSERT INTO tamoz_effects
          SELECT ? || effect_key, thread_id, namespace, execution_id, task_id, call_index, operation, safety,
                 request_digest, status, current_attempt, requires_reconciliation, created_at_ms, updated_at_ms,
                 NULL, request_id
          FROM tamoz_effects LIMIT 1
        SQL
        database.execute(<<~SQL, ["copy.#{index}", "token.#{index}"])
          INSERT INTO tamoz_effect_attempts
          SELECT ?1 || effect_key, attempt_number, ?2, fence, status, deadline_ms, result, result_digest, external_id,
                 error, error_digest, prepared_at_ms, started_at_ms, completed_at_ms, NULL
          FROM tamoz_effect_attempts WHERE effect_key NOT LIKE 'copy.%' LIMIT 1
        SQL
      end
    end
  ensure
    database&.close
  end
end
