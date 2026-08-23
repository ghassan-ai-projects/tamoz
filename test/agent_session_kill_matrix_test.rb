# frozen_string_literal: true

require_relative "test_helper"

# P6-E: a real repository repair survives `kill -9` at every declared seam.
#
# Every kill in this file is a real `Process.kill("KILL", ...)` delivered to a real
# process. Nothing here substitutes an exception, a stub, or a simulated failure.
#
# Seam selection is semantic rather than ordinal: the child appends an ordered event
# log (model calls, publications, check runs, resumes, and every fault-injector
# callback), and the kill fires at the first matching storage seam that occurs after a
# named marker, optionally skipping a declared number of matches. That keeps each row
# readable and stable against unrelated changes in super-step counts.
class AgentSessionKillMatrixTest < Minitest::Test
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

    # Real SIGKILL of this process, at a real seam.
    def die!
      Process.kill("KILL", Process.pid)
      sleep 5
    end

    KILL_MARKER = ENV["TAMOZ_KILL_MARKER"]
    KILL_POINT = ENV["TAMOZ_KILL_POINT"]
    KILL_OPERATION = ENV["TAMOZ_KILL_OPERATION"]
    KILL_SKIP = ENV.fetch("TAMOZ_KILL_SKIP", "0").to_i
    KILL_PUBLISH = ENV["TAMOZ_KILL_PUBLISH"]

    seen_after_marker = 0
    fired = false
    fault = lambda do |point, metadata|
      operation = metadata.fetch("operation")
      log("fault:#{point}:#{operation}") if ENV["TAMOZ_TRACE"] == "1"
      next if fired || KILL_POINT.nil?
      next unless point.to_s == KILL_POINT && operation == KILL_OPERATION
      next if KILL_MARKER && !events.include?(KILL_MARKER)

      if seen_after_marker < KILL_SKIP
        seen_after_marker += 1
        next
      end
      fired = true
      die!
    end

    # Publication instrumentation. Each line is one real filesystem publication, so the
    # log counts how many times an effect actually reached the workspace across every
    # process in the run.
    publication = Module.new do
      define_method(:rename) do |old, new|
        result = super(old, new)
        if new.to_s.start_with?(WORKSPACE) && !new.to_s.include?(".tamoz-")
          File.open(EVENT_LOG, "ab") { |file| file.write("publish:apply_patch\n") }
          if ENV["TAMOZ_KILL_PUBLISH"] == "after"
            Process.kill("KILL", Process.pid)
            sleep 5
          end
        end
        result
      end

      define_method(:link) do |old, new|
        if new.to_s.start_with?(WORKSPACE) && ENV["TAMOZ_KILL_PUBLISH"] == "before"
          Process.kill("KILL", Process.pid)
          sleep 5
        end
        result = super(old, new)
        if new.to_s.start_with?(WORKSPACE)
          File.open(EVENT_LOG, "ab") { |file| file.write("publish:create_file\n") }
          if ENV["TAMOZ_KILL_PUBLISH"] == "after"
            Process.kill("KILL", Process.pid)
            sleep 5
          end
        end
        result
      end
    end
    File.singleton_class.prepend(publication)

    class Model
      DISCOVERY = {
        "goal" => "read the current value",
        "done_when" => ["app.rb has been read"],
        "steps" => [
          {
            "id" => "look",
            "purpose" => "read the file",
            "tool" => "read_file",
            "arguments" => {"path" => "app.rb"},
            "verification" => "the digest is present"
          }
        ]
      }.freeze

      def initialize(digest, logger)
        @digest = digest
        @logger = logger
      end

      def generate(stage:, system:, prompt:)
        phase = (JSON.parse(prompt)["phase"] rescue nil) || "verify"
        @logger.call("model:#{stage}:#{phase}")
        case stage
        when :plan
          JSON.generate(phase == "discovery" ? DISCOVERY : action_plan)
        when :review
          JSON.generate("decision" => "accept", "issues" => [], "rationale" => "sound")
        else
          JSON.generate(
            "answer" => "value is 2",
            "satisfied" => true,
            "evidence" => ["app.rb"]
          )
        end
      end

      def action_plan
        mutation =
          if ENV.fetch("TAMOZ_TOOL", "apply_patch") == "create_file"
            {
              "id" => "edit",
              "purpose" => "create the missing file",
              "tool" => "create_file",
              "arguments" => {
                "path" => "greeting.txt",
                "content" => "hello\n",
                "expected_sha256" => Digest::SHA256.hexdigest("hello\n"),
                "mode" => "0644"
              },
              "verification" => "the receipt reports the published digest"
            }
          else
            arguments = {
              "path" => "app.rb",
              "before" => "value = 1",
              "after" => "value = 2"
            }
            # D-8 Fix A (T7): with TAMOZ_ABSENT_DIGEST=1 the patch step carries no
            # digest — the shape a real model produces before a read executes. The
            # session resolves it from observation at step_gate.
            arguments["expected_sha256"] = @digest unless ENV["TAMOZ_ABSENT_DIGEST"] == "1"
            {
              "id" => "edit",
              "purpose" => "apply the exact replacement",
              "tool" => "apply_patch",
              "arguments" => arguments,
              "verification" => "the receipt reports the new digest"
            }
          end
        {
          "goal" => "make the configured check pass",
          "done_when" => ["the workspace satisfies the check"],
          "steps" => [
            mutation,
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
    end

    adapter = Tamoz::SQLite::Adapter.new(
      path: ENV.fetch("TAMOZ_DB"),
      limits: Tamoz::SQLite::Limits.new(
        lease_ttl: 0.5,
        effect_attempt_ttl: 0.2
      ),
      fault_injector: fault
    )
    check_script = <<~CHECK
      File.open(ENV.fetch("TAMOZ_EVENT_LOG"), "ab") { |f| f.write("check:ran\\n") }
      if ENV["TAMOZ_KILL_IN_CHECK"] == "1"
        Process.kill("KILL", Process.ppid)
        sleep 0.3
        exit 1
      end
      if ENV.fetch("TAMOZ_TOOL", "apply_patch") == "create_file"
        abort("wrong") unless File.read("greeting.txt") == "hello\\n"
      else
        abort("wrong") unless File.read("app.rb") == "value = 2\\n"
      end
    CHECK
    check_command = [RbConfig.ruby, "-e", check_script]
    toolbox = Tamoz::Agent::Toolbox.new(
      root: WORKSPACE,
      allow_changes: true,
      checks: {"answer" => check_command}
    )
    session = Tamoz::Agent::Session.new(
      model: Model.new(ENV.fetch("TAMOZ_BEFORE_DIGEST"), method(:log)),
      toolbox:,
      checkpointer: adapter,
      model_call_safety: ENV.fetch("TAMOZ_MODEL_SAFETY", "idempotent").to_sym,
      # The kill matrix calibrates its seams around an approval BEFORE every
      # mutation: under the review profile workspace_write asks, so the
      # apply_patch/create_file approval checkpoint exists again (policy data —
      # the implement profile would auto-allow the patch and shift every seam).
      approval_engine: Tamoz::Agent.build_approval_engine(profile_name: "review")
    )
    thread = "session.kill"

    outcome =
      if ENV.fetch("TAMOZ_MODE") == "recover"
        pending = (0..9).lazy.map do |index|
          session.app.durable_runner.fetch(thread:, request_id: "r#{index}")
        end.select { |request| request && !request.terminal? }.first
        if pending
          log("recover:#{pending.request_id}")
          session.recover(
            thread:,
            request_id: pending.request_id,
            owner_id: "owner.recover.#{Process.pid}"
          )
        else
          log("recover:none")
          session.view(thread:)
          nil
        end
      else
        log("start")
        session.start(
          ENV.fetch("TAMOZ_TASK"),
          thread:,
          request_id: "r0",
          owner_id: "owner.start.#{Process.pid}"
        )
      end

    guard = 0
    while guard < 8
      guard += 1
      view = session.view(thread:)
      if (blocked = view.blocked)
        # The operator surface (cli.rb resolve_effect): attest the truth by
        # re-running the configured check, then record the verdict on the
        # effect journal. Only TOOL effects are attestable this way; a blocked
        # provider call stays blocked. The turn itself was finalized around the
        # unknown outcome, so a follow-up continue is expected to report the
        # stale request rather than invent new work.
        if blocked.fetch("operation").start_with?("tool.")
          log("attest:#{blocked.fetch('effect_key')}")
          ok = system(*check_command, chdir: WORKSPACE)
          log("resolve:#{blocked.fetch('effect_key')}")
          session.resolve_effect(
            thread:,
            effect_key: blocked.fetch("effect_key"),
            status: ok ? :succeeded : :failed,
            actor: "kill-matrix-child",
            evidence: {"how" => "re-ran the configured check"},
            owner_id: "owner.resolve.#{Process.pid}"
          )
          log("resolved:#{blocked.fetch('effect_key')}:#{ok ? 'succeeded' : 'failed'}")
          request_id = (1..9).find do |candidate|
            session.app.durable_runner.fetch(thread:, request_id: "r#{candidate}").nil?
          end
          break unless request_id

          log("continue:r#{request_id}")
          begin
            session.continue(
              thread:,
              request_id: "r#{request_id}",
              owner_id: "owner.continue.#{Process.pid}"
            )
          rescue Tamoz::Graph::StaleRequestError
            log("continue:finalized")
          end
          # The verdict is journaled; the finalized turn stays as recorded.
          break
        end
        log("blocked-unresolvable:#{blocked.fetch('operation')}")
      end
      break if view.interrupts.empty?

      request_id = (1..9).find do |candidate|
        session.app.durable_runner.fetch(thread:, request_id: "r#{candidate}").nil?
      end
      break unless request_id

      log("resume:r#{request_id}")
      outcome = session.resume(
        {view.interrupts.first.task_id => {0 => true}},
        thread:,
        request_id: "r#{request_id}",
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
        "accepted_plan_digest" => view.accepted_plan && view.accepted_plan.fetch("plan_digest"),
        "provider_ambiguity" => view.provider_ambiguity,
        "effect_receipts" => view.effect_receipts,
        "approvals" => view.approvals,
        "execution_ids" => session.app.history(thread:, limit: 200).map(&:execution_id).uniq,
        "integrity_ok" => adapter.integrity_check.fetch("ok")
      )
    )
    adapter.close
    exit 0
  RUBY

  SEAMS = {
    "K1.before_plan_acceptance" => {
      marker: "model:review:action",
      point: "before_commit",
      operation: "checkpoint.commit"
    },
    "K2.after_plan_acceptance" => {
      marker: "model:review:action",
      point: "after_commit",
      operation: "checkpoint.commit"
    },
    "K3.after_model_receipt_commit" => {
      marker: "model:review:action",
      point: "after_commit",
      operation: "effect.complete"
    },
    "K4.after_provider_response_before_receipt" => {
      marker: "model:plan:action",
      point: "before_commit",
      operation: "effect.complete"
    },
    "K5a.before_approval_checkpoint" => {
      marker: "model:review:action",
      point: "before_commit",
      operation: "checkpoint.commit",
      skip: 1
    },
    "K5b.after_approval_checkpoint" => {
      marker: "model:review:action",
      point: "after_commit",
      operation: "checkpoint.commit",
      skip: 1
    },
    # D-8 Fix A / T7: the checkpoint that commits the APPROVAL RECORD (and the
    # resolved effect intent), i.e. the third checkpoint.commit after the action
    # review. A kill here leaves the committed intent in state, so a resumed
    # dispatch re-verifies it rather than re-resolving (probe 9).
    "D8.after_approval_recorded" => {
      marker: "model:review:action",
      point: "after_commit",
      operation: "checkpoint.commit",
      skip: 2
    },
    "K6.after_effect_prepare" => {
      marker: "resume:r1",
      point: "after_commit",
      operation: "effect.prepare"
    },
    "K7.after_effect_start_before_publication" => {
      marker: "resume:r1",
      point: "after_commit",
      operation: "effect.start"
    },
    "K8.after_filesystem_publication" => {
      publish: "after"
    },
    "K10.after_check_receipt_commit" => {
      marker: "check:ran",
      point: "after_commit",
      operation: "effect.complete"
    },
    "K11.before_verification_checkpoint" => {
      marker: "model:verify:verify",
      point: "before_commit",
      operation: "checkpoint.commit"
    },
    "K12.before_terminal_commit" => {
      marker: "model:verify:verify",
      point: "before_commit",
      operation: "checkpoint.commit",
      skip: 1
    },
    "K13.after_terminal_commit" => {
      marker: "model:verify:verify",
      point: "after_commit",
      operation: "checkpoint.commit",
      skip: 1
    }
  }.freeze

  def test_every_declared_seam_survives_a_real_kill_and_applies_the_effect_once
    failures = []
    SEAMS.each do |name, seam|
      with_scenario do |context|
        status = run_child(context, mode: "run", seam:)
        killed = status.signaled? && status.termsig == Signal.list.fetch("KILL")
        unless killed
          failures << "#{name}: child was not killed (#{status.inspect})"
          next
        end

        sleep 0.35
        recovery = run_child(context, mode: "recover", seam: {})
        unless recovery.success?
          failures << "#{name}: recovery child failed (#{recovery.inspect})"
          next
        end

        result = JSON.parse(File.read(context.fetch(:result)))
        events = File.readlines(context.fetch(:log), chomp: true)
        problems = verify_recovery(name, result, events, context)
        failures.concat(problems)
      end
    end

    assert_empty failures, failures.join("\n")
  end

  def test_a_kill_during_a_check_pauses_the_session_and_never_repeats_the_command
    with_scenario do |context|
      status = run_child(
        context,
        mode: "run",
        seam: {},
        environment: {"TAMOZ_KILL_IN_CHECK" => "1"}
      )

      assert status.signaled?, "child was not killed: #{status.inspect}"
      assert_equal Signal.list.fetch("KILL"), status.termsig

      sleep 0.35
      recovery = run_child(context, mode: "recover", seam: {})
      assert recovery.success?, "recovery child failed"

      result = JSON.parse(File.read(context.fetch(:result)))
      events = File.readlines(context.fetch(:log), chomp: true)

      # The FRAMEWORK never repeats the command: the only second execution is the
      # operator's attestation (the re-run between the attest and resolve marks).
      # The turn stays finalized around the unknown outcome — the operator's
      # verdict is journaled, not silently converted into progress.
      framework_runs = events.take_while { |entry| !entry.start_with?("attest:") }
                             .count("check:ran")
      assert_equal 1, framework_runs,
                   "an unsafe check whose outcome is unknown must never be repeated by the framework"
      assert_equal 2, events.count("check:ran"), "exactly one operator attestation may re-run it"
      assert_equal 1, events.count("publish:apply_patch"),
                   "the filesystem effect must have been applied exactly once"
      assert_equal ["continue:finalized"], events.grep(/^continue:/),
                   "a resolved block must not be continued into invented work"
      assert(events.any? { |entry| entry.start_with?("resolved:") && entry.end_with?(":succeeded") },
             "the operator verdict must be journaled")
      assert_equal "blocked", result.fetch("status")
      assert_equal "effect_unknown", result.fetch("terminal").fetch("reason")
      assert_equal "tool.run_check", result.fetch("terminal").fetch("blocked").fetch("operation")
      assert result.fetch("integrity_ok")
      assert_equal 1, result.fetch("execution_ids").length
    end
  end

  # P6-C for the second real filesystem effect: create_file is no-clobber, so a blind
  # retry after an ambiguous crash would report EEXIST. Reconciliation from the
  # checkpointed intent must complete from a proven after-state and execute only from
  # a proven before-state.
  def test_create_file_publication_kills_reconcile_and_publish_exactly_once
    {"after" => 1, "before" => 1}.each do |when_to_kill, expected_publications|
      with_scenario do |context|
        environment = {"TAMOZ_TOOL" => "create_file"}
        status = run_child(
          context,
          mode: "run",
          seam: {publish: when_to_kill},
          environment:
        )

        assert status.signaled?, "#{when_to_kill}: child was not killed"
        assert_equal Signal.list.fetch("KILL"), status.termsig

        sleep 0.35
        recovery = run_child(context, mode: "recover", seam: {}, environment:)
        assert recovery.success?, "#{when_to_kill}: recovery child failed"

        events = File.readlines(context.fetch(:log), chomp: true)
        result = JSON.parse(File.read(context.fetch(:result)))
        target = File.join(context.fetch(:workspace), "greeting.txt")

        assert_equal "completed", result.fetch("status"), when_to_kill
        assert_equal "hello\n", File.read(target), when_to_kill
        assert_equal 0o644, File.stat(target).mode & 0o777, when_to_kill
        assert_equal expected_publications, events.count("publish:create_file"),
                     "#{when_to_kill}: create_file must publish exactly once"
        assert_equal 1, result.fetch("execution_ids").length, when_to_kill
        assert result.fetch("integrity_ok"), when_to_kill
        assert_no_public_partial(context, %w[app.rb greeting.txt], when_to_kill)
      end
    end
  end

  # D-8 Fix A / T7 (review probe 9): an absent-digest plan killed between approval
  # and dispatch re-verifies the COMMITTED intent on resume. The workspace is
  # mutated while the child is dead; the resumed dispatch must stop (the patch is
  # never applied to the mutated bytes) instead of silently re-binding.
  def test_absent_digest_patch_killed_between_approval_and_dispatch_rebinds_to_committed_intent
    with_scenario do |context|
      environment = {"TAMOZ_ABSENT_DIGEST" => "1"}
      status = run_child(
        context,
        mode: "run",
        seam: SEAMS.fetch("D8.after_approval_recorded"),
        environment:
      )
      assert status.signaled?, "child was not killed: #{status.inspect}"
      assert_equal Signal.list.fetch("KILL"), status.termsig

      mutated = "value = 99\n"
      File.write(File.join(context.fetch(:workspace), "app.rb"), mutated)
      sleep 0.35
      recovery = run_child(context, mode: "recover", seam: {}, environment:)
      assert recovery.success?, "recovery child failed: #{recovery.inspect}"

      result = JSON.parse(File.read(context.fetch(:result)))
      assert_equal "failed", result.fetch("status"),
                   "the resumed dispatch must stop on the changed workspace"
      assert_equal mutated, File.read(File.join(context.fetch(:workspace), "app.rb")),
                   "the patch must never apply to the mutated bytes"
      events = File.readlines(context.fetch(:log), chomp: true)
      assert_equal 0, events.count("publish:apply_patch"),
                   "no filesystem publication may reach the workspace"
      assert result.fetch("integrity_ok")
    end
  end

  def test_an_unsafe_model_call_pauses_instead_of_repeating_the_provider_call
    with_scenario do |context|
      seam = SEAMS.fetch("K4.after_provider_response_before_receipt")
      status = run_child(
        context,
        mode: "run",
        seam:,
        environment: {"TAMOZ_MODEL_SAFETY" => "unsafe"}
      )
      assert status.signaled?

      before = File.readlines(context.fetch(:log), chomp: true)
                   .count { |entry| entry.start_with?("model:") }
      sleep 0.35
      recovery = run_child(
        context,
        mode: "recover",
        seam: {},
        environment: {"TAMOZ_MODEL_SAFETY" => "unsafe"}
      )
      assert recovery.success?

      events = File.readlines(context.fetch(:log), chomp: true)
      after = events.count { |entry| entry.start_with?("model:") }
      result = JSON.parse(File.read(context.fetch(:result)))

      assert_equal before, after,
                   "an unsafe provider call whose outcome is unknown must not be repeated"
      assert_equal "blocked", result.fetch("status")
      assert_equal 0, result.fetch("provider_ambiguity")
      assert_equal "value = 1\n", File.read(File.join(context.fetch(:workspace), "app.rb"))
    end
  end

  def test_the_idempotent_model_default_repeats_at_most_one_call_and_counts_it
    with_scenario do |context|
      seam = SEAMS.fetch("K4.after_provider_response_before_receipt")
      status = run_child(context, mode: "run", seam:)
      assert status.signaled?

      baseline = reference_model_calls
      sleep 0.35
      assert run_child(context, mode: "recover", seam: {}).success?

      events = File.readlines(context.fetch(:log), chomp: true)
      result = JSON.parse(File.read(context.fetch(:result)))
      repeated = events.count { |entry| entry.start_with?("model:") } - baseline

      assert_equal 1, repeated, "exactly one ambiguous provider call may be repeated"
      assert_equal 1, result.fetch("provider_ambiguity"),
                   "the repeat must be counted and surfaced"
      assert_equal "completed", result.fetch("status")
    end
  end

  private

  def verify_recovery(name, result, events, context)
    problems = []
    workspace = context.fetch(:workspace)
    target = File.join(workspace, "app.rb")
    publications = events.count("publish:apply_patch")

    problems << "#{name}: expected completion, got #{result.fetch("status")}" unless
      result.fetch("status") == "completed"
    problems << "#{name}: file content is #{File.read(target).inspect}" unless
      File.read(target) == "value = 2\n"
    problems << "#{name}: filesystem effect applied #{publications} times" unless
      publications == 1
    problems << "#{name}: #{result.fetch("execution_ids").length} execution ids" unless
      result.fetch("execution_ids").length == 1
    problems << "#{name}: integrity check failed" unless result.fetch("integrity_ok")
    problems << "#{name}: blocked #{result.fetch("blocked").inspect}" if result.fetch("blocked")

    accepted = result.fetch("accepted_plan_digest")
    expected = context.fetch(:reference_plan_digest)
    problems << "#{name}: resumed a different plan (#{accepted} != #{expected})" unless
      accepted == expected

    approvals = result.fetch("approvals")
    problems << "#{name}: #{approvals.length} approvals" unless approvals.length == 2
    unless %w[apply_patch run_check].all? do |tool|
      approvals.any? { |record| record.fetch("tool") == tool && record.fetch("decision") == "approve" }
    end
      problems << "#{name}: a mutation or check approval was not granted"
    end

    receipts = result.fetch("effect_receipts").map { |record| record.fetch("operation") }
    problems << "#{name}: missing apply_patch receipt" unless
      receipts.count("tool.apply_patch") == 1
    problems << "#{name}: missing run_check receipt" unless
      receipts.count("tool.run_check") == 1

    surviving = Dir.children(workspace) - %w[app.rb]
    unexpected = surviving.reject { |entry| entry.start_with?(".tamoz-") }
    problems << "#{name}: unexpected workspace entries: #{unexpected.inspect}" unless
      unexpected.empty?
    problems
  end

  # A killed process can orphan its *private* temporary file: `atomic_replace` and
  # `atomic_create` publish by rename/link and only unlink the temporary name
  # afterwards. P5 guarantees no public partial file and no overwrite, and that is
  # what is asserted here.
  #
  # P15-C closed the reclamation half: `Toolbox#reap_stale_staging` sweeps stale
  # `.tamoz-*.tmp` files at action-capable construction. It deliberately does NOT
  # fire here — the orphans these kills produce are seconds old, and the sweep's
  # 60-second staleness floor exists so a sibling session mid-publication is never
  # disturbed. The orphan is therefore expected to survive THIS assertion and to
  # be reclaimed by the next action-capable session that starts later, which
  # `test/toolbox_staging_reaper_test.rb` proves directly.
  def assert_no_public_partial(context, expected, label)
    workspace = context.fetch(:workspace)
    surviving = Dir.children(workspace) - expected
    unexpected = surviving.reject { |entry| entry.start_with?(".tamoz-") }

    assert_empty unexpected, "#{label}: unexpected public workspace entries"
    orphans = surviving.grep(/\A\.tamoz-/)
    orphans.each do |orphan|
      path = File.join(workspace, orphan)
      assert File.file?(path), "#{label}: orphan #{orphan} is not a regular file"
      refute_includes expected, orphan, "#{label}: an orphan took a public name"
      # Whatever survives must be reclaimable by the sweep once it is stale:
      # an orphan the reaper's own pattern cannot match would be permanent.
      assert_match Tamoz::Tools::Toolbox::STAGING_PATTERN, orphan,
                   "#{label}: orphan #{orphan} is unreclaimable by the P15-C sweep"
    end
    # …and the sweep really does reclaim them once they age past the floor.
    unless orphans.empty?
      aged = Time.now - (Tamoz::Tools::Toolbox::STAGING_STALE_SECONDS + 60)
      orphans.each do |orphan|
        File.utime(aged, aged, File.join(workspace, orphan))
      end
      reaped = Tamoz::Tools::Toolbox.new(root: workspace, allow_changes: true).reaped_staging

      assert_equal orphans.sort, reaped.sort,
                   "#{label}: the sweep must reclaim every orphan this kill left"
    end
  end

  def with_scenario
    Dir.mktmpdir("tamoz-kill-matrix") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      File.write(File.join(workspace, "app.rb"), "value = 1\n")
      context = {
        directory:,
        workspace: File.realpath(workspace),
        database: File.join(directory, "tamoz.sqlite3"),
        log: File.join(directory, "events.log"),
        result: File.join(directory, "result.json"),
        digest: Digest::SHA256.hexdigest("value = 1\n"),
        reference_plan_digest: reference_plan_digest
      }
      yield context
    end
  end

  def reference_plan_digest
    reference.fetch(:plan_digest)
  end

  def reference_model_calls
    reference.fetch(:model_calls)
  end

  # A clean, unkilled run: its accepted action-plan digest is the plan every recovered
  # run must resume, and its model-call count is the baseline against which an
  # ambiguous provider repeat is measured.
  def reference
    @reference ||= begin
      Dir.mktmpdir("tamoz-kill-reference") do |directory|
        workspace = File.join(directory, "workspace")
        FileUtils.mkdir_p(workspace)
        File.write(File.join(workspace, "app.rb"), "value = 1\n")
        context = {
          directory:,
          workspace: File.realpath(workspace),
          database: File.join(directory, "tamoz.sqlite3"),
          log: File.join(directory, "events.log"),
          result: File.join(directory, "result.json"),
          digest: Digest::SHA256.hexdigest("value = 1\n")
        }
        status = run_child(context, mode: "run", seam: {})
        raise "reference run failed: #{status.inspect}" unless status.success?

        result = JSON.parse(File.read(context.fetch(:result)))
        raise "reference run did not complete: #{result}" unless
          result.fetch("status") == "completed"

        {
          plan_digest: result.fetch("accepted_plan_digest"),
          model_calls: File.readlines(context.fetch(:log), chomp: true)
                           .count { |entry| entry.start_with?("model:") }
        }
      end
    end
  end

  def run_child(context, mode:, seam:, environment: {})
    # P16: the child loads tamoz/agent, which now requires tamoz/tools.
    # P15: the list is the child's REAL load path. Bundler 4 exports
    # `BUNDLER_SETUP`, which a child honours even with `RUBYOPT` cleared, so
    # this list used to be decorative — every gem in the workspace was on the
    # path regardless, and a missing runtime dependency could not surface here.
    # Clearing both makes the constraint real: `tamoz/sqlite` requires
    # `tamoz/scheduler` and `tamoz/stream`, and this is where that shows.
    # The list mirrors the gems' real require edges: tamoz/sqlite and
    # tamoz/agent both require tamoz/approval (ADR-049 stores + engine).
    load_paths = %w[
      tamoz-comms tamoz-core tamoz-graph tamoz-scheduler tamoz-stream
      tamoz-approval tamoz-sqlite tamoz-tools tamoz-observability
      tamoz-agent-kernel tamoz-agent-memory tamoz-agent-healing tamoz-agent-profile tamoz-agent-improvement
      tamoz-agent
    ].flat_map do |gem|
      ["-I", ROOT.join("gems", gem, "lib").to_s]
    end
    env = {
      "TAMOZ_MODE" => mode,
      "TAMOZ_DB" => context.fetch(:database),
      "TAMOZ_WORKSPACE" => context.fetch(:workspace),
      "TAMOZ_EVENT_LOG" => context.fetch(:log),
      "TAMOZ_RESULT" => context.fetch(:result),
      "TAMOZ_BEFORE_DIGEST" => context.fetch(:digest),
      "TAMOZ_TASK" => "set value to 2 and run the configured check",
      "TAMOZ_KILL_MARKER" => seam[:marker],
      "TAMOZ_KILL_POINT" => seam[:point],
      "TAMOZ_KILL_OPERATION" => seam[:operation],
      "TAMOZ_KILL_SKIP" => seam[:skip]&.to_s,
      "TAMOZ_KILL_PUBLISH" => seam[:publish],
      "RUBYOPT" => nil,
      "BUNDLER_SETUP" => nil
    }.merge(environment)
    pid = Process.spawn(
      env,
      RbConfig.ruby,
      *load_paths,
      "-e",
      CHILD,
      out: ENV["TAMOZ_KILL_DEBUG"] ? $stdout : File::NULL,
      err: ENV["TAMOZ_KILL_DEBUG"] ? $stderr : File::NULL
    )
    _pid, status = Process.wait2(pid)
    status
  end
end
