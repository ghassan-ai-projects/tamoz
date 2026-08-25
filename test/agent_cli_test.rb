# frozen_string_literal: true

require_relative "test_helper"

class AgentCLITest < Minitest::Test
  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      queue = @responses.fetch(stage)
      raise "no scripted #{stage} response" if queue.empty?

      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  def test_version_needs_no_provider_configuration
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(["--version"], out:, err:, env: {})

    assert_equal 0, status
    assert_equal "#{Tamoz::Agent::VERSION}\n", out.string
    assert_empty err.string
  end

  def test_help_output_is_stable
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(["--help"], out:, err:, env: {})

    assert_equal 0, status
    assert_includes out.string, "Usage: tamoz [global-options] [subcommand] [options] [ARGS]"
    assert_includes out.string, "Interactive:  ask, resume, continue, list, show, follow-up, redirect,"
    assert_includes out.string, "--profile PROFILE"
    assert_includes out.string, "--check NAME=COMMAND"
    assert_includes out.string, "--non-interactive"
  end

  def test_missing_task_is_a_usage_error
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run([], out:, err:, env: {})

    assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
    assert_match(/TASK/, err.string)
  end

  def test_missing_model_is_a_usage_error
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(["inspect this"], out:, err:, env: {})

    assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
    assert_match(/TAMOZ_MODEL/, err.string)
  end

  def test_check_configuration_requires_explicit_change_mode
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(
      ["--check", "test=ruby -c example.rb", "inspect"],
      out:,
      err:,
      env: {"TAMOZ_MODEL" => "model", "OPENAI_API_KEY" => "key"}
    )

    assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
    assert_match(/requires --allow-changes/, err.string)
  end

  def test_ask_creates_session_file
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      factory = ->(_options) do
        ScriptedModel.new(
          plan: [plan_for("read_file", {"path" => "note.txt"}, id: "s1")],
          review: [accepted_review],
          verify: [{"answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"]}]
        )
      end

      out = StringIO.new
      err = StringIO.new
      status = run_cli(
        ["ask", "read note.txt"],
        session: "test-thread", workspace:, session_dir:, out:, err:, factory:
      )

      assert_equal 0, status, err.string
      assert_path_exists File.join(session_dir, "test-thread.sqlite3")
      assert_match(/hello/, out.string)
    end
  end

  def test_adaptive_routing_is_available_on_the_durable_cli_surface
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      factory = ->(_options) do
        ScriptedModel.new(
          adaptive_decide: [
            {"decision" => "action", "capability_id" => "read_file",
             "arguments" => {"path" => "note.txt"}},
            {"decision" => "final", "answer" => "hello",
             "evidence_refs" => ["observation:0"]}
          ]
        )
      end
      out = StringIO.new
      err = StringIO.new

      status = run_cli(
        ["--adaptive-routing", "ask", "read note.txt"],
        session: "adaptive-cli", workspace:, session_dir:, out:, err:, factory:
      )

      assert_equal 0, status, err.string
      assert_includes out.string, "hello"
    end
  end

  # `list` must actually report the threads it wrote. The command had no test
  # and a blanket StandardError rescue in `list_entry`, so a NoMethodError
  # turned every listing into an empty table without any error.
  def test_list_reports_a_written_session
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      factory = ->(_options) do
        ScriptedModel.new(
          plan: [plan_for("read_file", {"path" => "note.txt"}, id: "s1")],
          review: [accepted_review],
          verify: [{"answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"]}]
        )
      end
      assert_equal 0, run_cli(
        ["ask", "read note.txt"],
        session: "listed-thread", workspace:, session_dir:, factory:
      )

      out = StringIO.new
      status = run_cli(["--json", "list"], workspace:, session_dir:, out:, factory:)
      assert_equal 0, status

      threads = JSON.parse(out.string).fetch("threads")
      assert_equal ["listed-thread"], threads.map { |entry| entry.fetch("thread_id") }
      entry = threads.fetch(0)
      assert_equal "completed", entry.fetch("status")
      assert_match(/read note.txt/, entry.fetch("summary"))
      assert_operator entry.fetch("updated_at_ms"), :>, 0
    end
  end

  # P15-A/P15-G (ledger gap 12): every subcommand needs one behavioural
  # assertion on its RENDERED output. `show` was only ever exercised inside the
  # redaction test, which asserts what is *absent* — a `show` that printed
  # nothing at all would have passed it.
  def test_show_renders_the_thread_state_in_both_modes
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      factory = ->(_options) do
        ScriptedModel.new(
          plan: [plan_for("read_file", {"path" => "note.txt"}, id: "s1")],
          review: [accepted_review],
          verify: [{"answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"]}]
        )
      end
      assert_equal 0, run_cli(
        ["ask", "read note.txt"],
        session: "shown", workspace:, session_dir:, factory:
      )

      json_out = StringIO.new
      err = StringIO.new
      status = run_cli(
        ["--json", "show", "shown"],
        workspace:, session_dir:, out: json_out, err:, factory:
      )
      assert_equal 0, status, err.string
      document = JSON.parse(json_out.string)
      assert_equal "shown", document.fetch("thread_id")
      assert_equal "completed", document.fetch("status")
      refute_nil document.fetch("checkpoint_id")
      assert_operator document.fetch("sequence"), :>, 0
      assert_equal "completed_without_check", document.fetch("terminal").fetch("reason")

      human_out = StringIO.new
      status = run_cli(
        ["show", "shown"],
        workspace:, session_dir:, out: human_out, factory:
      )
      assert_equal 0, status
      assert_match(/\AThread: shown$/, human_out.string)
      assert_match(/^Status: completed$/, human_out.string)
      assert_match(/^Terminal: completed_without_check/, human_out.string)
    end
  end

  # `continue` drives a paused thread forward with no new input. Without a test
  # the verb could stop resolving its thread, or silently start a second turn,
  # and nothing in the corpus would notice.
  def test_continue_advances_a_paused_thread_without_new_input
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)
      checks = {"answer" => check_argv}

      assert_equal Tamoz::Agent::CLI::EXIT_PAUSED, run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )
      paused = latest_request_record(session_dir, "th")

      err = StringIO.new
      status = run_cli(
        ["--non-interactive", "continue", "th"],
        workspace:, session_dir:, input: StringIO.new, err:, factory:, checks:
      )

      # The approval interrupt is still outstanding and `continue` supplies no
      # answers, so the thread stays paused rather than acting unreviewed.
      assert_equal Tamoz::Agent::CLI::EXIT_PAUSED, status, err.string
      assert_equal "value = 1\n", File.read(File.join(workspace, "app.rb"))
      continued = latest_request_record(session_dir, "th")
      refute_equal paused.request_id, continued.request_id,
                   "continue must enqueue its own request, not reuse the paused one"
    end
  end

  # `resolve` is the ONLY way an `:unknown` effect leaves that state. It had no
  # test: a change that made the human resolution a no-op would have been
  # invisible.
  def test_resolve_records_a_human_effect_resolution
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)
      checks = {"answer" => check_argv}

      run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      # An `:unknown` effect is the only state human resolution exists for, so
      # the fixture reproduces one the way the runtime does: an unsafe attempt
      # whose lease expires while it is running.
      effect_key = nil
      decision = nil
      database_path = File.join(session_dir, "th.sqlite3")
      with_thread_session(session_dir, workspace, digest) do |session|
        store = session.app.checkpointer
        execution_id = session.view(thread: "th").execution_id
        store.open_writer(
          thread_id: "th", namespace: [], owner_id: SecureRandom.uuid, ttl: store.writer_ttl
        ) do |writer|
          decision = writer.effects.prepare(
            execution_id:,
            task_id: "task.resolve_probe",
            call_index: 0,
            operation: "tool.apply_patch",
            safety: :unsafe,
            request: {"tool" => "apply_patch"}
          )
          effect_key = decision.record.key
          writer.effects.start(key: effect_key, attempt_token: decision.attempt_token)
        end
        expire_effect_attempt(database_path, decision.attempt_token)
        store.open_writer(
          thread_id: "th", namespace: [], owner_id: SecureRandom.uuid, ttl: store.writer_ttl
        ) do |writer|
          recovery = writer.effects.prepare(
            execution_id:,
            task_id: "task.resolve_probe",
            call_index: 0,
            operation: "tool.apply_patch",
            safety: :unsafe,
            request: {"tool" => "apply_patch"}
          )
          assert_equal :unknown, recovery.record.status
        end
      end
      refute_nil effect_key

      out = StringIO.new
      err = StringIO.new
      status = run_cli(
        ["resolve", "th", effect_key, "abandoned"],
        workspace:, session_dir:, out:, err:, factory:, checks:
      )

      assert_equal 0, status, err.string
      assert_match(/Resolved #{Regexp.escape(effect_key)} as abandoned\./, out.string)

      # The resolution is a durable audited transition, not a silent status
      # flip: the CLI's actor is on the thread's transition log.
      actors = effect_transition_actors(database_path, effect_key)
      assert_includes actors, "tamoz.cli"

      with_thread_session(session_dir, workspace, digest) do |session|
        record = session.effect(thread: "th", effect_key:)
        assert_equal :abandoned, record.status
      end
    end
  end

  def effect_transition_actors(path, effect_key)
    database = SQLite3::Database.new(path)
    database.execute(
      "SELECT actor FROM tamoz_effect_transitions WHERE effect_key = ?",
      [effect_key]
    ).flatten.compact
  ensure
    database&.close
  end

  def expire_effect_attempt(path, token)
    database = SQLite3::Database.new(path)
    database.execute(
      "UPDATE tamoz_effect_attempts SET deadline_ms = 0 WHERE attempt_token = ?",
      [token]
    )
  ensure
    database&.close
  end

  def with_thread_session(session_dir, workspace, digest)
    adapter = Tamoz::SQLite::Adapter.new(
      path: File.join(session_dir, "th.sqlite3"),
      limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
    )
    begin
      yield build_session(
        model: repair_model(digest), root: workspace, adapter:,
        allow_changes: true, checks: {"answer" => check_argv}
      )
    ensure
      adapter.close
    end
  end

  def test_resume_collects_interrupt_answers
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)

      checks = {"answer" => check_argv}
      status1 = run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )
      assert_equal Tamoz::Agent::CLI::EXIT_PAUSED, status1

      input = StringIO.new("y\ny\n")
      err = StringIO.new
      status2 = run_cli(
        ["resume", "th"],
        workspace:, session_dir:, input:, err:, factory:, checks:
      )

      assert_equal 0, status2, err.string
      assert_equal "value = 2\n", File.read(File.join(workspace, "app.rb"))
    end
  end

  def test_resume_non_interactive_with_answer
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)
      checks = {"answer" => check_argv}

      run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      input = StringIO.new
      status = run_cli(
        ["--non-interactive", "resume", "--answer", "y", "th"],
        workspace:, session_dir:, input:, factory:, checks:
      )

      assert_equal 0, status
      assert_equal "value = 2\n", File.read(File.join(workspace, "app.rb"))
    end
  end

  def test_duplicate_request_id_is_idempotent
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)
      checks = {"answer" => check_argv}

      run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      original = latest_request_record(session_dir, "th")
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(session_dir, "th.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
      )
      begin
        session = build_session(
          model: repair_model(digest),
          root: workspace,
          adapter:,
          allow_changes: true,
          checks: {"answer" => check_argv}
        )
        duplicate = session.app.durable_runner.submit(
          {"task" => "set value to 2"},
          thread: "th",
          request_id: original.request_id,
          operation: :turn,
          delivery: :queue
        )
        assert_equal original.request_id, duplicate.request_id
        assert_equal original.status, duplicate.status
      ensure
        adapter.close
      end
    end
  end

  def test_follow_up_queues_behind_paused_request
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)
      checks = {"answer" => check_argv}

      run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      err = StringIO.new
      status = run_cli(
        ["follow-up", "th", "also set value to 3"],
        workspace:, session_dir:, input: StringIO.new, err:, factory:, checks:
      )

      assert_equal Tamoz::Agent::CLI::EXIT_PAUSED, status
      assert_match(/queued/, err.string)
    end
  end

  def test_cli_follow_up_uses_the_same_canonical_turn_payload_as_telegram
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)
      checks = {"answer" => check_argv}

      run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      run_cli(
        ["follow-up", "th", "also set value to 3"],
        workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(session_dir, "th.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
      )
      begin
        session = build_session(
          model: repair_model(digest), root: workspace, adapter:, allow_changes: true, checks:
        )
        requests = session.app.checkpointer.request_history(thread_id: "th", namespace: [])
        follow_up = requests.last

        assert_equal Tamoz::Agent::SessionPlanningContext.turn_payload(
          thread_id: "th",
          request_id: follow_up.request_id,
          text: "also set value to 3",
          fragments: [{"role" => "user", "text" => "set value to 2"}]
        ), follow_up.payload
      ensure
        adapter.close
      end
    end
  end

  def test_redirect_replaces_in_flight_goal
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      File.write(File.join(workspace, "note.txt"), "hello\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      repair = repair_factory(digest)
      read_only = ->(_options) do
        ScriptedModel.new(
          plan: [
            plan_for("read_file", {"path" => "note.txt"}, id: "s1"),
            noop_action_plan(check_name: "answer")
          ],
          review: [accepted_review],
          verify: [{"answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"]}]
        )
      end
      call_count = 0
      factory = ->(options) do
        call_count += 1
        call_count == 1 ? repair.call(options) : read_only.call(options)
      end

      checks = {"answer" => [RbConfig.ruby, "-e", "exit 0"]}
      run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      status = run_cli(
        ["redirect", "th", "read note.txt"],
        workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      assert_equal Tamoz::Agent::CLI::EXIT_PAUSED, status
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(session_dir, "th.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
      )
      begin
        view = Tamoz::Agent::Session.new(
          model: read_only.call({}),
          toolbox: Tamoz::Agent::Toolbox.new(root: workspace, allow_changes: true),
          checkpointer: adapter
        ).view(thread: "th")
        assert_equal "read note.txt", view.state[:task]
      ensure
        adapter.close
      end
    end
  end

  def test_cancel_routes_to_terminal
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)
      checks = {"answer" => check_argv}

      run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      status = run_cli(
        ["cancel", "--force", "th"],
        workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      assert_equal 0, status
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(session_dir, "th.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0)
      )
      begin
        view = Tamoz::Agent::Session.new(
          model: factory.call({}),
          toolbox: Tamoz::Agent::Toolbox.new(root: workspace, allow_changes: true, checks: {"answer" => check_argv}),
          checkpointer: adapter
        ).view(thread: "th")
        assert_equal "cancelled_by_user", view.terminal.fetch("reason")
      ensure
        adapter.close
      end
    end
  end

  def test_eof_exits_three_when_interactive
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)
      checks = {"answer" => check_argv}

      run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      status = run_cli(
        ["resume", "th"],
        workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )

      assert_equal Tamoz::Agent::CLI::EXIT_PAUSED, status
    end
  end

  def test_sigint_exits_one_thirty
    cli = Tamoz::Agent::CLI.new(
      out: StringIO.new,
      err: StringIO.new,
      input: StringIO.new,
      env: {}
    )
    cancellation = Tamoz::CancellationToken.new
    cli.instance_variable_set(:@cancellation, cancellation)
    cancellation.cancel!("sigint")

    assert_equal Tamoz::Agent::CLI::EXIT_SIGINT, cli.send(:exit_for_cancellation)
  end

  def test_sigterm_exits_one_forty_three
    cli = Tamoz::Agent::CLI.new(
      out: StringIO.new,
      err: StringIO.new,
      input: StringIO.new,
      env: {}
    )
    cancellation = Tamoz::CancellationToken.new
    cli.instance_variable_set(:@cancellation, cancellation)
    cancellation.cancel!("sigterm")

    assert_equal Tamoz::Agent::CLI::EXIT_SIGTERM, cli.send(:exit_for_cancellation)
  end

  def test_two_owners_cannot_advance_same_thread
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      digest = Digest::SHA256.hexdigest("value = 1\n")
      factory = repair_factory(digest)
      checks = {"answer" => check_argv}
      status = run_cli(
        ["ask", "set value to 2"],
        session: "th", workspace:, session_dir:, input: StringIO.new, factory:, checks:
      )
      assert_equal Tamoz::Agent::CLI::EXIT_PAUSED, status

      # A second owner holding the namespace lease must fence out the resume.
      path = File.join(session_dir, "th.sqlite3")
      foreign = Tamoz::SQLite::Adapter.new(
        path:, limits: Tamoz::SQLite::Limits.new(lease_ttl: 30.0)
      )
      begin
        foreign_session = build_session(
          model: factory.call({}), root: workspace, adapter: foreign,
          allow_changes: true, checks:
        )
        store = foreign_session.app.checkpointer
        store.open_writer(thread_id: "th", namespace: [], owner_id: "owner.foreign", ttl: 30.0) do
          err = StringIO.new
          status = run_cli(
            ["resume", "th", "--answer", "y"],
            workspace:, session_dir:, input: StringIO.new("y\n"), err:, factory:, checks:
          )
          assert_equal 1, status
          assert_match(/lease|conflict/i, err.string)
        end
      ensure
        foreign.close
      end
    end
  end

  def test_sensitive_content_is_not_rendered_to_streams_or_transcript
    with_cli_workspace do |workspace, session_dir|
      secret = "sk-live-gauntlet-probe-secret"
      File.write(File.join(workspace, "note.txt"), "payload #{secret}\n")
      factory = ->(_options) do
        ScriptedModel.new(
          plan: [plan_for("read_file", {"path" => "note.txt"}, id: "s1")],
          review: [accepted_review],
          verify: [{"answer" => "read complete", "satisfied" => true, "evidence" => ["note.txt"]}]
        )
      end

      out = StringIO.new
      err = StringIO.new
      status = run_cli(
        ["--json", "ask", "read note.txt"],
        session: "th", workspace:, session_dir:, out:, err:, factory:
      )
      assert_equal 0, status, err.string
      refute_includes out.string, secret
      refute_includes err.string, secret

      show_out = StringIO.new
      show_err = StringIO.new
      status = run_cli(
        ["--json", "show", "th"],
        workspace:, session_dir:, out: show_out, err: show_err, factory:
      )
      assert_equal 0, status, show_err.string
      refute_includes show_out.string, secret
      refute_includes show_err.string, secret
    end
  end

  def test_json_event_stream_is_ndjson
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      factory = ->(_options) do
        ScriptedModel.new(
          plan: [plan_for("read_file", {"path" => "note.txt"}, id: "s1")],
          review: [accepted_review],
          verify: [{"answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"]}]
        )
      end

      out = StringIO.new
      status = run_cli(
        ["--json", "ask", "read note.txt"],
        session: "th", workspace:, session_dir:, out:, err: StringIO.new, factory:
      )

      assert_equal 0, status
      lines = out.string.lines
      refute_empty lines
      lines.each do |line|
        event = JSON.parse(line)
        assert_equal 1, event.fetch("schema")
        assert event.key?("type")
        assert event.key?("data")
        assert event.key?("task_state")
        assert event.key?("delivery_state")
      end
      session_event = lines.map { |line| JSON.parse(line) }.find { |event| event["type"] == "cli.session" }
      refute_nil session_event
      assert_equal "completed", session_event["data"]["status"]
    end
  end

  # The machine contract: a StreamPart-backed line carries the part's full
  # identity (run_id, task_id, sequence, emitted_at) so it survives the
  # round-trip, sequences increase within one run, and synthetic local events
  # (cli.session) carry no null-valued identity keys.
  def test_json_envelope_preserves_stream_part_identity
    with_cli_workspace do |workspace, session_dir|
      File.write(File.join(workspace, "note.txt"), "hello\n")
      factory = ->(_options) do
        ScriptedModel.new(
          plan: [plan_for("read_file", {"path" => "note.txt"}, id: "s1")],
          review: [accepted_review],
          verify: [{"answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"]}]
        )
      end

      out = StringIO.new
      status = run_cli(
        ["--json", "ask", "read note.txt"],
        session: "th", workspace:, session_dir:, out:, err: StringIO.new, factory:
      )

      assert_equal 0, status
      events = out.string.lines.map { |line| JSON.parse(line) }
      stream_events = events.select { |event| event.key?("run_id") }
      synthetic_events = events.reject { |event| event.key?("run_id") }

      refute_empty stream_events
      first = stream_events.first
      assert_instance_of String, first.fetch("run_id")
      refute_empty first.fetch("run_id")
      stream_events.each do |event|
        assert_instance_of String, event.fetch("type")
        refute_empty event.fetch("type")
        assert_instance_of Integer, event.fetch("sequence")
        assert_operator event.fetch("sequence"), :>=, 0
        assert_kind_of Numeric, event.fetch("emitted_at")
        assert event.key?("task_id")
      end

      run_sequences = Hash.new { |hash, key| hash[key] = [] }
      stream_events.each { |event| run_sequences[event.fetch("run_id")] << event.fetch("sequence") }
      run_sequences.each_value do |sequences|
        assert_equal sequences.sort, sequences, "sequence must increase in emission order"
        assert_equal sequences.uniq.size, sequences.size
      end
      assert_operator run_sequences.values.count { |sequences| sequences.size > 1 }, :>=, 1,
                     "at least one run must emit multiple sequenced events"

      session_event = events.find { |event| event["type"] == "cli.session" }
      refute_nil session_event
      assert_includes stream_events.map { |event| event.fetch("run_id") },
                      session_event["data"]["request_id"]
      synthetic_events.each do |event|
        refute event.key?("task_id")
        refute event.key?("sequence")
        refute event.key?("emitted_at")
      end
    end
  end

  # --- Error taxonomy (characterization of the run() rescue chain, Q2) ---
  # Each error class has a pinned exit code and "tamoz: " message prefix; a
  # generic error must NOT be swallowed into a clean exit — it propagates so
  # the operator sees the backtrace. Mutating any exit code or removing a
  # rescue here must fail the corresponding test.

  def test_tool_error_exits_one_with_message
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(
      ["read note.txt"],
      out:, err:, env: {},
      model_factory: raising_factory(Tamoz::Core::ToolError.new("boom"))
    )

    assert_equal 1, status
    assert_match(/tamoz: boom/, err.string)
  end

  def test_checkpoint_conflict_exits_one_with_message
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(
      ["read note.txt"],
      out:, err:, env: {},
      model_factory: raising_factory(Tamoz::CheckpointConflictError.new("conflict"))
    )

    assert_equal 1, status
    assert_match(/tamoz: conflict/, err.string)
  end

  def test_unexpected_error_propagates_instead_of_clean_exit
    out = StringIO.new
    err = StringIO.new

    assert_raises(RuntimeError) do
      Tamoz::Agent::CLI.run(
        ["read note.txt"],
        out:, err:, env: {},
        model_factory: raising_factory(RuntimeError.new("boom"))
      )
    end
  end

  # --- --check argument validation (parse seam) ---

  def test_check_with_empty_name_is_usage_error
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(["--check", "=ruby -c app.rb", "inspect"], out:, err:, env: {})

    assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
    assert_match(/check must be NAME=COMMAND/, err.string)
  end

  def test_check_with_empty_command_is_usage_error
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(["--check", "lint=", "inspect"], out:, err:, env: {})

    assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
    assert_match(/check must be NAME=COMMAND/, err.string)
  end

  def test_duplicate_check_is_usage_error
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(
      ["--check", "lint=ruby -c app.rb", "--check", "lint=ruby -w app.rb", "inspect"],
      out:, err:, env: {}
    )

    assert_equal Tamoz::Agent::CLI::USAGE_ERROR, status
    assert_match(/duplicate check/, err.string)
  end

  # --- Interactive answer vocabulary (map_answer contract) ---
  # The words an operator types at an approval/clarify/resolve prompt are a
  # stable user-facing contract. These pin the mapping through the CLI's own
  # private seam (send) because the vocabulary is exactly what a full-flow test
  # would exercise, at a fraction of the fixture cost.

  def test_approve_tool_answer_vocabulary
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})

    assert cli.send(:map_answer, "approve_tool", "y")
    assert cli.send(:map_answer, "approve_tool", "yes")
    assert cli.send(:map_answer, "approve_tool", "a")
    assert cli.send(:map_answer, "approve_tool", "approve")
    refute cli.send(:map_answer, "approve_tool", "n")
    refute cli.send(:map_answer, "approve_tool", "deny")
    assert_raises(ArgumentError) { cli.send(:map_answer, "approve_tool", "maybe") }
  end

  def test_resolve_effect_answer_vocabulary
    cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})

    %w[fixed approve ok succeeded yes].each do |word|
      assert_equal :succeeded, cli.send(:map_answer, "resolve_effect", word), word
    end
    %w[skipped deny no abandoned].each do |word|
      assert_equal :abandoned, cli.send(:map_answer, "resolve_effect", word), word
    end
    assert_equal :failed, cli.send(:map_answer, "resolve_effect", "failed")
    assert_equal :unknown, cli.send(:map_answer, "resolve_effect", "?")
    assert_raises(ArgumentError) { cli.send(:map_answer, "resolve_effect", "maybe") }
  end

  # --- Milestone facts on the CLI ---
  # A committed milestone never rides a turn-scoped stream event (the engine
  # emits run/task/update/checkpoint parts only), so there is no in-turn
  # milestone renderer to pin here. The operator surface for those facts is
  # the reconnectable view, pinned by the live-dispatch tests in
  # test/cancellation_visibility_test.rb.

  private

  def with_cli_workspace
    Dir.mktmpdir("tamoz-cli") do |directory|
      workspace = File.join(directory, "workspace")
      session_dir = File.join(directory, "sessions")
      FileUtils.mkdir_p(workspace)
      yield workspace, session_dir
    end
  end

  def run_cli(argv, workspace:, session_dir:, out: StringIO.new, err: StringIO.new, input: StringIO.new, factory:, session: nil, checks: nil)
    global_argv = ["--session-dir", session_dir, "--root", workspace, "--allow-changes"]
    global_argv += ["--session", session] if session
    if checks
      checks.each do |name, command|
        global_argv += ["--check", "#{name}=#{Shellwords.join(command)}"]
      end
    end
    Tamoz::Agent::CLI.run(global_argv + argv, out:, err:, input:, env: {}, model_factory: factory)
  end

  def repair_factory(digest)
    ->(_options) { repair_model(digest) }
  end

  class RaisingModel
    def initialize(error)
      @error = error
    end

    def generate(**)
      raise @error
    end
  end

  def raising_factory(error)
    ->(_options) { RaisingModel.new(error) }
  end

  def repair_model(digest)
    ScriptedModel.new(
      plan: [plan_for("read_file", {"path" => "app.rb"}, id: "look"), action_plan(digest)],
      review: [accepted_review],
      verify: [{"answer" => "value is 2", "satisfied" => true, "evidence" => ["app.rb"]}]
    )
  end

  def build_session(model:, root:, adapter:, allow_changes: false, checks: {}, **options)
    Tamoz::Agent::Session.new(
      model:,
      toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes:, checks:),
      checkpointer: adapter,
      **options
    )
  end

  def latest_request_record(session_dir, thread_id)
    path = File.join(session_dir, "#{thread_id}.sqlite3")
    adapter = Tamoz::SQLite::Adapter.new(path:, limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0))
    begin
      row = adapter.__send__(:read, operation: "test.requests") do |tx|
        tx.first(
          "test.requests",
          <<~SQL,
            SELECT request_id, status
            FROM tamoz_requests
            WHERE thread_id = ?
            ORDER BY enqueue_sequence DESC
            LIMIT 1
          SQL
          [thread_id]
        )
      end
      Tamoz::Graph::RequestRecord.new(
        thread_id: thread_id,
        namespace: [],
        request_id: row.fetch(0),
        enqueue_sequence: 0,
        input_digest: "",
        operation: :turn,
        delivery_mode: :queue,
        status: row.fetch(1).to_sym,
        payload: {},
        execution_id: nil,
        target_execution_id: nil,
        cancellation_generation: nil,
        checkpoint_id: nil,
        response: nil,
        terminal_error: nil,
        retryable: nil,
        created_at_ms: 0,
        updated_at_ms: 0
      )
    ensure
      adapter.close
    end
  end

  def plan_for(tool, arguments, id: "s1")
    {
      "goal" => "answer the task",
      "done_when" => ["the tool returned evidence"],
      "steps" => [
        {
          "id" => id,
          "purpose" => "gather evidence",
          "tool" => tool,
          "arguments" => arguments,
          "verification" => "the output is present"
        }
      ]
    }
  end

  def action_plan(digest)
    {
      "goal" => "set value to 2",
      "done_when" => ["app.rb contains value = 2 and the check passes"],
      "steps" => [
        {
          "id" => "edit",
          "purpose" => "apply the exact replacement",
          "tool" => "apply_patch",
          "arguments" => {
            "path" => "app.rb",
            "expected_sha256" => digest,
            "before" => "value = 1",
            "after" => "value = 2"
          },
          "verification" => "the receipt reports the new digest"
        },
        {
          "id" => "check",
          "purpose" => "run the configured check",
          "tool" => "run_check",
          "arguments" => {"name" => "answer"},
          "verification" => "the check exits zero"
        }
      ]
    }
  end

  def noop_action_plan(check_name: nil)
    steps = [
      {
        "id" => "noop",
        "purpose" => "record that no mutation is required",
        "tool" => nil,
        "arguments" => {},
        "verification" => "the observation records the no-op"
      }
    ]
    if check_name
      steps << {
        "id" => "check",
        "purpose" => "run the configured check",
        "tool" => "run_check",
        "arguments" => {"name" => check_name},
        "verification" => "the check exits zero"
      }
    end
    {
      "goal" => "confirm no further action is needed",
      "done_when" => ["the read-only evidence answers the task"],
      "steps" => steps
    }
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "sound"}
  end

  def check_argv
    [RbConfig.ruby, "-e", %q{abort("wrong") unless File.read("app.rb") == "value = 2\n"}]
  end
end
