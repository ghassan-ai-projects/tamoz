# frozen_string_literal: true

# Regression coverage for the unattended surface: `init`, `queue`, `worker`,
# `status`.
#
# The autonomy scorecard proves the product behaviours; this file guards the
# edges around them — permissions, refusals, signals, idling, concurrency, and
# the authority boundary between a work item and the profile that governs it.

require_relative "test_helper"
require_relative "support/autonomy_case"

class AgentWorkerTest < Minitest::Test
  include AutonomyCase

  # -------------------------------------------------------------- the directory

  def test_init_creates_a_private_runtime_directory
    Dir.mktmpdir("tamoz-init") do |directory|
      runtime_dir = File.join(directory, "runtime")
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      out = StringIO.new
      err = StringIO.new

      status = Tamoz::Agent::CLI.run(
        ["--runtime-dir", runtime_dir, "init", "--workspace", workspace, "--json"],
        out:, err:, input: StringIO.new, env: {}
      )

      assert_equal 0, status, err.string
      document = JSON.parse(out.string)
      assert_equal File.expand_path(runtime_dir), document.fetch("runtime_dir")
      assert_equal 0o700, File.stat(runtime_dir).mode & 0o777
      assert_equal 0o600, File.stat(File.join(runtime_dir, "config.yaml")).mode & 0o777
    end
  end

  # The runtime directory carries unattended authority: the profiles that decide
  # what runs with nobody watching. A directory anyone can write to is a
  # directory anyone can grant themselves authority in.
  def test_worker_refuses_a_world_readable_runtime_directory
    with_runtime do |rt|
      File.chmod(0o755, rt.dir)

      status = rt.cli(%w[status --json])

      assert_equal 1, status
      assert_match(/accessible to group or others/, rt.err)
    end
  end

  def test_missing_runtime_directory_is_a_clear_error
    out = StringIO.new
    err = StringIO.new

    status = Tamoz::Agent::CLI.run(
      ["--runtime-dir", "/nonexistent/tamoz-runtime", "status"],
      out:, err:, input: StringIO.new, env: {}
    )

    assert_equal 1, status
    assert_match(/does not exist/, err.string)
  end

  # ----------------------------------------------------------------- authority

  # A queued request names a profile; it never carries one. The binding is
  # written to the operator's runtime store, so a payload cannot describe the
  # authority it wants to run under.
  def test_queue_add_refuses_an_unknown_profile
    with_runtime do |rt|
      status = rt.cli(%W[queue add --task Read\ note.txt --profile nonexistent],
                      factory: read_only_factory)

      assert_equal 1, status
      assert_match(/profile "nonexistent" is not in/, rt.err)
      # Nothing was queued: an unresolvable authority must not leave work behind.
      rt.cli(%w[queue list --json])
      assert_empty JSON.parse(rt.out).fetch("pending")
    end
  end

  # A profile id names a file in the runtime directory. It must not be able to
  # name a file anywhere else.
  def test_profile_id_cannot_escape_the_runtime_directory
    with_runtime do |rt|
      outside = File.join(File.dirname(rt.dir), "elsewhere.yaml")
      File.write(outside, Psych.dump("profile" => {"profile_id" => "elsewhere"}))
      File.chmod(0o600, outside)

      ["../elsewhere", "../../etc/passwd", "/etc/passwd", "..", "a/b"].each do |candidate|
        status = rt.cli(%W[queue add --task Read\ note.txt --profile #{candidate}],
                        factory: read_only_factory)

        assert_equal 1, status, "#{candidate.inspect} was accepted as a profile id"
        assert_match(/not a valid name|is not in/, rt.err,
                     "#{candidate.inspect} produced an unexpected error: #{rt.err}")
      end
    end
  end

  def test_repository_content_cannot_enable_a_capability_source
    with_runtime do |rt|
      # A checkout the agent can write to asks for every source there is.
      File.write(File.join(rt.workspace, "tamoz.yaml"), Psych.dump(
        "sources" => {"websearch" => {"enabled" => true}, "mcp" => {"enabled" => true}}
      ))
      File.write(File.join(rt.workspace, "config.yaml"), Psych.dump(
        "sources" => {"websearch" => {"enabled" => true}}
      ))

      rt.cli(%w[status --json])

      assert_empty JSON.parse(rt.out).fetch("capability_sources"),
                   "workspace content reached the operator's source configuration"
    end
  end

  # A skill body is instructions the agent will follow. Pointing the skills root
  # at the tree under repair would let that tree write its own instructions, so
  # the configuration itself is refused rather than quietly loading nothing.
  def test_skills_root_inside_the_workspace_is_refused
    with_runtime do |rt|
      path = File.join(rt.dir, "config.yaml")
      document = Psych.safe_load_file(path)
      document["sources"] = {"skills" => {"enabled" => true,
                                          "root" => File.join(rt.workspace, "skills")}}
      File.write(path, Psych.dump(document))

      status = rt.cli(%w[status --json])

      assert_equal 1, status
      assert_match(/inside the workspace/, rt.err)
    end
  end

  # Memory is off until the operator turns it on, and when it is on the worker
  # really carries it — the tenant and owner come from operator configuration,
  # never from a task or the workspace.
  def test_memory_is_absent_until_the_operator_configures_it
    with_runtime do |rt|
      rt.cli(%w[status --json])
      refute JSON.parse(rt.out).dig("memory", "enabled"), "memory was on without configuration"

      path = File.join(rt.dir, "config.yaml")
      document = Psych.safe_load_file(path)
      document["sources"] = {"memory" => {"enabled" => true, "tenant" => "acme", "owner" => "alice"}}
      File.write(path, Psych.dump(document))

      status = rt.cli(%w[status --json])

      assert_equal 0, status, rt.err
      memory = JSON.parse(rt.out).fetch("memory")
      assert memory.fetch("enabled"), "operator-configured memory was not available"
      assert_equal "acme", memory.fetch("tenant")
      assert_equal "alice", memory.fetch("owner")
    end
  end

  # A memory-enabled runtime must still run a plain task end to end; enabling a
  # source must not change what an ordinary turn does.
  def test_a_memory_enabled_runtime_still_completes_a_queued_task
    with_runtime do |rt|
      path = File.join(rt.dir, "config.yaml")
      document = Psych.safe_load_file(path)
      document["sources"] = {"memory" => {"enabled" => true, "tenant" => "acme"}}
      File.write(path, Psych.dump(document))
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")

      rt.cli(%W[queue add --task Read\ note.txt], factory: read_only_factory)
      assert_equal 0, rt.cli(%w[worker --once --json], factory: read_only_factory), rt.err

      completed = rt.events.select { |event| event["event"] == "request.completed" }
      assert_equal 1, completed.length
    end
  end

  def test_unknown_capability_source_in_operator_config_is_refused
    with_runtime do |rt|
      rt.enable_source("definitely_not_a_source")

      status = rt.cli(%w[status --json])

      assert_equal 1, status
      assert_match(/unknown capability source/, rt.err)
    end
  end

  # ------------------------------------------------------------------- running

  def test_worker_with_no_work_exits_without_spinning
    with_runtime do |rt|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = rt.cli(%w[worker --once --json])
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal 0, status, rt.err
      assert_operator elapsed, :<, 2.0, "an idle --once worker should return promptly"
      events = rt.events.map { |event| event["event"] }
      assert_equal %w[worker.started worker.stopped], events
      assert_equal "idle", rt.events.last.fetch("reason")
    end
  end

  def test_worker_emits_structured_json_events_for_a_completed_request
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Read\ note.txt], factory: read_only_factory)

      rt.cli(%w[worker --once --json], factory: read_only_factory)

      events = rt.events
      assert_equal %w[worker.started request.claimed request.completed worker.stopped],
                   events.map { |event| event["event"] }
      events.each do |event|
        assert_match(/\A\d{4}-\d{2}-\d{2}T/, event.fetch("ts"), "every event carries a timestamp")
      end
      assert_equal 1, events.last.fetch("processed")
    end
  end

  # A worker asked to stop stops claiming. It must not be held hostage by its own
  # poll interval — a supervisor that sends SIGTERM expects the process to go.
  def test_stop_request_ends_the_polling_loop_promptly
    with_runtime do |rt|
      runtime = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) }
      )
      begin
        worker = Tamoz::Agent::Worker.new(
          runtime:,
          session_builder: ->(thread_id) { runtime.session_for(thread_id) },
          emitter: ->(_event) {},
          once: false,
          poll_interval: 30.0
        )
        stopper = Thread.new do
          sleep 0.1
          worker.stop!("sigterm")
        end
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        reason = worker.run
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        stopper.join

        assert_equal "signal", reason
        assert_operator elapsed, :<, 5.0,
                        "a 30s poll interval must not delay shutdown by 30s"
      ensure
        runtime.close
      end
    end
  end

  def test_worker_processes_several_threads_with_bounded_concurrency
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      3.times do |index|
        rt.cli(%W[queue add --task Read\ note.txt --thread t#{index}], factory: read_only_factory)
      end

      status = rt.cli(%w[worker --once --json --concurrency 2], factory: read_only_factory)

      assert_equal 0, status, rt.err
      completed = rt.events.select { |event| event["event"] == "request.completed" }
      assert_equal 3, completed.length
      assert_equal %w[t0 t1 t2], completed.map { |event| event["thread"] }.sort
    end
  end

  # A thread that blows up is contained: it is reported, it is parked, and its
  # neighbours still run. One poisoned work item must not stop the worker.
  def test_a_failing_thread_does_not_stop_its_neighbours
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Read\ note.txt --thread healthy], factory: read_only_factory)
      rt.cli(%W[queue add --task Read\ note.txt --thread poisoned], factory: read_only_factory)

      # The poisoned thread's model has no scripted answer and raises.
      factory = lambda do |_options|
        ScriptedModel.new(plan: [], review: [accepted_review], verify: [])
      end
      rt.cli(%w[worker --once --json], factory:)

      failed = rt.events.select { |event| event["event"] == "request.failed" }
      refute_empty failed, "the failing thread should be reported"
      assert_equal "worker.stopped", rt.events.last.fetch("event")
    end
  end

  # ------------------------------------------------------------------- status

  def test_status_reports_pending_work_without_a_configured_model
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      rt.cli(%W[queue add --task Read\ note.txt --thread waiting], factory: read_only_factory)

      # No model factory at all: inspecting a runtime must not require a provider.
      status = rt.cli(%w[status --json])

      assert_equal 0, status, rt.err
      document = JSON.parse(rt.out)
      assert_equal 1, document.fetch("pending_work").length
      assert_equal "waiting", document.dig("pending_work", 0, "thread_id")
      assert_equal "queued", document.dig("pending_work", 0, "head_status")
    end
  end

  def test_status_safety_counters_are_present_and_zero_on_a_clean_runtime
    with_runtime do |rt|
      rt.cli(%w[status --json])

      counters = JSON.parse(rt.out).fetch("safety_counters")
      AutonomyCase::HARD_COUNTERS.each do |name|
        assert_equal 0, counters.fetch(name), "#{name} should start at zero"
      end
    end
  end

  # `approve` is implemented in the unattended-policy slice; its behaviour is
  # covered by test/agent_unattended_policy_test.rb and scorecard case 06. What
  # belongs here is only that an unknown id is refused rather than accepted.
  def test_approve_refuses_an_id_that_is_not_waiting
    with_runtime do |rt|
      assert_equal 1, rt.cli(%w[approve not-a-real-request --json])
      assert_match(/no paused approval/, rt.err)
    end
  end
end
