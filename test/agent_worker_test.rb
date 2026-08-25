# frozen_string_literal: true

# Regression coverage for the unattended surface: `init`, `queue`, `worker`,
# `status`.
#
# The autonomy scorecard proves the product behaviours; this file guards the
# edges around them — permissions, refusals, signals, idling, concurrency, and
# the authority boundary between a work item and the profile that governs it.

require_relative "test_helper"
require_relative "support/autonomy_case"

# rubocop:disable Metrics/ClassLength -- the unattended surface has one file
#   per concern; the class is the file.
class AgentWorkerTest < Minitest::Test
  include AutonomyCase

  class CompactionCrash < Exception # rubocop:disable Lint/InheritException
  end

  class AdaptiveCompactionModel
    attr_reader :calls

    def initialize(crash: false)
      @crash = crash
      @crashed = false
      @adaptive_calls = 0
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      case stage
      when :adaptive_decide
        @adaptive_calls += 1
        if prompt.include?('large observation')
          JSON.generate(
            'decision' => 'final', 'answer' => 'the file was inspected',
            'evidence_refs' => ['observation:0']
          )
        else
          JSON.generate(
            'decision' => 'action', 'capability_id' => 'read_file',
            'arguments' => {'path' => 'large.txt'}
          )
        end
      when :context_compact
        result = JSON.generate('summary' => 'Retain the large observation for the next decision.')
        if @crash && !@crashed
          @crashed = true
          raise CompactionCrash, 'simulated worker loss during compaction'
        end
        result
      else
        raise "unexpected model stage #{stage.inspect}"
      end
    end
  end

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
      assert_operator completed.first.fetch("duration_ms"), :>=, 0
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

  def test_worker_reopens_the_same_occurrence_after_a_compaction_crash
    with_runtime do |rt|
      File.write(File.join(rt.workspace, "large.txt"), "large observation\n" * 200)
      directory = Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {})
      first_runtime = Tamoz::Agent::WorkerRuntime.open(
        directory,
        model_factory: ->(profile:) { AdaptiveCompactionModel.new(crash: true) },
        lease_ttl: 0.2,
        routing: :adaptive
      )
      first_runtime.checkpoints.enqueue_request(
        thread_id: "compaction-thread", request_id: "compaction-request", operation: :turn,
        payload: {"task" => "Inspect the large file"}, delivery: :queue
      )
      first_worker = Tamoz::Agent::Worker.new(
        runtime: first_runtime,
        session_builder: ->(thread_id) { first_runtime.session_for(thread_id) },
        emitter: ->(_event) {}, once: true
      )

      assert_raises(CompactionCrash) { first_worker.poll_once }
      first_runtime.close

      sleep 0.25
      second_runtime = Tamoz::Agent::WorkerRuntime.open(
        directory,
        model_factory: ->(profile:) { AdaptiveCompactionModel.new },
        lease_ttl: 0.2,
        routing: :adaptive
      )
      second_worker = Tamoz::Agent::Worker.new(
        runtime: second_runtime,
        session_builder: ->(thread_id) { second_runtime.session_for(thread_id) },
        emitter: ->(_event) {}, once: true
      )

      assert second_worker.poll_once
      view = second_runtime.session_for("compaction-thread").view(thread: "compaction-thread")
      assert_equal :completed, view.status
      assert_equal 1, view.state.fetch(:compactions).length
      assert_equal 1, view.effect_receipts.count { |receipt| receipt.fetch("operation") == "tool.read_file" }
      assert_equal 1, view.lifecycle_events.count { |event| event.fetch("event_type") == "terminal" }
      assert second_runtime.checkpoints.fetch_request(
        thread_id: "compaction-thread", request_id: "compaction-request"
      ).terminal?
    ensure
      second_runtime&.close
      first_runtime&.close
    end
  end

  # The idle sleep must never be handed a negative interval. The window is one
  # clock read wide, so a single pass almost always wins it — and a worker
  # polling once a second loses it eventually, dying hours later with an
  # ArgumentError that names nothing about where it came from.
  def test_the_idle_sleep_never_goes_negative_when_the_clock_crosses_the_deadline
    worker = Tamoz::Agent::Worker.new(
      runtime: nil, session_builder: ->(_thread) {}, emitter: ->(_event) {},
      poll_interval: 1.0
    )
    # now() for the deadline, then a reading BEFORE it, then one PAST it: the
    # deadline is crossed in exactly the window between the test and the sleep.
    readings = [0.0, 0.5, 2.0, 2.0, 2.0]
    clock = Object.new
    clock.define_singleton_method(:now) { readings.shift || 2.0 }

    with_monotonic_clock(clock) do
      assert_equal :due, worker.send(:sleep_until_due),
                   "the idle sleep raised instead of finding the deadline passed"
    end
  end

  # Swaps the process clock for a scripted one, and always puts it back.
  def with_monotonic_clock(clock)
    original = Tamoz::Clock.method(:monotonic)
    Tamoz::Clock.define_singleton_method(:monotonic) { clock }
    yield
  ensure
    Tamoz::Clock.define_singleton_method(:monotonic, original)
  end

  # A REAL SIGTERM to a REAL process. The test below calls `stop!` from an
  # ordinary thread, which is not the same thing at all: a signal handler runs
  # in trap context, where `Mutex#synchronize` raises ThreadError. Sending the
  # signal for real is the only way to prove that a supervisor's stop actually
  # cancels the turn instead of killing the process with a backtrace.
  def test_sigterm_stops_the_worker_cleanly_from_a_real_trap_context
    with_runtime do |rt|
      script = <<~RUBY
        require "stringio"
        require "tamoz/agent"
        require "tamoz/agent_cli"
        $stdout.sync = true
        status = Tamoz::Agent::CLI.run(
          ["--runtime-dir", #{rt.dir.inspect}, "worker", "--json"],
          out: $stdout, err: $stderr, input: StringIO.new, env: {}
        )
        exit status
      RUBY
      out_read, out_write = IO.pipe
      err_read, err_write = IO.pipe
      pid = Process.spawn(RbConfig.ruby, *SUBPROCESS_LIB_ARGS, "-e", script, out: out_write, err: err_write)
      out_write.close
      err_write.close

      begin
        started = nil
        Timeout.timeout(30) { started = out_read.gets }
        assert_includes started.to_s, "worker.started", "the child worker never started"

        Process.kill("TERM", pid)
        _pid, status = Timeout.timeout(30) { Process.wait2(pid) }
        stderr = err_read.read

        refute_includes stderr, "ThreadError",
                        "the signal handler ran work that is illegal in trap context"
        refute_includes stderr, "trap context", "SIGTERM raised out of the trap handler"
        assert_equal 0, status.exitstatus, "a supervised stop must exit 0, got: #{stderr}"
      ensure
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
        out_read.close
        err_read.close
      end
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

  def test_experimental_routing_selects_the_v2_worker_graph
    with_runtime do |rt|
      runtime = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) },
        routing: :experimental
      )

      assert_equal '2', runtime.session_for('experimental').definition.version
      assert_includes runtime.session_for('experimental').definition.nodes.keys, :route
    ensure
      runtime&.close
    end
  end

  # A queued request whose claim raises (e.g. the session builder fails at
  # MCP catalog compile) must be failed durably, not re-claimed on every poll.
  # `parked?` ignores queued entries, so an in-memory park alone would hot-loop
  # the worker at the poll interval forever.
  def test_queued_request_whose_claim_raises_is_failed_durably_not_hot_looped
    with_runtime do |rt|
      rt.cli(%W[queue add --task Read\ note.txt --thread stuck], factory: read_only_factory)
      runtime = Tamoz::Agent::WorkerRuntime.open(
        Tamoz::Agent::RuntimeDirectory.resolve(path: rt.dir, env: {}),
        model_factory: ->(profile:) { read_only_factory.call(profile) }
      )
      entry = runtime.checkpoints.pending_threads(limit: 5).first
      assert_equal :queued, entry.fetch(:head_status)

      events = []
      worker = Tamoz::Agent::Worker.new(
        runtime:,
        session_builder: ->(_thread_id) { raise "session build failed" },
        emitter: ->(event) { events << event },
        once: true
      )
      worker.run

      failed = events.select { |event| event["event"] == "request.failed" }
      assert_equal 1, failed.length, "the failed claim must be reported exactly once"
      assert_equal "stuck", failed.first.fetch("thread")

      request = runtime.checkpoints.fetch_request(thread_id: "stuck", request_id: entry.fetch(:head_request_id))
      assert_equal :failed, request.status, "the request must be terminal, not left queued"

      # A second pass must not re-claim the failed request.
      second_events = []
      second = Tamoz::Agent::Worker.new(
        runtime:,
        session_builder: ->(_thread_id) { raise "session build failed" },
        emitter: ->(event) { second_events << event },
        once: true
      )
      second.run
      assert_empty runtime.checkpoints.pending_threads(limit: 5), "the failed request leaves the inbox"
      assert_empty second_events.select { |event| event["event"] == "request.claimed" }
    ensure
      runtime&.close
    end
  end

  # A request queued behind a genuinely paused turn must WAIT, not die: the
  # thread's latest checkpoint is paused, so claiming it today would be stale —
  # but the paused occurrence still owes the thread its settle, and once the
  # human answers, the queued message runs against a terminal checkpoint.
  # Failing it dropped a message the user sent in good faith; closing the
  # paused occurrence out from under the approval stranded the thread forever.
  def test_a_turn_queued_behind_a_paused_turn_waits_then_runs_after_approval
    with_runtime(approval_profile: "unattended") do |rt|
      File.write(File.join(rt.workspace, "note.txt"), "hello\n")
      # First turn pauses for approval (apply_patch is not preauthorized).
      rt.cli(%W[queue add --task Fix\ note.txt --thread t1 --profile trusted], factory: edit_factory)
      rt.cli(%w[worker --once --json], factory: edit_factory)
      paused = rt.events.select { |event| event["event"] == "request.paused" }
      assert_equal 1, paused.length, "the first turn must pause for approval"

      # The second message is admitted while the first waits on the human.
      rt.cli(%W[queue add --task Read\ note.txt --thread t1 --profile trusted], factory: read_only_factory)
      before = rt.events.length
      rt.cli(%w[worker --once --json], factory: edit_factory)

      events = rt.events[before..]
      refute events.any? { |event| event["event"] == "request.failed" },
             "a message that arrives during an approval pause must wait, not fail"
      refute events.any? { |event| event["event"] == "request.claimed" },
             "the waiting message must not be claimed against a paused checkpoint"

      # The human approves the first turn; the SAME occurrence resumes, and the
      # queued message runs once the thread settles.
      approval = rt.pending_approvals.first.fetch("request_id")
      assert_equal 0, rt.cli(%W[approve #{approval} --json]), rt.err
      rt.cli(%w[worker --once --json], factory: read_only_factory)

      if ENV['TAMOZ_DEBUG']
        warn('DIAG ev=' + rt.events.map { |e| [e['event'], e['reason']].compact.join(':') }.inspect)
      end
      completed = rt.events.select { |event| event["event"] == "request.completed" }
      assert_equal 2, completed.length, "both the approved turn and the queued message must complete"
      assert_equal 1, rt.events.count { |event| event["event"] == "request.paused" },
                   "the read-only follow-up must not pause for approval"
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
# rubocop:enable Metrics/ClassLength
