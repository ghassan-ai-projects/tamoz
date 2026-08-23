# frozen_string_literal: true

require_relative "test_helper"

# P15-D (docs/P15_RELEASE_PLAN.md §6) — the invariant-24 sweep over EVERY
# durable store.
#
# Invariant 24: "Secret values are rejected from checkpoints, streams, and
# instrumentation unless a named policy protects them; no lossy key-name
# scrubbing occurs."
#
# Individual suites prove that for the store they own. What none of them prove
# is COVERAGE: that the set of durable surfaces which can accept caller data is
# the set that refuses a secret. A new durable table with a `payload` column
# and no protection would be invisible to every existing test, because every
# existing test knows only about the tables that existed when it was written.
#
# So this sweeps the surfaces by name, planting the same `Tamoz::Secret` into
# each, and asserts every one of them fails closed. The list is pinned: adding a
# durable payload surface without deciding its secret policy fails here.
class SecretSweepTest < Minitest::Test
  SECRET = Tamoz::Secret.new("sk-live-DO-NOT-PERSIST-0123456789")

  # Every durable surface that accepts caller-supplied data. Adding one without
  # adding it here is the gap this test exists to prevent. T8.3: the retired
  # P14 engine's stream_payload surface is gone with it (the worker admits
  # only the stream-sealed, digest-verified snapshot).
  SURFACES = %w[
    application_store checkpoint_state session_record request_payload
    effect_request schedule_payload instrumentation
    stream_part context_metadata
  ].freeze

  def test_the_swept_surface_list_is_complete
    covered = methods.grep(/\Atest_a_secret_is_refused_from_/).map do |name|
      name.to_s.delete_prefix("test_a_secret_is_refused_from_")
    end

    assert_equal SURFACES.sort, covered.sort,
                 "every durable payload surface needs a secret test; add the new " \
                 "surface to SURFACES and give it one"
  end

  def test_a_secret_is_refused_from_application_store
    with_adapter do |adapter|
      assert_raises(Tamoz::SensitiveValueError) do
        adapter.store.put("memory", "leak", {"token" => SECRET})
      end
      # …and round-trips only under an explicit named protection.
      refute_nil Tamoz::SQLite::Adapter.instance_method(:initialize)
                                       .parameters.find { |_kind, name| name == :store_protection }
    end
  end

  # A node that returns a secret does not raise out of `deliver` — the run
  # FAILS, durably, which is the correct behaviour for a durable runner. The
  # assertion that matters is the one about the file: the secret's bytes must
  # never reach the database, whatever the control flow does.
  def test_a_secret_is_refused_from_checkpoint_state
    with_adapter do |adapter, path|
      definition = Tamoz.graph(name: "secret.sweep", version: "1") do
        state :payload
        node(:leak, implementation_name: "secret.sweep.leak", version: "1") do |_state, _context|
          {payload: Tamoz::Secret.new("sk-live-DO-NOT-PERSIST-0123456789")}
        end
        edge Tamoz::START, :leak
        edge :leak, Tamoz::END
      end
      app = definition.compile(checkpointer: adapter)
      app.durable_runner.deliver({}, thread: "secret", request_id: "r0")

      assert_equal :failed, app.state(thread: "secret").status
      assert_nil app.state(thread: "secret").state[:payload]
      refute_includes File.binread(path), "sk-live-DO-NOT-PERSIST",
                      "a secret reached the database file"
    end
  end

  def test_a_secret_is_refused_from_session_record
    assert_raises(Tamoz::Error) do
      Tamoz::Agent::SessionRecords.build(
        "session",
        session_id: "s1", task: SECRET, task_digest: "a" * 64, root: "/tmp",
        graph_version: "1", behavior_version: "tamoz.agent.session/1",
        tool_catalog_digest: "sha256:#{"b" * 64}", created_at_ms: 0
      )
    end
  end

  def test_a_secret_is_refused_from_request_payload
    with_adapter do |adapter|
      definition = Tamoz.graph(name: "secret.request", version: "1") do
        state :seen, default: ""
        node(:noop, implementation_name: "secret.request.noop", version: "1") do |_s, _c|
          {seen: "ok"}
        end
        edge Tamoz::START, :noop
        edge :noop, Tamoz::END
      end
      app = definition.compile(checkpointer: adapter)

      assert_raises(Tamoz::SensitiveValueError) do
        app.durable_runner.deliver({"token" => SECRET}, thread: "req", request_id: "r0")
      end
    end
  end

  def test_a_secret_is_refused_from_effect_request
    with_adapter do |adapter|
      definition = Tamoz.graph(name: "secret.effect", version: "1") do
        state :ready, default: false
        node(:go, implementation_name: "secret.effect.go", version: "1") { |_s, _c| {ready: true} }
        edge Tamoz::START, :go
        edge :go, Tamoz::END
      end
      app = definition.compile(checkpointer: adapter)
      app.durable_runner.deliver({}, thread: "effect", request_id: "r0")
      store = app.checkpointer
      execution_id = app.state(thread: "effect").execution_id

      assert_raises(Tamoz::SensitiveValueError) do
        store.open_writer(
          thread_id: "effect", namespace: [], owner_id: SecureRandom.uuid,
          ttl: store.writer_ttl
        ) do |writer|
          writer.effects.prepare(
            execution_id:, task_id: "task.leak", call_index: 0,
            operation: "tool.leak", safety: :read_only,
            request: {"authorization" => SECRET}
          )
        end
      end
    end
  end

  def test_a_secret_is_refused_from_schedule_payload
    # A schedule pins a payload REFERENCE (a digest), never the payload itself,
    # so a secret cannot be stored in one by construction. The assertion is
    # that the field refuses a non-reference value rather than accepting a
    # secret-bearing object.
    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::Scheduler::Schedule.new(
        id: "leaky", owner: "human:op", kind: :interval, expression: "3600",
        payload_ref: SECRET, thread_policy: "thread.default",
        capability_grant: {"scopes" => ["read"]},
        behavior_version: "tamoz.agent.session/1",
        delivery_policy: {"mode" => "inbox"}, budgets: {"max_steps" => 10},
        created_by: "human:op", created_at: 1_785_000_000
      )
    end
  end

  # T8.3: the P14 stream engine (which admitted arbitrary source payloads and
  # swept them for secrets) is retired. The supervised worker admits only the
  # stream-sealed snapshot, which is verified by digest and never re-parsed
  # as an admission candidate — there is no stream payload to sweep. The
  # memory admission path (which DOES accept agent-authored statements) keeps
  # the secret sweep via test_a_secret_is_refused_from_episode_statement.
  def test_a_secret_is_refused_from_instrumentation
    context = Tamoz::Context.new(
      run_id: "run", execution_id: "execution", request_id: "request"
    )

    assert_equal :ok, Tamoz.instrument("tamoz.test.sweep", {}, context:) { :ok }
    assert_raises(Tamoz::SensitiveValueError) do
      Tamoz.instrument("tamoz.test.sweep", {"token" => SECRET}, context:) { :ok }
    end
  end

  def test_a_secret_is_refused_from_stream_part
    assert_raises(Tamoz::SensitiveValueError) do
      Tamoz::StreamPart.new(
        type: :message_chunk, namespace: [], run_id: "run", sequence: 1,
        emitted_at: 0, data: {"token" => SECRET}
      )
    end
  end

  def test_a_secret_is_refused_from_context_metadata
    assert_raises(Tamoz::SensitiveValueError) do
      Tamoz::Context.new(
        run_id: "run", execution_id: "execution", request_id: "request",
        metadata: {"authorization" => SECRET}
      )
    end
  end

  # The refusal must be by TYPE, not by key name. A secret hiding under an
  # innocuous key is still refused, and an innocuous value under a
  # scary-looking key is still accepted — "no lossy key-name scrubbing".
  def test_the_refusal_is_by_type_not_by_key_name
    with_adapter do |adapter|
      assert_raises(Tamoz::SensitiveValueError) do
        adapter.store.put("memory", "innocent", {"colour" => SECRET})
      end
      entry = adapter.store.put(
        "memory", "scary", {"password" => "this is a literal string, not a Secret"}
      )

      assert_equal 1, entry.version
      assert_equal({"password" => "this is a literal string, not a Secret"},
                   adapter.store.get("memory", "scary").value)
    end
  end

  # A secret must not leak through its own string conversions either — the
  # place a redaction bug shows up in a log line rather than a store.
  def test_a_secret_never_renders_its_value
    rendered = [SECRET.to_s, SECRET.inspect, format("%s", SECRET), "#{SECRET}"]

    rendered.each do |text|
      refute_includes text, "sk-live-DO-NOT-PERSIST-0123456789",
                      "a secret rendered its value: #{text.inspect}"
    end
  end

  private

  def with_adapter
    Dir.mktmpdir("tamoz-secret-sweep") do |directory|
      path = File.join(directory, "tamoz.sqlite3")
      adapter = Tamoz::SQLite::Adapter.new(path:)
      begin
        yield adapter, path
      ensure
        adapter.close
      end
    end
  end
end
