# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/durable_record_builder'
require 'digest'

class SQLiteRecordReaderTest < Minitest::Test
  CONTENT_COLUMNS = %w[payload response result error terminal_error evidence expected_tips authorization report
                       reason].freeze

  def test_reader_never_writes_the_database
    with_records do |path, _builder|
      before = Digest::SHA256.file(path).hexdigest
      reader = Tamoz::SQLite::RecordReader.open(path:)
      Tamoz::Observability::TelemetryReader::KINDS.each { |kind| reader.public_send(kind) }
      assert_raises(SQLite3::Exception) do
        reader.instance_variable_get(:@connection).execute('DELETE FROM tamoz_requests')
      end
      reader.close

      assert_equal before, Digest::SHA256.file(path).hexdigest
    end
  end

  def test_reader_returns_no_content_columns
    selected = Tamoz::SQLite::RecordReader::QUERIES.values.flat_map do |query|
      query.columns.map { |column| column.split('.').last }
    end

    assert_empty selected & CONTENT_COLUMNS
    with_records do |path, _builder|
      reader = Tamoz::SQLite::RecordReader.open(path:)
      keys = Tamoz::Observability::TelemetryReader::KINDS.flat_map { |kind| reader.public_send(kind).flat_map(&:keys) }

      assert_empty keys.uniq & CONTENT_COLUMNS
      reader.close
    end
  end

  def test_a_database_sqlite_cannot_open_raises_a_tamoz_permission_error
    skip 'root can open a mode-000 file' if Process.uid.zero?

    with_records do |path, _builder|
      File.chmod(0o000, path)

      assert_raises(Tamoz::SQLite::PermissionError) { Tamoz::SQLite::RecordReader.open(path:) }
    ensure
      File.chmod(0o600, path)
    end
  end

  def test_reader_implements_the_telemetry_reader_contract
    contract = Tamoz::Observability::TelemetryReader.instance_methods(false)

    assert_empty contract - Tamoz::SQLite::RecordReader.public_instance_methods
    assert_equal Tamoz::Observability::TelemetryReader::CONTRACT_VERSION, Tamoz::SQLite::RecordReader::CONTRACT_VERSION
  end

  def test_a_failure_exposes_only_its_class_and_code
    with_records do |path, builder|
      execution = builder.completed_turn(thread: 'thread.fail').execution_id
      secret = "sk-#{'a' * 40}"
      [
        { 'class' => 'Tamoz::Agent::ModelCallError', 'code' => 'rate_limited', 'message' => "429 #{secret}" },
        { 'message' => 'Tamoz::Agent::ToolError: crafted prefix decides nothing' },
        { 'class' => 'Tamoz::Agent::ToolError', 'code' => secret }
      ].each do |error|
        builder.effect(thread: 'thread.fail', execution_id: execution, operation: 'tool.x', outcome: :failed, error:)
      end
      reader = Tamoz::SQLite::RecordReader.open(path:)
      failures = reader.effect_attempts(thread: 'thread.fail').map { |row| row.fetch('failure') }
      reader.close

      assert_equal [{ 'class' => 'Tamoz::Agent::ModelCallError', 'code' => 'rate_limited' },
                    { 'class' => 'Tamoz::Agent::ToolError' }, { 'class' => 'unclassified' }].sort_by(&:to_s),
                   failures.sort_by(&:to_s)
      refute_includes JSON.generate(failures), secret
    end
  end

  def test_thread_filter_and_limit_bound_the_rows
    with_records do |path, builder|
      3.times { builder.completed_turn(thread: 'thread.other') }
      reader = Tamoz::SQLite::RecordReader.open(path:)

      assert_equal ['thread.a'], reader.requests(thread: 'thread.a').map { |row| row.fetch('thread_id') }.uniq
      assert_raises(Tamoz::ConfigurationError) { reader.requests(limit: 0) }
      assert_raises(Tamoz::ConfigurationError) { reader.approval_decisions(thread: 'thread.a') }
      reader.close
    end
  end

  def test_missing_or_foreign_database_is_refused
    Dir.mktmpdir do |directory|
      assert_raises(Tamoz::ConfigurationError) do
        Tamoz::SQLite::RecordReader.open(path: File.join(directory, 'absent.sqlite3'))
      end
      foreign = File.join(directory, 'foreign.sqlite3')
      SQLite3::Database.new(foreign).close
      File.chmod(0o600, foreign)
      assert_raises(Tamoz::SQLite::MigrationError) { Tamoz::SQLite::RecordReader.open(path: foreign) }
    end
  end

  def test_one_reader_keeps_one_snapshot_while_a_writer_completes_an_effect
    with_records do |path, builder|
      turn = builder.completed_turn(thread: 'snapshot')
      prepared = builder.effect(thread: 'snapshot', execution_id: turn.execution_id,
                                operation: 'tool.shell', outcome: :running)
      reader = Tamoz::SQLite::RecordReader.open(path:)

      assert_equal 'running', effect_status(reader)
      complete_effect(builder, prepared)

      assert_equal 'running', reader.effect_attempts(thread: 'snapshot').first.fetch('status')
      reader.close
      updated = Tamoz::SQLite::RecordReader.open(path:)

      assert_equal 'succeeded', effect_status(updated)
      updated.close
    end
  end

  private

  def effect_status(reader) = reader.effects(thread: 'snapshot').first.fetch('status')

  def complete_effect(builder, prepared)
    graph = Tamoz.graph(name: 'snapshot-writer', version: '1') do
      state :done, default: true
      node(:finish, implementation_name: 'snapshot.finish', version: '1') { { done: true } }
      edge Tamoz::START, :finish
      edge :finish, Tamoz::END
    end
    store = graph.compile(checkpointer: builder.adapter).checkpointer
    store.open_writer(thread_id: 'snapshot', namespace: [], owner_id: 'builder', ttl: store.writer_ttl) do |writer|
      writer.effects.complete(key: prepared.record.key, attempt_token: prepared.attempt_token,
                              status: :succeeded, result: { 'ok' => true })
    end
  end

  def with_records
    Dir.mktmpdir('tamoz-record-reader') do |directory|
      path = File.join(directory, 'runtime.sqlite3')
      DurableRecordBuilder.open(path) do |builder|
        turn = builder.completed_turn(thread: 'thread.a')
        builder.effect(thread: 'thread.a', execution_id: turn.execution_id, operation: 'tool.read_file',
                       outcome: :succeeded)
        builder.paused_turn(thread: 'thread.paused')
        builder.failed_turn(thread: 'thread.failed')
        builder.approval(verdict: 'ask', answer: 'approve')
        yield path, builder
      end
    end
  end
end
