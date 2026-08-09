# frozen_string_literal: true

require_relative 'test_helper'

# `DurableRunner` is the graph gem's own durability orchestration, and it was
# tested only through tamoz-sqlite integration suites — never at its own
# boundary. These rows drive it against a recording fake checkpointer, so what
# is asserted is the ORCHESTRATION: which store calls it makes, in what order,
# with what arguments, and which decisions it takes before any graph runs.
#
# Graph execution itself is out of scope here on purpose; that is what the
# sqlite suites cover end to end. Every case below stops short of it, which is
# also why a fake is enough.
class GraphDurableRunnerTest < Minitest::Test
  RequestRecord = Tamoz::Graph::RequestRecord

  # The minimum durable-inbox surface `DurableRunner` binds to. Recording, not
  # simulating: each method appends its call and returns what the case set up.
  class FakeCheckpointer
    attr_reader :calls, :requests

    def initialize(claimed: nil, recovered: nil, enqueued: nil, fetched: nil, history: [])
      @calls = []
      @claimed = claimed
      @recovered = recovered
      @enqueued = enqueued
      @fetched = fetched
      @history = history
    end

    # The graph compiler's own contract (`checkpoint_protocol_version` plus the
    # bound reader surface), then the durable-inbox contract `DurableRunner`
    # adds on top of it.
    def checkpoint_protocol_version = 1
    def durable? = true
    def request_protocol_version = 1
    def writer_ttl = 12.5

    def latest(**) = nil
    def find(**) = nil
    def history(**) = []

    def enqueue_request(**arguments)
      @calls << [:enqueue_request, arguments]
      @enqueued
    end

    def fetch_request(**arguments)
      @calls << [:fetch_request, arguments]
      @fetched
    end

    def request_history(**arguments)
      @calls << [:request_history, arguments]
      @history
    end

    def open_writer(**arguments)
      @calls << [:open_writer, arguments]
      yield Writer.new(self, @claimed, @recovered)
      nil
    end

    Writer = Struct.new(:store, :claimed, :recovered) do
      def claim_next_request(validator: nil)
        store.calls << [:claim_next_request, { validator: }]
        claimed
      end

      def recover_request(request_id:, validator: nil)
        store.calls << [:recover_request, { request_id:, validator: }]
        recovered
      end

      def terminal_fail(request_id:, operation:, reason:)
        store.calls << [:terminal_fail, { request_id:, operation:, reason: }]
        RequestRecord.new(**REQUEST_FIELDS, request_id:, operation:,
                                            status: :failed, terminal_error: reason)
      end
    end
  end

  REQUEST_FIELDS = {
    thread_id: 'thread.a', namespace: [], request_id: 'request.1',
    enqueue_sequence: 1, input_digest: "sha256:#{'a' * 64}", operation: :turn,
    delivery_mode: :queue, status: :queued, payload: {}, execution_id: nil,
    target_execution_id: nil, cancellation_generation: 0, checkpoint_id: nil,
    response: nil, terminal_error: nil, retryable: false,
    created_at_ms: 0, updated_at_ms: 0
  }.freeze

  def request(**overrides) = RequestRecord.new(**REQUEST_FIELDS, **overrides)

  def definition
    Tamoz.graph(name: 'runner', version: '1') do
      state :count, default: 0
      node(:only, implementation_name: 'runner.only', version: '1') { |_state, _ctx| { count: 1 } }
      edge Tamoz::START, :only
      edge :only, Tamoz::END
    end
  end

  def runner_over(checkpointer)
    Tamoz::Graph::DurableRunner.new(definition.compile(checkpointer:))
  end

  # --- the binding contract ------------------------------------------------

  # The runner refuses anything that cannot answer the durable-inbox contract,
  # at construction rather than at first use — a non-durable store discovered
  # mid-run would already have taken a lease it cannot honour.
  def test_a_non_durable_checkpointer_is_refused_at_construction
    assert_raises(Tamoz::ConfigurationError) { runner_over(Tamoz::Graph::MemoryCheckpointer.new) }
  end

  def test_a_checkpointer_at_another_protocol_version_is_refused
    wrong = FakeCheckpointer.new
    wrong.define_singleton_method(:request_protocol_version) { 99 }

    assert_raises(Tamoz::ConfigurationError) { runner_over(wrong) }
  end

  def test_a_checkpointer_that_does_not_name_a_protocol_is_refused
    silent = FakeCheckpointer.new
    silent.singleton_class.undef_method(:request_protocol_version)

    assert_raises(Tamoz::ConfigurationError) { runner_over(silent) }
  end

  # --- delegation ----------------------------------------------------------

  def test_submit_enqueues_the_request_verbatim
    store = FakeCheckpointer.new(enqueued: request)
    result = runner_over(store).submit(
      { 'task' => 'go' }, thread: 'thread.a', request_id: 'request.1',
                          operation: :redirect, delivery: :redirect, namespace: %w[ns]
    )

    assert_equal request, result
    name, arguments = store.calls.fetch(0)

    assert_equal :enqueue_request, name
    assert_equal({ thread_id: 'thread.a', namespace: %w[ns], request_id: 'request.1',
                   operation: :redirect, payload: { 'task' => 'go' }, delivery: :redirect },
                 arguments)
  end

  def test_fetch_reads_through_to_the_store
    store = FakeCheckpointer.new(fetched: request)

    assert_equal request, runner_over(store).fetch(thread: 'thread.a', request_id: 'request.1')
    assert_equal :fetch_request, store.calls.fetch(0).first
  end

  def test_history_reads_through_to_the_store
    store = FakeCheckpointer.new(history: [request])

    assert_equal [request], runner_over(store).history(thread: 'thread.a', namespace: %w[ns])
    assert_equal [:request_history, { thread_id: 'thread.a', namespace: %w[ns] }],
                 store.calls.fetch(0)
  end

  # --- run_next: the decisions taken before anything executes --------------

  def test_run_next_returns_nil_when_the_inbox_is_empty
    store = FakeCheckpointer.new(claimed: nil)

    assert_nil runner_over(store).run_next(thread: 'thread.a')
    assert_includes store.calls.map(&:first), :claim_next_request
  end

  # A claim that comes back in any other status is handed back untouched. The
  # runner executes `claimed` and `redirecting` and nothing else, so a request
  # another worker already finished is never re-run.
  def test_run_next_returns_a_non_claimable_request_without_executing_it
    %i[completed failed running].each do |status|
      store = FakeCheckpointer.new(claimed: request(status:))
      result = runner_over(store).run_next(thread: 'thread.a')

      assert_equal status, result.status
      refute_includes store.calls.map(&:first), :fetch_request,
                      "#{status} must not reach execution or its post-run read"
    end
  end

  # The lease is opened with the store's OWN ttl, not a runner-chosen one.
  def test_run_next_opens_the_writer_with_the_stores_ttl_and_the_given_owner
    store = FakeCheckpointer.new(claimed: nil)
    runner_over(store).run_next(thread: 'thread.a', namespace: %w[ns], owner_id: 'owner.7')

    assert_equal({ thread_id: 'thread.a', namespace: %w[ns], owner_id: 'owner.7', ttl: 12.5 },
                 store.calls.fetch(0).last)
  end

  # The claim is validated by the GRAPH's staleness predicate, evaluated inside
  # the store transaction. This pins that the validator handed over is that
  # predicate, not an accident that happens to be truthy.
  def claim_validator_from(store)
    compiled = definition.compile(checkpointer: store)
    Tamoz::Graph::DurableRunner.new(compiled).run_next(thread: 'thread.a')
    validator = store.calls.find { |name, _| name == :claim_next_request }.last.fetch(:validator)
    [compiled, validator]
  end

  # The validator is called `(request, checkpoint)` by the store and hands them
  # to the predicate as `(checkpoint, request)`. A `:retry` against a
  # checkpoint that is not failed is stale, so the reason is non-nil — which is
  # what makes this comparison mean something, and what makes a silent argument
  # swap fail here rather than in production.
  def test_the_claim_validator_is_the_graphs_own_staleness_predicate
    compiled, validator = claim_validator_from(FakeCheckpointer.new(claimed: nil))
    stale = request(operation: :retry)
    checkpoint = Struct.new(:status).new(:completed)

    assert_equal compiled.stale_request_reason(checkpoint, stale), validator.call(stale, checkpoint)
  end

  def test_the_claim_validator_reports_a_stale_retry
    _compiled, validator = claim_validator_from(FakeCheckpointer.new(claimed: nil))
    checkpoint = Struct.new(:status).new(:completed)

    refute_nil validator.call(request(operation: :retry), checkpoint),
               'a retry against a completed checkpoint is stale'
  end

  # A `:redirect` is deliberately never stale: its wait condition must retry
  # rather than terminal-fail.
  def test_the_claim_validator_never_calls_a_redirect_stale
    _compiled, validator = claim_validator_from(FakeCheckpointer.new(claimed: nil))

    assert_nil validator.call(request(operation: :redirect), Struct.new(:status).new(:completed))
  end

  # --- recover -------------------------------------------------------------

  def test_recover_addresses_the_named_request
    store = FakeCheckpointer.new(recovered: request(status: :completed))
    runner_over(store).recover(thread: 'thread.a', request_id: 'request.1')
    _name, arguments = store.calls.find { |entry| entry.first == :recover_request }

    assert_equal 'request.1', arguments.fetch(:request_id)
  end

  def test_recover_leaves_an_already_terminal_request_alone
    store = FakeCheckpointer.new(recovered: request(status: :completed))
    result = runner_over(store).recover(thread: 'thread.a', request_id: 'request.1')

    assert_equal :completed, result.status
    refute_includes store.calls.map(&:first), :fetch_request
  end

  # --- terminal_fail (the DR-4 D2 backstop) --------------------------------

  # It takes a FRESH lease: the runner's own writer block has already closed by
  # the time a post-claim staleness is resolved, so reusing that writer would
  # be writing under an expired fence.
  def stale_request = request(status: :claimed, operation: :resume, namespace: %w[ns])

  def test_terminal_fail_transitions_the_request_through_the_writer
    store = FakeCheckpointer.new
    result = runner_over(store).terminal_fail(stale_request, reason: 'checkpoint moved')

    assert_equal :failed, result.status
    assert_equal 'checkpoint moved', result.terminal_error
  end

  # It takes a FRESH lease: the runner's own writer block has already closed by
  # the time a post-claim staleness is resolved, so reusing that writer would be
  # writing under an expired fence.
  def test_terminal_fail_opens_its_own_writer_on_the_requests_namespace
    store = FakeCheckpointer.new
    runner_over(store).terminal_fail(stale_request, reason: 'checkpoint moved')
    opened = store.calls.fetch(0)

    assert_equal :open_writer, opened.first
    assert_equal %w[ns], opened.last.fetch(:namespace)
  end

  def test_terminal_fail_names_the_request_and_its_operation
    store = FakeCheckpointer.new
    runner_over(store).terminal_fail(stale_request, reason: 'checkpoint moved')

    assert_equal({ request_id: 'request.1', operation: :resume, reason: 'checkpoint moved' },
                 store.calls.fetch(1).last)
  end

  # --- deliver -------------------------------------------------------------

  # A submit that lands terminal (a rejected or already-answered request) is
  # returned as-is. Nothing is claimed, no lease is taken, no graph runs.
  def test_deliver_short_circuits_on_a_terminal_submit
    store = FakeCheckpointer.new(enqueued: request(status: :failed))
    result = runner_over(store).deliver({}, thread: 'thread.a', request_id: 'request.1')

    assert_equal :failed, result.status
    assert_equal [:enqueue_request], store.calls.map(&:first),
                 'a terminal submit must not open a writer'
  end

  # A non-terminal submit runs the inbox and then reports the request's
  # SETTLED state, read back from the store rather than inferred from the run.
  def test_deliver_reports_the_request_read_back_after_the_run
    settled = request(status: :completed)
    store = FakeCheckpointer.new(enqueued: request(status: :queued), claimed: nil,
                                 fetched: settled)
    result = runner_over(store).deliver({}, thread: 'thread.a', request_id: 'request.1')

    assert_equal settled, result
    assert_equal :fetch_request, store.calls.last.first
  end
end
