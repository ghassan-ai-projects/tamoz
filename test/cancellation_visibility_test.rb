# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/autonomy_case'
require_relative 'support/comms_gateway_harness'

# Plan 03 work items 4-5 — visible cancellation and the reconnectable CLI
# status view. The timeline is durable (`requested` stamped inside the /cancel
# enqueue transaction, `observed` stamped once where the turn runner consumes
# the cancel operation), the terminal point stays the existing settle fact, a
# raced completion never renders as a stop (invariant 9), and the CLI view
# answers from durable rows alone — no worker process, nothing re-run.
# rubocop:disable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:disable Metrics/BlockLength, Metrics/ClassLength
class CancellationVisibilityTest < Minitest::Test
  include AutonomyCase
  include CommsGatewayHarness

  Comms = Tamoz::Comms

  CONVERSATION = 'telegram:chat:22222222'
  # The thread the gateway itself derives for this conversation (design §5):
  # admissions land on the deterministic thread, never on a caller-chosen one.
  THREAD = Comms::Admission.thread_id(CommsGatewayHarness::SURFACE_ID, CONVERSATION).freeze
  CANCEL_PAYLOAD = { 'task' => { 'cancel' => true, 'reason' => 'cancelled_by_user' } }.freeze

  def test_migration_pins_schema_version_22
    assert_equal 22, Tamoz::SQLite::Migrator::CURRENT_VERSION
    assert_equal (1..22).to_a, Tamoz::SQLite::Migrator.migration_ordinals
  end

  # Clean cancel: requested -> observed -> terminal stopped, all three points
  # rendered distinctly by `/status r<ref>`.
  def test_a_clean_cancel_renders_requested_observed_and_stopped_distinctly
    with_engine do |store, checkpoints, gateway, transport|
      bind_route!(store)
      serve_admission(gateway, transport, 301)
      request_id = request_ids(checkpoints).first

      assert_equal :requested, store.request_cancellation(
        thread_id: THREAD, request_id: 'cancel-301', payload: CANCEL_PAYLOAD, now: NOW + 2
      )
      assert_equal :observed, store.mark_cancellation_observed(thread_id: THREAD, now: NOW + 6)

      text = drive_status(gateway, transport, store, 310, "/status #{ref(request_id)}")

      assert_match(/Cancellation requested \d+[smh] ago\./, text)
      assert_match(/Observed by the runner \d+[smh] ago\./, text)
      assert_match(/Terminal: stopped at the cancellation boundary\./, text)
    end
  end

  # Raced cancel: the turn settled completed before the cancellation took
  # effect. The terminal wording says exactly that and NEVER claims issued
  # external work stopped (invariant 9).
  def test_a_raced_completion_says_completed_before_effect_and_never_stopped
    with_engine do |store, checkpoints, gateway, transport|
      bind_route!(store)
      serve_admission(gateway, transport, 302)
      request_id = request_ids(checkpoints).first

      assert_equal :requested, store.request_cancellation(
        thread_id: THREAD, request_id: 'cancel-302', payload: CANCEL_PAYLOAD, now: NOW + 2
      )
      assert_equal :released,
                   store.complete_request(thread_id: THREAD, request_id:, settle_kind: 'answer')
      assert_equal :observed, store.mark_cancellation_observed(thread_id: THREAD, now: NOW + 6)

      text = drive_status(gateway, transport, store, 311, "/status #{ref(request_id)}")

      assert_match(/Terminal: completed before the cancellation took effect\./, text)
      refute_match(/stopped/i, text, 'a raced completion must not be rendered as a stop')
    end
  end

  # A turn that FAILS under cancellation renders the failed wording next to
  # task=failed — the settle word follows the recorded settle kind, never a
  # success claim for work that did not succeed.
  def test_a_failed_settle_renders_failed_wording_on_the_task_axis
    with_engine do |store, checkpoints, gateway, transport|
      bind_route!(store)
      serve_admission(gateway, transport, 304)
      request_id = request_ids(checkpoints).first
      fail_inbox_request!(checkpoints, request_id)

      assert_equal :requested, store.request_cancellation(
        thread_id: THREAD, request_id: 'cancel-304', payload: CANCEL_PAYLOAD, now: NOW + 2
      )
      assert_equal :released,
                   store.complete_request(thread_id: THREAD, request_id:, settle_kind: 'failed')
      assert_equal :observed, store.mark_cancellation_observed(thread_id: THREAD, now: NOW + 6)

      text = drive_status(gateway, transport, store, 312, "/status #{ref(request_id)}")

      assert_match(/State: failed/, text)
      assert_match(/Terminal: failed before the cancellation took effect\./, text)
      refute_match(/completed/i, text, 'a failed settle never reads as a completion')
    end
  end

  # The aggregate `/status` (no argument) exposes the newest live timeline of
  # the active request alongside the usual queue facts.
  def test_the_aggregate_status_carries_the_newest_live_timeline
    with_engine do |store, _checkpoints, gateway, transport|
      bind_route!(store)
      serve_admission(gateway, transport, 303)

      assert_equal :requested, store.request_cancellation(
        thread_id: THREAD, request_id: 'cancel-303', payload: CANCEL_PAYLOAD, now: NOW + 2
      )

      text = drive_status(gateway, transport, store, 313, '/status')

      assert_match(%r{Work status: State: queued}, text)
      assert_match(/Cancellation requested/, text)
      assert_match(/Queue position 0\./, text)
    end
  end

  # A bound conversation with nothing admitted has a real projection whose
  # state is idle; the card must say so, not fall back to "active".
  def test_an_idle_conversation_is_reported_as_idle
    with_engine do |store, _checkpoints, gateway, transport|
      bind_route!(store)

      text = drive_status(gateway, transport, store, 314, '/status')

      assert_match(%r{Work status: State: idle}, text)
      refute_match(/active/i, text)
    end
  end

  # Black-box drive (the way agent_worker_test drives real workers): a real
  # WorkerRuntime/Worker whose pass consumes a queued cancel redirect through
  # claim_and_run alone — no private poke — must carry the timeline from
  # `requested` to `observed`, must never stamp while an ordinary turn or a
  # plain redirect runs, and must never move the stamp once it is written.
  def test_a_real_worker_claim_consumes_a_cancel_redirect_and_stamps_observation
    with_runtime do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      directory = Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {})
      runtime = Tamoz::Agent::WorkerRuntime.open(
        directory,
        model_factory: ->(profile:) { ScriptedModel.new(**read_only_responses) },
        lease_ttl: 5.0
      )
      begin
        store = runtime.adapter.bind_comms_store(runtime.checkpoints)
        insert_request!(store, request_id: 'c' * 63 + '1')
        worker = Tamoz::Agent::Worker.new(
          runtime:,
          session_builder: ->(thread) { runtime.session_for(thread) },
          emitter: ->(_event) {}, once: true
        )

        runtime.checkpoints.enqueue_request(
          thread_id: THREAD, request_id: 'd' * 63 + '1', operation: :turn,
          payload: { 'task' => 'Read note.txt' }, delivery: :queue
        )
        assert worker.poll_once

        stamps = cancellation_stamps(store, 'c' * 63 + '1')
        assert_nil stamps.fetch('observed_at_ms'),
                  'a settled ordinary turn is not a cancellation observation'

        requested_at = (Time.now.to_r * 1000).to_i
        assert_equal :requested, store.request_cancellation(
          thread_id: THREAD, request_id: 'cancel-claim', payload: CANCEL_PAYLOAD,
          now: Time.at(requested_at / 1000.0)
        )

        runtime.checkpoints.enqueue_request(
          thread_id: THREAD, request_id: 'e' * 63 + '1', operation: :redirect,
          payload: { 'task' => { 'cancel' => true } }, delivery: :redirect
        )
        assert worker.poll_once

        stamps = cancellation_stamps(store, 'c' * 63 + '1')
        refute_nil stamps.fetch('observed_at_ms'), 'consuming the cancel stamps observed'
        observed = stamps.fetch('observed_at_ms')
        assert_operator observed, :>=, stamps.fetch('requested_at_ms')

        history = runtime.checkpoints.request_history(thread_id: THREAD)
        assert_equal 1, history.count { |request| request.operation == :turn },
                     'no second turn ran behind the cancel'
        redirect = history.find { |request| request.operation == :redirect }
        assert redirect.terminal?, 'the consumed cancel redirect is terminal'

        view = runtime.session_for(THREAD).view(thread: THREAD)
        assert_equal 'cancelled_by_user', view.terminal.fetch('reason')

        runtime.checkpoints.enqueue_request(
          thread_id: THREAD, request_id: 'g' * 63 + '1', operation: :redirect,
          payload: { 'task' => 'Read note.txt' }, delivery: :redirect
        )
        assert worker.poll_once

        stamps = cancellation_stamps(store, 'c' * 63 + '1')
        assert_equal observed, stamps.fetch('observed_at_ms'),
                     'a redirect without a cancel task is not an observation'

        runtime.checkpoints.enqueue_request(
          thread_id: THREAD, request_id: 'h' * 63 + '1', operation: :redirect,
          payload: { 'task' => { 'cancel' => true } }, delivery: :redirect
        )
        assert worker.poll_once

        stamps = cancellation_stamps(store, 'c' * 63 + '1')
        assert_equal observed, stamps.fetch('observed_at_ms'),
                     'a replayed observation never moves the stamp'
      ensure
        runtime&.close
      end
    end
  end

  # The recover call site observes too: a redirect left `redirecting` by a
  # worker that died between claim and execution is re-entered by the next
  # worker's recover path, and THAT production call site stamps `observed`.
  def test_a_crashed_claim_is_recovered_through_the_recover_path_and_stamps_observation
    with_runtime do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      directory = Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {})
      runtime = Tamoz::Agent::WorkerRuntime.open(
        directory,
        model_factory: ->(profile:) { ScriptedModel.new(**read_only_responses) },
        lease_ttl: 5.0
      )
      begin
        store = runtime.adapter.bind_comms_store(runtime.checkpoints)
        insert_request!(store, request_id: 'f' * 63 + '1')

        runtime.checkpoints.enqueue_request(
          thread_id: THREAD, request_id: 'a' * 63 + '1', operation: :turn,
          payload: { 'task' => 'Read note.txt' }, delivery: :queue
        )
        first = Tamoz::Agent::Worker.new(
          runtime:,
          session_builder: ->(thread) { runtime.session_for(thread) },
          emitter: ->(_event) {}, once: true
        )
        assert first.poll_once

        runtime.checkpoints.enqueue_request(
          thread_id: THREAD, request_id: 'b' * 63 + '9', operation: :redirect,
          payload: { 'task' => { 'cancel' => true } }, delivery: :redirect
        )
        # Exactly what a kill between claim and execution leaves behind: the
        # redirect claimed (`redirecting`, target bound), nothing executed.
        runtime.checkpoints.open_writer(
          thread_id: THREAD, namespace: [], owner_id: 'ghost.claim', ttl: 5.0
        ) do |writer|
          claimed = writer.claim_next_request
          refute_nil claimed
          assert_equal :redirecting, claimed.status
        end

        assert_equal :requested, store.request_cancellation(
          thread_id: THREAD, request_id: 'cancel-recover', payload: CANCEL_PAYLOAD,
          now: Time.now
        )

        events = []
        recovering = Tamoz::Agent::Worker.new(
          runtime:,
          session_builder: ->(thread) { runtime.session_for(thread) },
          emitter: ->(event) { events << event.fetch('event') }, once: true
        )
        assert recovering.poll_once

        assert_includes events, 'request.recovered', 'the redirect was re-entered by recover'
        stamps = cancellation_stamps(store, 'f' * 63 + '1')
        refute_nil stamps.fetch('observed_at_ms'),
                  'the recover-path observation stamped the timeline'

        view = runtime.session_for(THREAD).view(thread: THREAD)
        assert_equal 'cancelled_by_user', view.terminal.fetch('reason')
      ensure
        runtime&.close
      end
    end
  end

  # A crashed TURN (not the cancel) recovered to completion must NOT stamp:
  # the observation tracks consumption of the cancel operation itself, so the
  # stamp waits for the pass that actually consumes the queued redirect.
  def test_recovery_of_a_crashed_turn_alone_leaves_the_timeline_unstamped
    with_runtime do |rt|
      File.write(File.join(rt.workspace, 'note.txt'), "hello\n")
      directory = Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {})
      first = Tamoz::Agent::WorkerRuntime.open(
        directory,
        model_factory: ->(profile:) {
          CrashingModel.new(after: :claim, **read_only_responses)
        },
        lease_ttl: 0.2
      )
      begin
        store = first.adapter.bind_comms_store(first.checkpoints)
        insert_request!(store, request_id: '9' * 63 + '1')
        first.checkpoints.enqueue_request(
          thread_id: THREAD, request_id: '8' * 63 + '1', operation: :turn,
          payload: { 'task' => 'Read note.txt' }, delivery: :queue
        )
        crashing = Tamoz::Agent::Worker.new(
          runtime: first,
          session_builder: ->(thread) { first.session_for(thread) },
          emitter: ->(_event) {}, once: true
        )
        assert_raises(CrashingModel::Killed) { crashing.poll_once }
        requested_at = Time.now
        assert_equal :requested, store.request_cancellation(
          thread_id: THREAD, request_id: 'cancel-crash', payload: CANCEL_PAYLOAD, now: requested_at
        )
        first.checkpoints.enqueue_request(
          thread_id: THREAD, request_id: '7' * 63 + '1', operation: :redirect,
          payload: { 'task' => { 'cancel' => true } }, delivery: :redirect
        )
      ensure
        first&.close
      end

      sleep 0.25
      second = Tamoz::Agent::WorkerRuntime.open(
        directory,
        model_factory: ->(profile:) { ScriptedModel.new(**read_only_responses) },
        lease_ttl: 0.2
      )
      begin
        worker = Tamoz::Agent::Worker.new(
          runtime: second,
          session_builder: ->(thread) { second.session_for(thread) },
          emitter: ->(_event) {}, once: true
        )
        assert worker.poll_once, 'the recovered occurrence made progress'

        store = second.adapter.bind_comms_store(second.checkpoints)
        stamps = cancellation_stamps(store, '9' * 63 + '1')
        assert_nil stamps.fetch('observed_at_ms'),
                  'recovering the crashed turn consumed no cancel operation'

        assert worker.poll_once, 'the queued cancel redirect was consumed'

        stamps = cancellation_stamps(store, '9' * 63 + '1')
        refute_nil stamps.fetch('observed_at_ms')
        assert_operator stamps.fetch('observed_at_ms'), :>=, stamps.fetch('requested_at_ms')
      ensure
        second&.close
      end
    end
  end

  # Reconnectable view (plan 03 work item 5): with every writer long gone,
  # `tamoz comms request <ref>` answers from the durable stores alone — task
  # and delivery states, queue facts, and the cancellation timeline — and an
  # unknown or malformed reference is refused typed.
  def test_the_cli_view_answers_from_durable_rows_alone
    with_rt do |rt|
      reference = seed_durable_rows!(rt)

      status, out, err = rt.cli(['comms', 'request', reference])

      assert_equal 0, status, err
      assert_match(/request #{reference} on telegram-ops\/#{CONVERSATION}/, out)
      assert_match(/task=\w+ delivery=\w+ open_requests=1 state=/, out)
      assert_match(/queue_position=0/, out)
      assert_match(/cancellation=terminal requested_age_ms=/, out)
      assert_match(/terminal=stopped$/, out.split("\n").find { |line| line.start_with?('  cancellation') })

      status, out, err = rt.cli(['comms', 'request', reference, '--json'])

      assert_equal 0, status, err
      document = JSON.parse(out.lines.last)
      assert_equal 'tamoz.comms.request_view.v1', document.fetch('schema')
      row = document.fetch('requests').first

      assert_equal reference, row.fetch('request_ref')
      assert_equal 'stopped', row.dig('cancellation', 'terminal')
      assert_equal 'accepted', row.fetch('state')
      assert_equal 1, row.fetch('open_requests')
      assert row.key?('delivery_state')
      assert row.key?('queue_position')
    end
  end

  def test_the_cli_view_refuses_an_unknown_or_malformed_reference
    with_rt do |rt|
      seed_durable_rows!(rt)

      status, _out, err = rt.cli(['comms', 'request', 'r0000000000'])

      assert_equal 1, status
      assert_match(/no request with reference "r0000000000" is admitted/, err)

      status, _out, err = rt.cli(['comms', 'request', 'not-a-ref'])

      assert_equal 1, status
      assert_match(/no request with reference/, err)
    end
  end

  # ----------------------------------------------------------------- helpers

  def read_only_responses
    {
      plan: [plan_step('read_file', { 'path' => 'note.txt' })],
      review: [accepted_review],
      verify: [{ 'answer' => 'hello', 'satisfied' => true, 'evidence' => ['note.txt'] }]
    }
  end

  # One gateway pass per inbound update: the admission lands through the
  # transport, the way the channel really receives it.
  def serve_admission(gateway, transport, id)
    transport.batch([update(id)])
    assert_equal :served, gateway.serve_once(now: NOW + id, drain: false)
  end

  def drive_status(gateway, transport, store, id, text)
    transport.batch([update(id, text:)])
    assert_equal :served, gateway.serve_once(now: NOW + id, drain: false)
    row = store.outbox_rows(surface_id: SURFACE_ID, statuses: %w[pending claimed succeeded])
               .find { |candidate| candidate.fetch('reply_to') == id + 10_000 }
    row && row.fetch('text')
  end

  def with_engine
    Dir.mktmpdir('tamoz-cancel') do |directory|
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(directory, 'runtime.sqlite3'))
      begin
        checkpoints = graph_definition('cancel').compile(checkpointer: adapter).checkpointer
        store = adapter.bind_comms_store(checkpoints)
        store.deploy_surface(descriptor.wire, now: NOW)
        transport = CommsGatewayHarness::ScriptedTransport.new
        gateway = Comms::Gateway.new(
          adapter:, checkpoints:, transport:, descriptor:, poller_owner: 'gateway:test'
        )
        yield store, checkpoints, gateway, transport
      ensure
        adapter&.close
      end
    end
  end

  def bind_route!(store)
    store.deploy_surface(descriptor.wire, now: NOW)
    store.bind_conversation(
      Comms::Conversation.new(
        surface_id: SURFACE_ID, surface_revision: 1,
        conversation_id: CONVERSATION, thread_id: THREAD,
        profile_id: 'ops', bound_at: NOW
      ).wire, now: NOW
    )
  end

  def insert_request!(store, request_id:)
    store.__send__(:transaction, 'test.cancel.insert') do |tx|
      binds = [request_id, 'telegram-ops', 1, CONVERSATION, THREAD, 'ops', 1, 'admitted',
               ms(NOW), ms(NOW)]
      tx.execute('test.cancel.insert', <<~SQL, binds)
        INSERT INTO tamoz_comms_requests (
          request_id, surface_id, surface_revision, conversation_id,
          thread_id, profile_id, reservation, projection_state,
          created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      SQL
    end
  end

  def request_ids(checkpoints)
    checkpoints.request_history(thread_id: THREAD).map(&:request_id)
  end

  # Marks the admitted turn failed in the checkpoint inbox — the same fenced
  # transition the worker's terminal_fail performs.
  def fail_inbox_request!(checkpoints, request_id)
    checkpoints.open_writer(thread_id: THREAD, namespace: [], owner_id: 'test.fail', ttl: 30) do |writer|
      claimed = writer.claim_next_request(validator: nil)
      raise 'the turn was not claimable' unless claimed&.request_id == request_id

      writer.mark_request_running(request_id:, execution_id: claimed.execution_id)
      writer.terminal_fail(request_id:, operation: :turn, reason: 'model_error')
    end
  end

  def ref(request_id) = "r#{request_id[0, 10]}"

  def cancellation_stamps(store, request_id)
    row = store.__send__(:read, 'test.cancel.stamps') do |txn|
      txn.first('test.cancel.stamps', <<~SQL, [request_id])
        SELECT cancellation_requested_at_ms, cancellation_observed_at_ms
        FROM tamoz_comms_requests WHERE request_id = ?
      SQL
    end

    { 'requested_at_ms' => row&.fetch(0), 'observed_at_ms' => row&.fetch(1) }
  end

  def ms(value)
    (value.to_r * 1000).to_i
  end

  # --- the reconnectable CLI harness: a runtime directory, durable rows, and
  # --- no process of any kind between the seed and the CLI invocation.

  def with_rt
    Dir.mktmpdir('tamoz-cancel-view') do |directory|
      runtime_dir = File.join(directory, 'runtime')
      workspace = File.join(directory, 'workspace')
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      File.chmod(0o700, runtime_dir)
      File.write(File.join(runtime_dir, 'config.yaml'), Psych.dump(
                                                           'runtime' => { 'schema_version' => 2 },
                                                           'workspace' => { 'root' => workspace },
                                                           'sources' => {},
                                                           'channels' => {
                                                             'telegram-ops' => {
                                                               'kind' => 'telegram', 'revision' => 1,
                                                               'enabled' => false, 'profile' => 'ops',
                                                               'credential_ref' => {
                                                                 'kind' => 'env', 'name' => 'TAMOZ_TELEGRAM_BOT_TOKEN'
                                                               },
                                                               'expected_bot_id' => BOT_ID,
                                                               'admission' => { 'direct' => 'pairing',
                                                                                'correspondents' => [] }
                                                             }
                                                           }
                                                         ))
      File.chmod(0o600, File.join(runtime_dir, 'config.yaml'))
      yield Harness.new(runtime_dir)
    end
  end

  def seed_durable_rows!(rt)
    reference = "r#{'a' * 10}"
    rt.with_store do |store|
      store.__send__(:transaction, 'test.view.insert') do |tx|
        binds = ['a' * 63 + '1', 'telegram-ops', 1, CONVERSATION, THREAD, 'ops', 1, 'admitted',
                 ms(NOW), ms(NOW)]
        tx.execute('test.view.insert', <<~SQL, binds)
          INSERT INTO tamoz_comms_requests (
            request_id, surface_id, surface_revision, conversation_id,
            thread_id, profile_id, reservation, projection_state,
            created_at_ms, updated_at_ms
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
      end
      assert_equal :requested, store.request_cancellation(
        thread_id: THREAD, request_id: 'cancel-view', payload: CANCEL_PAYLOAD, now: NOW + 2
      )
      assert_equal :observed, store.mark_cancellation_observed(thread_id: THREAD, now: NOW + 6)
    end
    reference
  end

  class Harness
    attr_reader :dir

    def initialize(dir)
      @dir = dir
    end

    def cli(argv)
      out = StringIO.new
      err = StringIO.new
      exit_code = Tamoz::Agent::CLI.run(
        ['--runtime-dir', dir] + argv,
        out:, err:, input: StringIO.new,
        env: { 'TAMOZ_TELEGRAM_BOT_TOKEN' => '12345:secret' }
      )
      [exit_code, out.string, err.string]
    end

    def with_store
      adapter = Tamoz::SQLite::Adapter.new(path: File.join(dir, 'runtime.sqlite3'))
      definition = Tamoz.graph(name: 't', version: '1') do
        state :ready, default: true
        node(:finish, implementation_name: 't.finish', version: '1') { |_s, _c| { ready: true } }
        edge Tamoz::START, :finish
        edge :finish, Tamoz::END
      end
      checkpoints = definition.compile(checkpointer: adapter).checkpointer
      yield adapter.bind_comms_store(checkpoints)
    ensure
      adapter&.close
    end
  end
end
# rubocop:enable Minitest/MultipleAssertions, Metrics/AbcSize, Metrics/MethodLength
# rubocop:enable Metrics/BlockLength, Metrics/ClassLength
