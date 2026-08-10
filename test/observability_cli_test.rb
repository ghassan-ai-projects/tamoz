# frozen_string_literal: true

require_relative 'test_helper'

class ObservabilityCLITest < Minitest::Test
  def test_observe_commands_read_the_local_journal
    Dir.mktmpdir do |directory|
      write_journal(directory)

      tail_out = StringIO.new
      assert_equal 0, Tamoz::Agent::CLI.run(
        ['--runtime-dir', directory, '--json', 'observe', 'tail'],
        out: tail_out,
        err: StringIO.new,
        env: {}
      )
      assert_equal 'tamoz.worker.request.completed', JSON.parse(tail_out.string).fetch('name')

      metrics_out = StringIO.new
      assert_equal 0, Tamoz::Agent::CLI.run(
        ['--runtime-dir', directory, '--json', 'observe', 'metrics'],
        out: metrics_out,
        err: StringIO.new,
        env: {}
      )
      assert_equal %w[counters gauges histograms violations].sort,
                   JSON.parse(metrics_out.string).keys.sort

      doctor_out = StringIO.new
      assert_equal 0, Tamoz::Agent::CLI.run(
        ['--runtime-dir', directory, '--json', 'observe', 'doctor'],
        out: doctor_out,
        err: StringIO.new,
        env: {}
      )
      assert_equal true, JSON.parse(doctor_out.string).fetch('redaction')
    end
  end

  def test_trace_command_reconstructs_a_deterministic_trace_from_the_journal
    Dir.mktmpdir do |directory|
      write_journal(directory)

      out = StringIO.new
      assert_equal 0, Tamoz::Agent::CLI.run(
        ['--runtime-dir', directory, '--json', 'trace', 'thread.1', '--execution', 'execution.1'],
        out:,
        err: StringIO.new,
        env: {}
      )
      document = JSON.parse(out.string)
      assert_equal Tamoz::Observability::Correlation.trace_id(
        thread_id: 'thread.1', execution_id: 'execution.1'
      ), document.fetch('trace_id')
      assert_equal 1, document.fetch('spans').length
    end
  end

  private

  def write_journal(directory)
    journal = Tamoz::Observability::Recorder::Journal.new(
      directory:, role: 'cli-test', max_file_bytes: 16_384
    )
    producer = Tamoz::Observability::Producer.new(recorder: journal, clock: -> { 10 })
    producer.emit(
      'tamoz.worker.request.completed',
      correlation: {
        thread_id: 'thread.1', execution_id: 'execution.1', request_id: 'request.1',
        occurrence_id: 'occurrence.1'
      }
    )
    assert_equal 0, journal.flush(deadline_ms: 1_000)
    journal.close
  end
end
