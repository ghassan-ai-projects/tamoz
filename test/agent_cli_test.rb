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
        assert event.key?("type")
        assert event.key?("data")
      end
      session_event = lines.map { |line| JSON.parse(line) }.find { |event| event["type"] == "cli.session" }
      refute_nil session_event
      assert_equal "completed", session_event["data"]["status"]
    end
  end

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
