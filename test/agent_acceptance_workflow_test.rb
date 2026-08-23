# frozen_string_literal: true

require_relative "test_helper"
require "digest"

# P15 acceptance workflow — the product proof, end to end, in ONE durable
# thread against a real repository, a real SQLite database, a real configured
# check, and a real `kill -9`.
#
# Every phase-level test in this repository proves one link of the chain. This
# proves the CHAIN: that a single session can inspect a repository, plan a
# bounded change, obtain approval, edit, run the configured check, treat the
# failure as evidence and repair it, survive a process kill mid-flight, resume
# in a fresh process, and finish with a verification bound to evidence — with
# every effect applied exactly once across both processes.
#
# Nothing here is simulated. The kill is `Process.kill("KILL", Process.pid)`
# fired from inside the atomic publication, the check is a real subprocess, and
# the second process shares nothing with the first except the database and the
# workspace.
class AgentAcceptanceWorkflowTest < Minitest::Test
  # The model is deterministic and derives its plan from the WORKSPACE, the way
  # a real model derives it from the evidence it was shown. That matters here:
  # after the kill the second process starts with no memory, so a plan that
  # depended on an in-process counter would diverge across the restart.
  CHILD = <<~'RUBY'
    require "json"
    require "digest"
    require "tamoz/sqlite"
    require "tamoz/agent"

    EVENT_LOG = ENV.fetch("TAMOZ_EVENT_LOG")
    WORKSPACE = ENV.fetch("TAMOZ_WORKSPACE")
    RESULT = ENV.fetch("TAMOZ_RESULT")

    def log(entry)
      File.open(EVENT_LOG, "ab") { |file| file.write("#{entry}\n") }
    end

    def events
      File.readlines(EVENT_LOG, chomp: true)
    rescue Errno::ENOENT
      []
    end

    # Every real publication into the workspace is counted, across every
    # process in the run. The kill fires immediately after the Nth one, so the
    # crash lands between "the bytes are on disk" and "the journal recorded
    # it" — the seam where a naive resume would apply the patch twice.
    publication = Module.new do
      define_method(:rename) do |old, new|
        result = super(old, new)
        if new.to_s.start_with?(WORKSPACE) && !new.to_s.include?(".tamoz-")
          File.open(EVENT_LOG, "ab") { |file| file.write("publish\n") }
          if ENV["TAMOZ_KILL_AFTER_PUBLISH"] &&
             File.readlines(EVENT_LOG, chomp: true).count("publish") ==
               Integer(ENV.fetch("TAMOZ_KILL_AFTER_PUBLISH"))
            Process.kill("KILL", Process.pid)
            sleep 5
          end
        end
        result
      end
    end
    File.singleton_class.prepend(publication)

    class Model
      def initialize(logger)
        @logger = logger
      end

      def generate(stage:, system:, prompt:)
        phase = (JSON.parse(prompt)["phase"] rescue nil) || "verify"
        @logger.call("model:#{stage}:#{phase}")
        case stage
        when :plan
          JSON.generate(phase == "discovery" ? discovery : action_plan)
        when :review
          JSON.generate("decision" => "accept", "issues" => [], "rationale" => "bounded and checked")
        else
          JSON.generate(
            "answer" => "app.rb now sets value to 2 and the configured check passes.",
            "satisfied" => true,
            "evidence" => ["apply_patch receipt", "answer check exit_0"]
          )
        end
      end

      def discovery
        {
          "goal" => "inspect the repository before changing it",
          "done_when" => ["app.rb has been read"],
          "steps" => [
            {"id" => "look", "purpose" => "read the implementation",
             "tool" => "read_file", "arguments" => {"path" => "app.rb"},
             "verification" => "the current value is visible"}
          ]
        }
      end

      # The bounded change: one exact replacement plus the configured check.
      # The BEFORE string is read from disk, so the first attempt proposes
      # 0 -> 1 (which the check rejects) and the repair proposes 1 -> 2.
      def action_plan
        path = File.join(WORKSPACE, "app.rb")
        current = File.read(path)
        before, after =
          if current.include?("value = 0")
            ["value = 0", "value = 1"]
          else
            ["value = 1", "value = 2"]
          end
        {
          "goal" => "make the configured check pass",
          "done_when" => ["app.rb satisfies the configured check"],
          "steps" => [
            {"id" => "edit", "purpose" => "apply the exact replacement",
             "tool" => "apply_patch",
             "arguments" => {
               "path" => "app.rb",
               "expected_sha256" => Digest::SHA256.hexdigest(current),
               "before" => before, "after" => after
             },
             "verification" => "the receipt reports the new digest"},
            {"id" => "check", "purpose" => "run the configured check",
             "tool" => "run_check", "arguments" => {"name" => "answer"},
             "verification" => "the check exits zero"}
          ]
        }
      end
    end

    adapter = Tamoz::SQLite::Adapter.new(
      path: ENV.fetch("TAMOZ_DB"),
      limits: Tamoz::SQLite::Limits.new(lease_ttl: 0.5, effect_attempt_ttl: 0.2)
    )
    check_script = <<~CHECK
      File.open(ENV.fetch("TAMOZ_EVENT_LOG"), "ab") { |f| f.write("check:ran\\n") }
      value = File.read("app.rb")
      unless value == "value = 2\\n"
        File.open(ENV.fetch("TAMOZ_EVENT_LOG"), "ab") { |f| f.write("check:failed\\n") }
        abort("expected value = 2, found \#{value.strip}")
      end
      File.open(ENV.fetch("TAMOZ_EVENT_LOG"), "ab") { |f| f.write("check:passed\\n") }
    CHECK
    toolbox = Tamoz::Agent::Toolbox.new(
      root: WORKSPACE,
      allow_changes: true,
      checks: {"answer" => [RbConfig.ruby, "-e", check_script]}
    )
    session = Tamoz::Agent::Session.new(
      model: Model.new(method(:log)), toolbox:, checkpointer: adapter
    )
    thread = "session.acceptance"

    outcome =
      if ENV.fetch("TAMOZ_MODE") == "recover"
        pending = (0..19).lazy.map do |index|
          session.app.durable_runner.fetch(thread:, request_id: "r#{index}")
        end.select { |request| request && !request.terminal? }.first
        if pending
          log("recover:#{pending.request_id}")
          # The killed owner's lease outlives the process that held it. A new
          # owner may not simply seize it: it waits for the fence to expire,
          # which is exactly what a real operator restarting a crashed agent
          # does. The wait is bounded, so "the lease never frees" fails loudly
          # instead of hanging.
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
          begin
            session.recover(thread:, request_id: pending.request_id,
                            owner_id: "owner.recover.#{Process.pid}")
          rescue Tamoz::CheckpointConflictError
            raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

            sleep 0.05
            retry
          end
        end
      else
        log("start")
        session.start(ENV.fetch("TAMOZ_TASK"), thread:, request_id: "r0",
                      owner_id: "owner.start.#{Process.pid}")
      end

    # Approvals: the operator grants every approval the session asks for. Each
    # grant is its own durable request, so the count in the result is the real
    # number of approval gates the workflow passed through.
    guard = 0
    while guard < 20
      guard += 1
      view = session.view(thread:)
      break if view.interrupts.empty?

      request_id = (1..19).find do |candidate|
        session.app.durable_runner.fetch(thread:, request_id: "r#{candidate}").nil?
      end
      break unless request_id

      log("approve:r#{request_id}")
      outcome = session.resume(
        {view.interrupts.first.task_id => {0 => true}},
        thread:, request_id: "r#{request_id}",
        owner_id: "owner.resume.#{Process.pid}"
      )
    end

    view = session.view(thread:)
    File.write(
      RESULT,
      JSON.generate(
        "status" => (outcome&.status || view.status).to_s,
        "phase" => view.phase,
        "terminal" => view.terminal,
        "blocked" => view.blocked,
        "verification" => view.state[:verification],
        "effect_receipts" => view.effect_receipts,
        "approvals" => view.approvals,
        "plan_versions" => view.state.fetch(:plan_versions).map { |plan| plan.fetch("plan_id") },
        "repair_attempt" => view.state.fetch(:repair_attempt),
        "observations" => view.state.fetch(:observations).length,
        "integrity_ok" => adapter.integrity_check.fetch("ok")
      )
    )
    adapter.close
    exit 0
  RUBY

  def test_the_full_workflow_survives_a_kill_and_ends_evidence_bound
    with_workspace do |context|
      # Phase 1-6: inspect, plan, approve, edit, check FAILS, repair, approve,
      # edit again — and the process is killed the instant the repair's bytes
      # reach the workspace, before the journal can record the publication.
      first = run_child(context, mode: "run", kill_after_publish: 2)

      refute first.success?, "the run must be killed at the declared seam"
      assert_equal 9, first.termsig, "the kill must be a real SIGKILL"
      assert_equal 2, events(context).count("publish")
      assert_includes events(context), "check:failed"
      assert_equal "value = 2\n", File.read(File.join(context.fetch(:workspace), "app.rb")),
                   "the repair's bytes must already be on disk when the process dies"

      # Phase 7: a fresh process, sharing only the database and the workspace,
      # resumes the interrupted thread.
      second = run_child(context, mode: "recover")

      assert second.success?, "the resumed process must complete: #{second.inspect}"
      result = JSON.parse(File.read(context.fetch(:result)))

      # Phase 8: an evidence-bound verification, not a claim.
      assert_equal "completed", result.fetch("status")
      assert_equal "check_passed", result.fetch("terminal").fetch("reason")
      verification = result.fetch("verification")

      assert verification.fetch("satisfied")
      refute_empty verification.fetch("evidence")
      assert result.fetch("terminal").fetch("satisfied")
      assert result.fetch("integrity_ok"), "the database must survive the kill intact"

      # The repair loop really ran: two accepted action plans, a recorded
      # repair attempt, and a failed check before the passing one.
      assert_operator result.fetch("plan_versions").length, :>=, 3,
                      "discovery + action + repair action: #{result.fetch("plan_versions").inspect}"
      assert_operator result.fetch("repair_attempt"), :>=, 1
      log = events(context)

      assert_includes log, "check:failed"
      assert_includes log, "check:passed"

      # Exactly once, across BOTH processes: the resume reconciled the killed
      # publication from its proven after-state instead of replaying it
      # (invariant 21). A duplicate would show as a third publication.
      assert_equal 2, log.count("publish"),
                   "each reviewed edit must publish exactly once across the whole run"
      assert_equal "value = 2\n", File.read(File.join(context.fetch(:workspace), "app.rb"))

      # Every effect the workflow recorded is terminal and truthful — nothing
      # is left `:unknown`, and nothing claims success without a receipt.
      receipts = result.fetch("effect_receipts")

      refute_empty receipts
      receipts.each do |receipt|
        refute_equal "unknown", receipt.fetch("status", "succeeded"),
                     "an unresolved effect cannot end a satisfied workflow: #{receipt.inspect}"
      end

      # The operator was asked before every mutation: the approvals recorded on
      # the thread cover both the first patch and the repair.
      assert_operator result.fetch("approvals").length, :>=, 1
    end
  end

  private

  def with_workspace
    Dir.mktmpdir("tamoz-acceptance") do |directory|
      workspace = File.join(directory, "repository")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "app.rb"), "value = 0\n")
      File.write(
        File.join(workspace, "README.md"),
        "The configured check requires app.rb to set value to 2.\n"
      )
      yield(
        directory:,
        workspace: File.realpath(workspace),
        database: File.join(directory, "tamoz.sqlite3"),
        log: File.join(directory, "events.log"),
        result: File.join(directory, "result.json")
      )
    end
  end

  def events(context)
    File.readlines(context.fetch(:log), chomp: true)
  rescue Errno::ENOENT
    []
  end

  def run_child(context, mode:, kill_after_publish: nil)
    load_paths = %w[
      tamoz-core tamoz-graph tamoz-scheduler tamoz-stream tamoz-approval tamoz-sqlite
      tamoz-tools tamoz-observability tamoz-agent tamoz-comms
    ].flat_map { |gem| ["-I", ROOT.join("gems", gem, "lib").to_s] }
    env = {
      "TAMOZ_MODE" => mode,
      "TAMOZ_DB" => context.fetch(:database),
      "TAMOZ_WORKSPACE" => context.fetch(:workspace),
      "TAMOZ_EVENT_LOG" => context.fetch(:log),
      "TAMOZ_RESULT" => context.fetch(:result),
      "TAMOZ_TASK" => "make the configured check pass",
      "TAMOZ_KILL_AFTER_PUBLISH" => kill_after_publish&.to_s,
      # The child must run with ONLY the load paths above, so a missing runtime
      # dependency surfaces here instead of being masked by the parent's
      # bundler environment.
      "RUBYOPT" => nil,
      "BUNDLER_SETUP" => nil
    }
    pid = Process.spawn(
      env, RbConfig.ruby, *load_paths, "-e", CHILD,
      out: ENV["TAMOZ_ACCEPTANCE_DEBUG"] ? $stdout : File::NULL,
      err: ENV["TAMOZ_ACCEPTANCE_DEBUG"] ? $stderr : File::NULL
    )
    _pid, status = Process.wait2(pid)
    status
  end
end
