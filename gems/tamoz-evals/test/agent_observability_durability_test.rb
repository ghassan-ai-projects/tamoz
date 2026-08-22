# frozen_string_literal: true

require_relative '../../../test/test_helper'

# Verifies worker observability survives abrupt process loss.
class AgentObservabilityDurabilityTest < Minitest::Test
  def test_cli_worker_uses_the_durable_recorder
    Dir.mktmpdir('observability-recorder') do |directory|
      cli = Tamoz::Agent::CLI.new(
        out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {}
      )
      runtime = Struct.new(:path).new(directory)

      recorder = cli.send(:observability_recorder, runtime)

      assert_instance_of durable_recorder, recorder

      recorder.close
    end
  end

  def test_worker_span_is_written_before_sigkill
    Dir.mktmpdir('observability-kill') do |directory|
      pid = Process.fork { emit_model_call_then_kill(directory) }

      _, status = Process.waitpid2(pid)

      assert_predicate status, :signaled?

      assert_equal Signal.list.fetch('KILL'), status.termsig

      documents = Tamoz::Observability::Recorder::Journal.read(
        directory, thread_id: 'kill-thread'
      )

      names = documents.map { |document| document.fetch('name') }

      assert_equal ['tamoz.model.call'], names
    end
  end

  private

  def emit_model_call_then_kill(directory)
    journal = Tamoz::Observability::Recorder::Journal.new(
      directory:, role: 'worker', flush_interval_ms: 60_000
    )
    recorder = durable_recorder.new(recorder: journal)
    model_call = Tamoz::Observability::ModelCall.new(
      producer: Tamoz::Observability::Producer.new(recorder:),
      provider: 'test',
      model: 'test-model'
    )
    model_call.emit(correlation: correlation, started_at_ms: 1, ended_at_ms: 2)
    Process.kill('KILL', Process.pid)
  end

  def correlation
    {
      thread_id: 'kill-thread', execution_id: 'execution-1', request_id: 'request-1',
      task_id: 'task-1'
    }
  end

  def durable_recorder
    Tamoz::Agent.const_get(:DurableRecorder, false)
  end
end
