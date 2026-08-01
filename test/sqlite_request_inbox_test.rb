# frozen_string_literal: true

require_relative "test_helper"

class SQLiteRequestInboxTest < Minitest::Test
  def test_duplicate_delivery_returns_one_completed_turn_and_conflicts_on_change
    with_runner do |_adapter, app, runner|
      first = runner.deliver(
        {"input" => "one"},
        thread: "thread.duplicate",
        request_id: "request.same"
      )
      duplicate = runner.deliver(
        {"input" => "one"},
        thread: "thread.duplicate",
        request_id: "request.same"
      )

      assert first.terminal?
      assert_equal :completed, first.status
      assert_equal first, duplicate
      assert_equal 2, app.history(thread: "thread.duplicate").length
      assert_raises(Tamoz::CheckpointConflictError) do
        runner.submit(
          {"input" => "different"},
          thread: "thread.duplicate",
          request_id: "request.same"
        )
      end
    end
  end

  def test_fifo_claim_processes_no_later_request_before_earlier_one
    with_runner do |_adapter, _app, runner|
      first = runner.submit(
        {"input" => "first"},
        thread: "thread.fifo",
        request_id: "request.1"
      )
      second = runner.submit(
        {"input" => "second"},
        thread: "thread.fifo",
        request_id: "request.2"
      )
      assert_equal 0, first.enqueue_sequence
      assert_equal 1, second.enqueue_sequence

      processed_first = runner.run_next(
        thread: "thread.fifo",
        owner_id: "owner.first"
      )
      assert_equal "request.1", processed_first.request_id
      assert_equal :completed, processed_first.status
      assert_equal :queued,
                   runner.fetch(
                     thread: "thread.fifo",
                     request_id: "request.2"
                   ).status

      processed_second = runner.run_next(
        thread: "thread.fifo",
        owner_id: "owner.second"
      )
      assert_equal "request.2", processed_second.request_id
      assert_equal :completed, processed_second.status
      assert_nil runner.run_next(
        thread: "thread.fifo",
        owner_id: "owner.empty"
      )
    end
  end

  def test_request_history_returns_ordered_durable_records
    with_runner do |_adapter, _app, runner|
      runner.deliver({"input" => "one"}, thread: "thread.history", request_id: "request.1")
      runner.submit({"input" => "two"}, thread: "thread.history", request_id: "request.2")
      runner.submit(
        {"input" => "three"},
        thread: "thread.history",
        request_id: "request.3",
        operation: :redirect,
        delivery: :redirect
      )

      history = runner.history(thread: "thread.history")
      assert history.frozen?
      assert_equal %w[request.1 request.2 request.3], history.map(&:request_id)
      assert_equal [0, 1, 2], history.map(&:enqueue_sequence)
      assert_equal %i[turn turn redirect], history.map(&:operation)
      assert_equal %i[queue queue redirect], history.map(&:delivery_mode)
      assert_equal :completed, history.first.status
      assert_equal :queued, history[1].status
      assert history.all? { |record| record.is_a?(Tamoz::Graph::RequestRecord) }
    end
  end

  def test_paused_turn_completes_and_resume_request_preserves_execution
    Dir.mktmpdir("tamoz-request-resume") do |directory|
      path = File.join(directory, "tamoz.db")
      definition = interrupt_definition
      adapter = Tamoz::SQLite::Adapter.new(path:)
      app = definition.compile(checkpointer: adapter)
      runner = app.durable_runner

      paused_request = runner.deliver(
        {},
        thread: "thread.resume",
        request_id: "request.pause"
      )
      assert_equal :completed, paused_request.status
      assert_equal "paused", paused_request.response.fetch("graph_status")
      paused = app.state(thread: "thread.resume")
      interrupt = paused.interrupts.first

      resumed_request = runner.deliver(
        {interrupt.task_id => {interrupt.call_index => "approved"}},
        thread: "thread.resume",
        request_id: "request.resume",
        operation: :resume
      )
      assert_equal :completed, resumed_request.status
      assert_equal paused_request.execution_id, resumed_request.execution_id
      assert_equal ["approved"], app.state(thread: "thread.resume").state.fetch(:answers)
      adapter.close
    end
  end

  def test_claimed_request_recovers_explicitly_under_a_new_fence
    with_runner do |_adapter, app, runner|
      runner.submit(
        {"input" => "recover"},
        thread: "thread.claim-recovery",
        request_id: "request.recover"
      )
      store = app.checkpointer
      claimed = nil
      store.open_writer(
        thread_id: "thread.claim-recovery",
        namespace: [],
        owner_id: "owner.crashed",
        ttl: store.writer_ttl
      ) { |writer| claimed = writer.claim_next_request }
      assert_equal :claimed, claimed.status

      recovered = runner.recover(
        thread: "thread.claim-recovery",
        request_id: "request.recover",
        owner_id: "owner.recovery"
      )
      assert_equal :completed, recovered.status
      assert_equal claimed.execution_id, recovered.execution_id
    end
  end

  def test_crash_after_running_checkpoint_recovers_without_second_execution
    Dir.mktmpdir("tamoz-request-running-recovery") do |directory|
      path = File.join(directory, "tamoz.db")
      injected = false
      fault = lambda do |point, metadata|
        next unless point == :after_commit
        next unless metadata.fetch("operation") == "checkpoint.commit"
        next if injected

        injected = true
        raise "crash after committed input checkpoint"
      end
      adapter = Tamoz::SQLite::Adapter.new(path:, fault_injector: fault)
      app = request_definition.compile(checkpointer: adapter)
      runner = app.durable_runner

      assert_raises(RuntimeError) do
        runner.deliver(
          {"input" => "recover"},
          thread: "thread.running-recovery",
          request_id: "request.running"
        )
      end
      assert injected
      running = runner.fetch(
        thread: "thread.running-recovery",
        request_id: "request.running"
      )
      assert_equal :running, running.status
      execution_id = running.execution_id
      adapter.close

      reopened = Tamoz::SQLite::Adapter.new(path:)
      recovered_app = request_definition.compile(checkpointer: reopened)
      recovered = recovered_app.durable_runner.recover(
        thread: "thread.running-recovery",
        request_id: "request.running",
        owner_id: "owner.after-crash"
      )
      assert_equal :completed, recovered.status
      assert_equal execution_id, recovered.execution_id
      assert_equal 2, recovered_app.history(
        thread: "thread.running-recovery"
      ).length
      reopened.close
    end
  end

  def test_fork_binds_new_execution_to_an_explicit_historical_checkpoint
    with_runner do |_adapter, app, runner|
      first = runner.deliver(
        {"input" => "first"},
        thread: "thread.fork",
        request_id: "request.first"
      )
      source = app.state(thread: "thread.fork")
      second = runner.deliver(
        {"input" => "second"},
        thread: "thread.fork",
        request_id: "request.second"
      )
      refute_equal first.execution_id, second.execution_id

      forked = runner.deliver(
        {
          "checkpoint_id" => source.checkpoint_id,
          "update" => {"input" => "forked"}
        },
        thread: "thread.fork",
        request_id: "request.fork",
        operation: :fork
      )
      assert_equal :completed, forked.status
      refute_equal second.execution_id, forked.execution_id
      state = app.state(thread: "thread.fork").state
      assert_equal "forked", state.fetch(:input)
      assert_equal ["first"], state.fetch(:seen)
    end
  end

  def test_redirect_pins_target_and_generation_then_starts_new_turn
    with_runner do |_adapter, app, runner|
      original = runner.deliver(
        {"input" => "original"},
        thread: "thread.redirect",
        request_id: "request.original"
      )
      redirected = runner.deliver(
        {"input" => "replacement"},
        thread: "thread.redirect",
        request_id: "request.redirect",
        operation: :redirect,
        delivery: :redirect
      )

      assert_equal :completed, redirected.status
      assert_equal original.execution_id, redirected.target_execution_id
      assert_equal 1, redirected.cancellation_generation
      refute_equal original.execution_id, redirected.execution_id
      assert_equal(
        ["replacement"],
        app.state(thread: "thread.redirect").state.fetch(:seen)
      )
      assert_raises(Tamoz::ConfigurationError) do
        runner.submit(
          {},
          thread: "thread.redirect",
          request_id: "request.invalid-redirect",
          operation: :redirect
        )
      end
    end
  end

  private

  def with_runner
    Dir.mktmpdir("tamoz-request") do |directory|
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.db")
      )
      app = request_definition.compile(checkpointer: adapter)
      yield adapter, app, app.durable_runner
      adapter.close
    end
  end

  def request_definition
    Tamoz.graph(name: "request-inbox", version: "1") do
      state :input, default: ""
      state :seen, reduce: :append, default: []
      node(
        :record,
        implementation_name: "request.record",
        version: "1"
      ) { |state, _context| {seen: [state.fetch(:input)]} }
      edge Tamoz::START, :record
      edge :record, Tamoz::END
    end
  end

  def interrupt_definition
    Tamoz.graph(name: "request-resume", version: "1") do
      state :answers, reduce: :append, default: []
      node(
        :pause,
        implementation_name: "request.pause",
        version: "1"
      ) do |_state, context|
        answer = Tamoz.interrupt({"question" => "approve?"}, context)
        {answers: [answer]}
      end
      edge Tamoz::START, :pause
      edge :pause, Tamoz::END
    end
  end
end
