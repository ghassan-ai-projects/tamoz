# frozen_string_literal: true

require_relative 'test_helper'

class GraphDurableRequestExecutorTest < Minitest::Test
  RequestRecord = Tamoz::Graph::RequestRecord
  Execution = Tamoz::Graph::DurableRequestExecution

  REQUEST_FIELDS = {
    thread_id: 'thread.a', namespace: [], request_id: 'request.1', enqueue_sequence: 1,
    input_digest: "sha256:#{'a' * 64}", operation: :continue, delivery_mode: :queue,
    status: :claimed, payload: {}, execution_id: 'execution.1', target_execution_id: nil,
    cancellation_generation: 0, checkpoint_id: nil, response: nil, terminal_error: nil,
    retryable: false, created_at_ms: 0, updated_at_ms: 0
  }.freeze

  class RecordingCompiled
    attr_reader :calls

    def initialize(latest_status: :running)
      @latest_status = latest_status
      @calls = []
    end

    def validate_concurrency!(value)
      calls << [:validate_concurrency, value]
    end

    def latest_status(request, writer:)
      calls << [:latest_status, request, writer]
      @latest_status
    end

    def continue_with_writer(**arguments)
      calls << [:continue_with_writer, arguments]
      :continued
    end
  end

  def test_running_resume_continues_when_the_latest_checkpoint_is_running
    compiled = RecordingCompiled.new
    request = build_request(operation: :resume, status: :running)

    result = execute(compiled, request)

    assert_equal :continued, result
    call = compiled.calls.find { |name, _| name == :continue_with_writer }

    refute_nil call
    refute call.last.fetch(:mark_request_running)
  end

  def test_continue_marks_only_a_claimed_request_running
    { claimed: true, running: false }.each do |status, expected|
      compiled = RecordingCompiled.new

      execute(compiled, build_request(status:))

      call = compiled.calls.find { |name, _| name == :continue_with_writer }

      assert_equal expected, call.last.fetch(:mark_request_running), status
    end
  end

  private

  def build_request(**overrides)
    RequestRecord.new(**REQUEST_FIELDS, **overrides)
  end

  def execute(compiled, request)
    execution = Execution.new(request, Object.new, :inline, nil)
    Tamoz::Graph::DurableRequestExecutor.new(compiled).execute(execution)
  end
end
