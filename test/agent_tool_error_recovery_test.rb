# frozen_string_literal: true

require_relative "test_helper"
require "digest"

# Fixed behavioural case for the tool-error surfacing and recovery capability.
# See docs/reviews/AGENT_TOOL_ERROR_RECOVERY_CORRECTION.md.
#
# The capability has three parts and each is proved here:
#   D-7a  a terminal node failure names something actionable on the CLI;
#   D-7b  a `ToolError` discloses its own message through `safe_message`, while a
#         `ProtocolError` and a plain `StandardError` still do not;
#   D-7c  a repairable `ToolError` becomes typed evidence and re-enters the *existing*
#         bounded repair loop, while a policy rejection and a denial stay terminal.
class AgentToolErrorRecoveryTest < Minitest::Test
  class ScriptedModel
    attr_reader :calls

    def initialize(plan:, review:, verify:)
      @responses = {plan:, review:, verify:}.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      value = @responses.fetch(stage).shift
      raise "missing #{stage} response" unless value

      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  # --- D-7b: message disclosure policy -------------------------------------------

  def test_tool_error_discloses_its_own_message_and_other_errors_do_not
    disclosed = Tamoz::NodeError.new(
      node: :step_execute,
      original: Tamoz::Agent::ToolArgumentError.new("patch text was not found")
    )
    assert_equal "patch text was not found", disclosed.safe_message

    policy = Tamoz::NodeError.new(
      node: :step_gate,
      original: Tamoz::Agent::ToolPolicyError.new("path escapes the workspace root")
    )
    assert_equal "path escapes the workspace root", policy.safe_message

    # A ProtocolError message can quote raw provider output, so it must stay generic.
    protocol = Tamoz::NodeError.new(
      node: :deliberate,
      original: Tamoz::Agent::ProtocolError.new("model returned invalid JSON: sk-secret")
    )
    assert_equal "A workflow step failed.", protocol.safe_message
    refute_includes protocol.safe_message, "sk-secret"

    plain = Tamoz::NodeError.new(node: :deliberate, original: RuntimeError.new("boom"))
    assert_equal "A workflow step failed.", plain.safe_message

    assert_equal "A workflow step failed.", Tamoz::NodeError.new(node: :x).safe_message
  end

  def test_disclosed_messages_are_normalized_and_bounded
    long = Tamoz::Agent::ToolArgumentError.new("x" * 4_000)
    disclosed = Tamoz::NodeError.new(node: :n, original: long).safe_message
    assert_operator disclosed.bytesize, :<=, Tamoz::Error::MAX_DISCLOSED_BYTES + 3
    assert disclosed.end_with?("...")

    control = Tamoz::Agent::ToolArgumentError.new("before\nnot\tfound")
    assert_equal(
      "before not found",
      Tamoz::NodeError.new(node: :n, original: control).safe_message
    )

    blank = Tamoz::Agent::ToolArgumentError.new(" ")
    assert_equal(
      "A workflow step failed.",
      Tamoz::NodeError.new(node: :n, original: blank).safe_message
    )

    invalid = Tamoz::Agent::ToolArgumentError.new("bad \xC3( byte".b)
    disclosed_invalid = Tamoz::NodeError.new(node: :n, original: invalid).safe_message
    assert_equal Encoding::UTF_8, disclosed_invalid.encoding
    assert disclosed_invalid.valid_encoding?
  end

  # --- D-7c: taxonomy ------------------------------------------------------------

  def test_taxonomy_marks_only_argument_failures_repairable
    refute Tamoz::Agent::ToolError.new("x").repairable?
    refute Tamoz::Agent::ToolPolicyError.new("x").repairable?
    assert Tamoz::Agent::ToolArgumentError.new("x").repairable?
    assert_kind_of Tamoz::Agent::ToolError, Tamoz::Agent::ToolPolicyError.new("x")
    assert_kind_of Tamoz::Agent::ToolError, Tamoz::Agent::ToolArgumentError.new("x")
  end

  def test_toolbox_classifies_recoverable_and_policy_rejections_by_type
    Dir.mktmpdir("tamoz-classify-root") do |root|
      Dir.mktmpdir("tamoz-classify-outside") do |outside|
        File.write(File.join(outside, "secret.txt"), "secret\n")
        File.symlink(outside, File.join(root, "escape"))
        write_value(root, 40)
        toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
        digest = Digest::SHA256.hexdigest(value_source(40))

        recoverable = {
          "not found" => -> { toolbox.execute("apply_patch", patch_arguments(digest, "nope", "x")) },
          "stale digest" => lambda do
            toolbox.execute("apply_patch", patch_arguments("0" * 64, "40", "42"))
          end,
          "ambiguous" => lambda do
            File.write(File.join(root, "dup.rb"), "same\nsame\n")
            toolbox.execute(
              "apply_patch",
              "path" => "dup.rb",
              "expected_sha256" => Digest::SHA256.hexdigest("same\nsame\n"),
              "before" => "same",
              "after" => "other"
            )
          end,
          "missing target" => -> { toolbox.execute("read_file", "path" => "absent.rb") },
          "bad digest shape" => lambda do
            toolbox.execute("apply_patch", patch_arguments("nothex", "40", "42"))
          end
        }
        recoverable.each do |label, action|
          error = assert_raises(Tamoz::Agent::ToolArgumentError, label) { action.call }
          assert error.repairable?, label
        end

        policy = {
          "symlink escape" => -> { toolbox.execute("read_file", "path" => "escape/secret.txt") },
          "absolute path" => -> { toolbox.execute("read_file", "path" => "/etc/passwd") },
          "parent escape" => -> { toolbox.execute("read_file", "path" => "../outside.txt") },
          "null byte path" => -> { toolbox.execute("read_file", "path" => "a\0b") },
          "null byte patch text" => lambda do
            toolbox.execute("apply_patch", patch_arguments(digest, "4\0" + "0", "42"))
          end
        }
        policy.each do |label, action|
          error = assert_raises(Tamoz::Agent::ToolPolicyError, label) { action.call }
          refute error.repairable?, label
        end

        assert_equal value_source(40), File.read(File.join(root, "broken.rb"))
      end
    end
  end

  # --- D-7c: ephemeral runtime ---------------------------------------------------

  def test_runtime_repairs_from_a_patch_text_miss_and_passes_the_check
    Dir.mktmpdir("tamoz-tool-repair") do |root|
      write_value(root, 40)
      model = scripted_model(
        plans: [
          discovery_plan,
          action_plan(before: "def self.answer = 4O", after: "def self.answer = 42"),
          action_plan_with_trailing_check(before: "def self.answer = 40", after: "def self.answer = 42", trailing_check: "answer2")
        ],
        reviews: 3,
        final_satisfied: true
      )
      events = []

      result = runtime(root, model, checks: answer_check.merge("answer2" => answer_check.fetch("answer"))).run("Make Broken.answer equal 42") { |event| events << event }

      assert result.satisfied
      assert_equal 42, load_value(root)

      rejected = events.select { |event| event.type == :tool_rejected }
      assert_equal 1, rejected.length
      assert_equal "patch text was not found", rejected.first.data.dig("failure", "reason")
      assert_equal(
        "Tamoz::Agent::ToolArgumentError",
        rejected.first.data.dig("failure", "error_class")
      )
      assert_includes rejected.first.data.fetch("output"), "patch text was not found"

      # The rejected patch never became a mutation and never reached a check.
      assert_equal 1, events.count { |event| event.type == :tool_completed && event.data.fetch("tool") == "apply_patch" }
      assert_equal 1, events.count { |event| event.type == :repair_started }

      repair_prompt = model.calls.select { |call| call.fetch(:stage) == :plan }.last.fetch(:prompt)
      assert_includes repair_prompt, "patch text was not found"
      assert_includes repair_prompt, "prior_failure_signatures"
    end
  end

  def test_runtime_bounds_repeated_distinct_tool_rejections_and_never_mutates
    Dir.mktmpdir("tamoz-tool-bound") do |root|
      write_value(root, 40)
      model = scripted_model(
        plans: [
          discovery_plan,
          action_plan(before: "miss-one", after: "42"),
          action_plan_with_trailing_check(before: "miss-two", after: "42", trailing_check: "answer2"),
          action_plan_with_trailing_check(before: "miss-three", after: "42", trailing_check: "answer3"),
          action_plan_with_trailing_check(before: "miss-four", after: "42", trailing_check: "answer4")
        ],
        reviews: 5,
        final_satisfied: false
      )
      events = []

      result = runtime(root, model, checks: answer_check.merge("answer2" => answer_check.fetch("answer"), "answer3" => answer_check.fetch("answer"), "answer4" => answer_check.fetch("answer"))).run("Make Broken.answer equal 42") { |event| events << event }

      refute result.satisfied
      assert_equal 40, load_value(root)
      assert_equal value_source(40), File.read(File.join(root, "broken.rb"))
      # MAX_REPAIR_ATTEMPTS = 2, so three action attempts and no more.
      assert_equal 3, events.count { |event| event.type == :tool_rejected }
      assert_equal 2, events.count { |event| event.type == :repair_started }
      stopped = events.select { |event| event.type == :repair_stopped }
      assert_equal 1, stopped.length
      assert_equal "repair_attempts_exhausted", stopped.first.data.fetch("reason")
      assert_equal 0, events.count { |event| event.type == :tool_completed && event.data.fetch("tool") == "apply_patch" }
      assert_includes result.evidence.last, "repair_attempts_exhausted"
    end
  end

  def test_runtime_stops_an_identical_repeated_rejection_on_the_action_signature
    Dir.mktmpdir("tamoz-tool-identical") do |root|
      write_value(root, 40)
      repeated = action_plan(before: "miss", after: "42")
      model = scripted_model(
        plans: [discovery_plan, repeated, repeated],
        reviews: 3,
        final_satisfied: false
      )
      events = []

      result = runtime(root, model).run("Make Broken.answer equal 42") { |event| events << event }

      refute result.satisfied
      assert_equal 40, load_value(root)
      stopped = events.find { |event| event.type == :repair_stopped }
      assert_equal "repeated_action", stopped.data.fetch("reason")
    end
  end

  def test_runtime_still_terminates_on_a_policy_rejection
    Dir.mktmpdir("tamoz-policy-root") do |root|
      Dir.mktmpdir("tamoz-policy-outside") do |outside|
        write_value(root, 40)
        File.write(File.join(outside, "broken.rb"), value_source(40))
        File.symlink(File.join(outside, "broken.rb"), File.join(root, "link.rb"))
        model = scripted_model(
          plans: [
            discovery_plan,
            action_plan(
              before: "def self.answer = 40",
              after: "def self.answer = 42",
              path: "link.rb",
              digest: Digest::SHA256.hexdigest(value_source(40))
            )
          ],
          reviews: 2,
          final_satisfied: false
        )
        events = []

        error = assert_raises(Tamoz::Agent::ToolPolicyError) do
          runtime(root, model).run("Make Broken.answer equal 42") { |event| events << event }
        end

        # The symlink's realpath lands outside the workspace, so containment fires
        # before the symlink-specific check; either way the rejection is policy.
        assert_match(/escapes the workspace root/, error.message)
        refute error.repairable?
        assert_equal 0, events.count { |event| event.type == :tool_rejected }
        assert_equal 0, events.count { |event| event.type == :repair_started }
        assert_equal value_source(40), File.read(File.join(outside, "broken.rb"))
      end
    end
  end

  def test_runtime_denial_is_a_structured_result_not_an_exception
    Dir.mktmpdir("tamoz-denial") do |root|
      write_value(root, 40)
      action = action_plan(before: "def self.answer = 40", after: "def self.answer = 42")
      model = scripted_model(
        plans: [discovery_plan, action, action],
        reviews: 3,
        final_satisfied: false
      )
      events = []

      result = runtime(root, model, ask: ->(**) { "deny" }).run("Make Broken.answer equal 42") do |event|
        events << event
      end

      refute result.satisfied
      assert events.any? { |event| event.type == :approval_denied }
      denial = result.observations.find do |entry|
        entry.dig("failure", "error_class") == "ToolPolicyError"
      end
      assert denial, "expected a structured ToolPolicyError denial observation"
      assert_includes denial.fetch("failure").fetch("reason"), "denied by operator"
      stopped = events.find { |event| event.type == :repair_stopped }
      assert stopped, "the repair loop stopped on the repeated plan"
    end
  end

  # --- D-7c: durable session -----------------------------------------------------

  def test_session_repairs_from_a_patch_text_miss_and_records_typed_evidence
    with_workspace do |root, adapter|
      write_value(root, 40)
      model = scripted_model(
        plans: [
          discovery_plan,
          action_plan(before: "def self.answer = 4O", after: "def self.answer = 42"),
          action_plan(before: "def self.answer = 40", after: "def self.answer = 42")
        ],
        reviews: 3,
        final_satisfied: true
      )
      session = build_session(model:, root:, adapter:)

      outcome = approve_all(
        session,
        session.start("Make Broken.answer equal 42", thread: "t.repair", request_id: "r.0"),
        thread: "t.repair",
        request_id: "r"
      )

      assert_equal :completed, outcome.status
      assert_equal 42, load_value(root)

      view = session.view(thread: "t.repair")
      failures = view.state.fetch(:observations).select { |record| record.key?("failure") }
      assert_equal 1, failures.length
      failure = failures.first.fetch("failure")
      assert_equal "tool_error", failure.fetch("kind")
      assert_equal "apply_patch", failure.fetch("tool")
      assert_equal "patch text was not found", failure.fetch("reason")
      assert_equal "Tamoz::Agent::ToolArgumentError", failure.fetch("error_class")
      assert_equal "action", failures.first.fetch("phase")
      assert_includes failures.first.fetch("output"), "patch text was not found"

      # The committed implement policy auto-allows workspace writes, so the
      # doomed patch never asks: it fails as a typed effect error instead.
      assert_empty view.approvals.select { |record| record.fetch("tool") == "apply_patch" }
      assert_equal 1, view.state.fetch(:seen_failure_signatures).length
      assert adapter.integrity_check.fetch("ok")
    end
  end

  def test_session_bounds_repeated_distinct_tool_rejections_and_never_mutates
    with_workspace do |root, adapter|
      write_value(root, 40)
      model = scripted_model(
        plans: [
          discovery_plan,
          action_plan(before: "miss-one", after: "42"),
          action_plan(before: "miss-two", after: "42"),
          action_plan(before: "miss-three", after: "42"),
          action_plan(before: "miss-four", after: "42")
        ],
        reviews: 5,
        final_satisfied: false
      )
      session = build_session(model:, root:, adapter:)

      outcome = approve_all(
        session,
        session.start("Make Broken.answer equal 42", thread: "t.bound", request_id: "r.0"),
        thread: "t.bound",
        request_id: "r"
      )

      assert_equal :completed, outcome.status
      refute outcome.result.satisfied
      assert_equal 40, load_value(root)
      assert_equal value_source(40), File.read(File.join(root, "broken.rb"))

      view = session.view(thread: "t.bound")
      assert_equal "repair_attempts_exhausted", view.terminal.fetch("reason")
      assert_equal 3, view.state.fetch(:observations).count { |record| record.key?("failure") }
      # The exhausting rejection's signature is recorded too (legacy `failed_check`
      # behavior): it is evidence, and only two repair attempts actually ran.
      assert_equal 3, view.state.fetch(:seen_failure_signatures).length
      assert_empty view.effect_receipts.select { |record| record.fetch("operation") == "tool.apply_patch" }
      assert adapter.integrity_check.fetch("ok")
    end
  end

  def test_session_still_terminates_on_a_policy_rejection
    with_workspace do |root, adapter|
      Dir.mktmpdir("tamoz-session-policy-outside") do |outside|
        write_value(root, 40)
        File.write(File.join(outside, "broken.rb"), value_source(40))
        File.symlink(File.join(outside, "broken.rb"), File.join(root, "link.rb"))
        model = scripted_model(
          plans: [
            discovery_plan,
            action_plan(
              before: "def self.answer = 40",
              after: "def self.answer = 42",
              path: "link.rb",
              digest: Digest::SHA256.hexdigest(value_source(40))
            )
          ],
          reviews: 2,
          final_satisfied: false
        )
        session = build_session(model:, root:, adapter:)

        outcome = approve_all(
          session,
          session.start("Make Broken.answer equal 42", thread: "t.policy", request_id: "r.0"),
          thread: "t.policy",
          request_id: "r"
        )

        assert_equal :failed, outcome.status
        assert_equal value_source(40), File.read(File.join(outside, "broken.rb"))
        view = session.view(thread: "t.policy")
        assert_empty view.state.fetch(:observations).select { |record| record.key?("failure") }
      end
    end
  end

  # --- D-7a: the operator is told something actionable ---------------------------

  def test_cli_reports_a_specific_reason_for_a_terminal_node_failure
    Dir.mktmpdir("tamoz-cli-error") do |directory|
      Dir.mktmpdir("tamoz-cli-outside") do |outside|
        workspace = File.join(directory, "workspace")
        FileUtils.mkdir_p(workspace)
        workspace = File.realpath(workspace)
        write_value(workspace, 40)
        File.write(File.join(outside, "broken.rb"), value_source(40))
        File.symlink(File.join(outside, "broken.rb"), File.join(workspace, "link.rb"))
        model = scripted_model(
          plans: [
            discovery_plan,
            action_plan(
              before: "def self.answer = 40",
              after: "def self.answer = 42",
              path: "link.rb",
              digest: Digest::SHA256.hexdigest(value_source(40))
            )
          ],
          reviews: 2,
          final_satisfied: false
        )
        err = StringIO.new

        status = Tamoz::Agent::CLI.run(
          [
            "--session-dir", File.join(directory, "sessions"),
            "--root", workspace,
            "--allow-changes",
            "--check", "answer=#{Shellwords.join(answer_check.fetch("answer"))}",
            "--session", "cli-error",
            "ask", "Make Broken.answer equal 42"
          ],
          out: StringIO.new,
          err:,
          input: StringIO.new("y\ny\ny\ny\n"),
          env: {},
          model_factory: ->(_options) { model }
        )

        assert_equal 1, status
        refute_match(/^Error: *$/, err.string)
        # The symlink's realpath lands outside the workspace, so the disclosed reason
        # is the containment violation, and the failing node is named.
        assert_match(/^Error: .*escapes the workspace root/, err.string)
        assert_match(/node step_/, err.string)
        assert_match(/tamoz: session failed: .*escapes the workspace root/, err.string)
      end
    end
  end

  private

  def scripted_model(plans:, reviews:, final_satisfied:)
    ScriptedModel.new(
      plan: plans,
      review: Array.new(reviews) { accepted_review },
      verify: [
        {
          "answer" => "Broken.answer inspection",
          "satisfied" => final_satisfied,
          "evidence" => ["controller-owned evidence"]
        }
      ]
    )
  end

  def runtime(root, model, ask: ->(**) { "approve" }, checks: answer_check)
    Tamoz::Agent.build(
      model:,
      root:,
      allow_changes: true,
      checks:,
      ask:
    )
  end

  def with_workspace
    Dir.mktmpdir("tamoz-tool-error-session") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2)
      )
      begin
        yield File.realpath(root), adapter
      ensure
        adapter.close
      end
    end
  end

  def build_session(model:, root:, adapter:)
    Tamoz::Agent::Session.new(
      model:,
      toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: true, checks: answer_check),
      checkpointer: adapter
    )
  end

  def approve_all(session, outcome, thread:, request_id:, limit: 16)
    current = outcome
    index = 0
    while current.status == :paused && index < limit
      index += 1
      task_id = session.view(thread:).interrupts.first.task_id
      current = session.resume(
        {task_id => {0 => true}},
        thread:,
        request_id: "#{request_id}.#{index}"
      )
    end
    current
  end

  def discovery_plan
    {
      "goal" => "read the current source",
      "done_when" => ["broken.rb has been read"],
      "steps" => [
        {
          "id" => "inspect",
          "purpose" => "read the current bytes",
          "tool" => "read_file",
          "arguments" => {"path" => "broken.rb"},
          "verification" => "the receipt carries the digest"
        }
      ]
    }
  end

  def action_plan(before:, after:, path: "broken.rb", digest: nil)
    {
      "goal" => "make Broken.answer equal 42",
      "done_when" => ["the configured check exits zero"],
      "steps" => [
        {
          "id" => "patch-#{Digest::SHA256.hexdigest(before)[0, 8]}",
          "purpose" => "apply the bounded edit",
          "tool" => "apply_patch",
          "arguments" => patch_arguments(
            digest || Digest::SHA256.hexdigest(value_source(40)),
            before,
            after,
            path:
          ),
          "verification" => "the receipt carries before and after digests"
        },
        {
          "id" => "check",
          "purpose" => "run the configured check",
          "tool" => "run_check",
          "arguments" => {"name" => "answer"},
          "verification" => "the check receipt is observed"
        }
      ]
    }
  end

  def action_plan_with_trailing_check(before:, after:, trailing_check:, path: "broken.rb")
    plan = action_plan(before:, after:, path:)
    plan.fetch("steps") << {
      "id" => "check-#{trailing_check}",
      "purpose" => "run the configured check",
      "tool" => "run_check",
      "arguments" => {"name" => trailing_check},
      "verification" => "the check receipt is observed"
    }
    plan
  end

  def patch_arguments(digest, before, after, path: "broken.rb")
    {
      "path" => path,
      "expected_sha256" => digest,
      "before" => before,
      "after" => after
    }
  end

  def accepted_review
    {"decision" => "accept", "issues" => [], "rationale" => "bounded and independently verifiable"}
  end

  def answer_check
    {
      "answer" => [
        RbConfig.ruby,
        "-I.",
        "-e",
        %q{require './broken'; abort("wrong #{Broken.answer}") unless Broken.answer == 42}
      ]
    }
  end

  def write_value(root, value)
    File.write(File.join(root, "broken.rb"), value_source(value))
  end

  def value_source(value)
    "module Broken\n  def self.answer = #{value}\nend\n"
  end

  def load_value(root)
    match = File.read(File.join(root, "broken.rb")).match(/answer = (\d+)/)
    match && Integer(match[1])
  end
end
