# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/durable_record_builder'

class SelfObservationTest < Minitest::Test
  def test_an_unreadable_database_is_skipped_and_marks_the_report_degraded
    with_unreadable_databases do |observation|
      now = (Time.now.to_f * 1000).to_i
      report = observation.diagnose(now_ms: now, since_ms: now - 3_600_000)

      assert_equal(%w[thread-one.sqlite3 thread-two.sqlite3], report.sources.map { |source| source.fetch('name') })
      assert_equal %w[corrupt memory], skipped_databases(report)
    end
  end

  def test_explain_finds_its_thread_past_an_unreadable_database
    with_unreadable_databases do |observation|
      assert_equal 'thread-two', observation.explain(thread: 'thread-two', now_ms: 0).fetch('thread_id')
    end
  end

  def test_a_thread_not_found_names_the_databases_it_skipped
    with_unreadable_databases do |observation|
      error = assert_raises(Tamoz::Agent::SelfObservation::Error) { observation.explain(thread: 'none', now_ms: 0) }

      assert_match(/skipped corrupt\.sqlite3: .*skipped memory\.sqlite3: /, error.message)
    end
  end

  def test_diagnosis_with_no_readable_database_is_an_error
    Dir.mktmpdir('tamoz-sessions') do |directory|
      File.chmod(0o700, directory)
      File.write(File.join(directory, 'corrupt.sqlite3'), 'not a database' * 100, perm: 0o600)
      observation = Tamoz::Agent::SelfObservation.open(session_dir: directory)

      error = assert_raises(Tamoz::Agent::SelfObservation::Error) { observation.diagnose(now_ms: 1, since_ms: 0) }
      assert_match(/\Ano readable Tamoz database: corrupt\.sqlite3: /, error.message)
    end
  end

  private

  def with_unreadable_databases
    Dir.mktmpdir('tamoz-sessions') do |directory|
      File.chmod(0o700, directory)
      %w[thread-one thread-two].each do |thread|
        DurableRecordBuilder.open(File.join(directory, "#{thread}.sqlite3")) { |builder| builder.failed_turn(thread:) }
      end
      File.write(File.join(directory, 'corrupt.sqlite3'), 'not a database' * 100, perm: 0o600)
      foreign = File.join(directory, 'memory.sqlite3')
      SQLite3::Database.new(foreign).tap { |database| database.execute('CREATE TABLE m(x)') }.close
      File.chmod(0o600, foreign)
      yield Tamoz::Agent::SelfObservation.open(session_dir: directory)
    end
  end

  def skipped_databases(report)
    report.degraded_reasons.filter_map { |reason| reason[/\Askipped unreadable database (\w+)\.sqlite3: /, 1] }
  end
end
