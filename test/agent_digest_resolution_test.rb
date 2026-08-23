# frozen_string_literal: true

require_relative "test_helper"
require "digest"

# D-8 Fix A/B/C behavioural cases. See docs/D8_ACTION_PLAN_DIGEST_PLAN.md §3.
#
#   T2  absent digest resolves exactly once; the preview and the executed bytes are
#       the same (both drivers);
#   T3  placeholder arguments are rejected by structural review with the exact
#       message, while legitimate `<`/`>` in patch text passes;
#   T4  PlanRejectedError discloses a bounded summary of structural issues only;
#   T5  Session driver: a mutation between approval and dispatch is refused by
#       `verify_intent_before_state!` (ToolPolicyError), file byte-identical;
#   T5R Runtime driver: a stale committed digest is refused fail closed by
#       `prepare_patch`'s live equality check (ToolPolicyError — terminal, not a
#       repairable argument value), file byte-identical;
#   T8  repeated identical absent-digest plans stop on `repeated_action`;
#   T9  create_file absent content digest resolves from `hexdigest(content)`.
class AgentDigestResolutionTest < Minitest::Test
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

  # --- T2: absent digest, single resolution, preview == execution (Runtime) -------

  def test_runtime_resolves_absent_digest_once_and_binds_preview_to_execution
    Dir.mktmpdir("tamoz-digest-runtime") do |root|
      write_value(root, 40)
      observed = Digest::SHA256.hexdigest(value_source(40))
      model = scripted_model(
        plans: [discovery_plan, absent_action_plan],
        reviews: 2,
        final_satisfied: true
      )
      events = []

      result = runtime(root, model).run("Make Broken.answer equal 42") { |event| events << event }

      assert result.satisfied
      assert_equal 42, load_value(root)

      # The approval asked about the RESOLVED state: the preview shows the bound
      # after-bytes (emitted events carry the PLAN's arguments; the injected
      # digest is execution metadata, asserted through the receipt below).
      patch_approval = events.find do |event|
        event.type == :approval_requested && event.data.fetch("tool") == "apply_patch"
      end
      assert patch_approval, "apply_patch approval was never requested"
      assert_equal "ask", patch_approval.data.fetch("verdict")
      assert_includes patch_approval.data.fetch("preview"), "def self.answer = 42"
      granted = events.find do |event|
        event.type == :approval_granted && event.data.fetch("tool") == "apply_patch"
      end
      assert granted, "the apply_patch ask was never answered"

      # The executed patch bound to the SAME digest: preview and execution bytes agree.
      completed = events.find do |event|
        event.type == :tool_completed && event.data.fetch("tool") == "apply_patch"
      end
      assert completed
      assert_includes completed.data.fetch("output"), "before_sha256: #{observed}"
      # The check ran and passed.
      assert events.any? do |event|
        event.type == :tool_completed && event.data.dig("check", "passed") == true
      end
    end
  end

  def test_runtime_present_stale_digest_is_refused_fail_closed
    Dir.mktmpdir("tamoz-digest-stale") do |root|
      write_value(root, 40)
      model = scripted_model(
        plans: [
          discovery_plan,
          action_plan(before: "def self.answer = 40", after: "def self.answer = 42",
                      digest: "0" * 64),
          action_plan(before: "def self.answer = 40", after: "def self.answer = 42",
                      digest: "0" * 64)
        ],
        reviews: 3,
        final_satisfied: false
      )
      events = []

      error = assert_raises(Tamoz::Agent::ToolPolicyError) do
        runtime(root, model).run("Make Broken.answer equal 42") { |event| events << event }
      end

      # A stale committed digest is a policy refusal, terminal by construction —
      # never a repairable value the planner can iterate against.
      assert_includes error.message, "file changed"
      assert_equal 40, load_value(root)
      completed_patches = events.count { |event|
        event.type == :tool_completed && event.data.fetch("tool") == "apply_patch"
      }
      assert_equal 0, completed_patches
    end
  end

  # --- T2: absent digest, single resolution (Session) ------------------------------

  def test_session_resolves_absent_digest_once_and_executes_the_approved_bytes
    with_workspace do |root, adapter|
      write_value(root, 40)
      observed = Digest::SHA256.hexdigest(value_source(40))
      model = scripted_model(plans: [discovery_plan, absent_action_plan], reviews: 2, final_satisfied: true)
      session = build_session(model:, root:, adapter:)

      paused = session.start(
        "Make Broken.answer equal 42",
        thread: "t.absent",
        request_id: "r.0"
      )

      assert_equal :paused, paused.status
      descriptor = paused.approvals.first
      assert_equal "apply_patch", descriptor.fetch("tool")
      # The approval descriptor shows the RESOLVED digest (the bound state).
      assert_equal observed, descriptor.dig("arguments", "expected_sha256")

      completed = approve_all(session, paused, thread: "t.absent", request_id: "r")

      assert_equal :completed, completed.status
      assert_equal 42, load_value(root)

      view = session.view(thread: "t.absent")
      intent = view.state.fetch(:effect_intents).find do |record|
        record.fetch("tool") == "apply_patch"
      end
      assert intent
      assert_equal observed, intent.fetch("before_state")
      # The executed patch's receipt carries the same before digest.
      patch_observation = view.state.fetch(:observations).find do |record|
        record.fetch("tool") == "apply_patch"
      end
      assert patch_observation
      assert_includes patch_observation.fetch("output"), "before_sha256: #{observed}"
      assert view.state.fetch(:check_passed)
      assert adapter.integrity_check.fetch("ok")
    end
  end

  # --- T3: scoped placeholder rejection + negative ---------------------------------

  def test_placeholder_path_is_rejected_with_the_exact_structural_message
    Dir.mktmpdir("tamoz-digest-placeholder") do |root|
      File.write(File.join(root, "note.txt"), "content\n")
      model = scripted_model(
        plans: [
          plan_for("read_file", {"path" => "<path from search result>"}),
          plan_for("read_file", {"path" => "note.txt"})
        ],
        reviews: 0,
        final_satisfied: false
      )
      events = []
      runtime = Tamoz::Agent.build(model:, root:, max_plan_attempts: 1)

      error = assert_raises(Tamoz::Agent::PlanRejectedError) do
        runtime.run("Explain note.txt") { |event| events << event }
      end
      assert_includes(
        error.message,
        "step \"inspect\" arguments contain a placeholder; every argument must be " \
        "a concrete value already known from evidence"
      )
      refute events.any? { |event| event.type == :tool_started }
    end
  end

  def test_reference_phrase_path_is_rejected_by_structural_review
    Dir.mktmpdir("tamoz-digest-reference-path") do |root|
      File.write(File.join(root, "note.txt"), "content\n")
      # A bare reference with no angle brackets (the F2 shape a real model emits)
      # must still be rejected: the reference-phrase rule applies to `path` and
      # digest-shaped arguments (the critic-hardened scope).
      model = scripted_model(
        plans: [
          plan_for("read_file", {"path" => "to be filled from search result"}),
          plan_for("read_file", {"path" => "note.txt"})
        ],
        reviews: 0,
        final_satisfied: false
      )
      events = []
      runtime = Tamoz::Agent.build(model:, root:, max_plan_attempts: 1)

      error = assert_raises(Tamoz::Agent::PlanRejectedError) do
        runtime.run("Explain note.txt") { |event| events << event }
      end
      assert_includes error.message, "arguments contain a placeholder"
      refute events.any? { |event| event.type == :tool_started }
    end
  end

  def test_legitimate_angle_brackets_in_patch_text_pass_structural_review_and_execute
    Dir.mktmpdir("tamoz-digest-negative") do |root|
      File.write(File.join(root, "expr.rb"), "answer = a < b\n")
      model = scripted_model(
        plans: [
          discovery_plan_for("expr.rb"),
          plan_for("apply_patch", {
            "path" => "expr.rb",
            "expected_sha256" => Digest::SHA256.hexdigest("answer = a < b\n"),
            "before" => "a < b",
            "after" => "a >= b"
          })
        ],
        reviews: 2,
        final_satisfied: true
      )
      events = []

      # No configured checks: the action plan needs no run_check step, so the
      # structural review outcome is decided purely by the placeholder heuristic.
      result = Tamoz::Agent.build(model:, root:, allow_changes: true, ask: ->(**_kw) { :approve })
                          .run("Fix the comparison") { |event| events << event }

      assert result.satisfied
      assert_equal "answer = a >= b\n", File.read(File.join(root, "expr.rb"))
      structural = events.select do |event|
        event.type == :plan_reviewed && event.data.fetch("layer") == "structural"
      end
      assert_equal %w[accept accept], structural.map { |event| event.data.fetch("decision") }
    end
  end

  def test_reference_phrases_in_patch_text_and_queries_are_not_placeholders
    Dir.mktmpdir("tamoz-digest-phrase-negative") do |root|
      File.write(File.join(root, "doc.rb"), "from step 1\n")
      # The D-8 critic hardening: cross-step reference phrases are legitimate
      # text in patch `before`/`after` and in query/content values — only `path`
      # and digest-shaped arguments can carry a placeholder reference. Without
      # this, a real model patching "from step 1" -> "from step 2" is rejected
      # with the placeholder message (the exact failure class D-8 exists to fix).
      model = scripted_model(
        plans: [
          # Discovery: a query legitimately containing the phrase must pass
          # structural review (only path/digest args are phrase-checked).
          {
            "goal" => "locate the step reference",
            "done_when" => ["the query and the read both succeed"],
            "steps" => [
              {"id" => "q", "purpose" => "search for the phrase", "tool" => "search_text",
               "arguments" => {"query" => "from search result", "path" => "doc.rb"},
               "verification" => "the search finds the line"},
              {"id" => "r", "purpose" => "read the file", "tool" => "read_file",
               "arguments" => {"path" => "doc.rb"}, "verification" => "the content is read"}
            ]
          },
          # Action: patch text legitimately containing the phrase.
          plan_for("apply_patch", {
            "path" => "doc.rb",
            "expected_sha256" => Digest::SHA256.hexdigest("from step 1\n"),
            "before" => "from step 1",
            "after" => "from step 2"
          })
        ],
        reviews: 2,
        final_satisfied: true
      )
      events = []
      result = Tamoz::Agent.build(model:, root:, allow_changes: true, ask: ->(**_kw) { :approve })
                          .run("Fix the step reference") { |event| events << event }

      assert result.satisfied
      assert_equal "from step 2\n", File.read(File.join(root, "doc.rb"))
      structural = events.select do |event|
        event.type == :plan_reviewed && event.data.fetch("layer") == "structural"
      end
      assert_equal %w[accept accept], structural.map { |event| event.data.fetch("decision") }
    end
  end

  # --- T4: structural-only rejection disclosure ------------------------------------

  def test_structural_rejection_discloses_bounded_tamoz_issues_only
    Dir.mktmpdir("tamoz-disclose-structural") do |root|
      model = scripted_model(
        plans: Array.new(3) { plan_for("read_file", {"path" => "<path from search result>"}) },
        reviews: 0,
        final_satisfied: false
      )
      events = []

      error = assert_raises(Tamoz::Agent::PlanRejectedError) do
        runtime(root, model).run("Explain") { |event| events << event }
      end
      assert_includes error.message, "no plan passed review after 3 attempts"
      assert_includes error.message, "arguments contain a placeholder"
      assert_equal 3, events.count { |event| event.type == :plan_reviewed }
    end
  end

  def test_semantic_rejection_discloses_only_the_generic_phrase
    Dir.mktmpdir("tamoz-disclose-semantic") do |root|
      model = ScriptedModel.new(
        plan: Array.new(3) { plan_for(nil, {}) },
        review: Array.new(3) do
          {"decision" => "revise", "issues" => ["model-authored secret: sk-abcdef"], "rationale" => "x"}
        end,
        verify: []
      )
      events = []

      error = assert_raises(Tamoz::Agent::PlanRejectedError) do
        runtime(root, model).run("Explain") { |event| events << event }
      end
      assert_includes error.message, "the plan did not pass review; the last feedback is not discloseable"
      refute_includes error.message, "sk-abcdef"
    end
  end

  def test_protocol_rejection_discloses_nothing_of_the_provider_payload
    Dir.mktmpdir("tamoz-disclose-protocol") do |root|
      payload = '{"steps": invalid json sk-SECRET123'
      model = ScriptedModel.new(
        plan: Array.new(3) { payload },
        review: [],
        verify: []
      )
      events = []

      error = assert_raises(Tamoz::Agent::PlanRejectedError) do
        runtime(root, model).run("Explain") { |event| events << event }
      end
      assert_includes error.message, "not discloseable"
      refute_includes error.message, "SECRET123"
      refute_includes error.message, "invalid json"
    end
  end

  def test_plan_rejected_error_discloses_through_node_error_like_a_tool_error
    disclosed = Tamoz::NodeError.new(
      node: :deliberate,
      original: Tamoz::Agent::PlanRejectedError.new(
        "no plan passed review after 3 attempts: step \"x\" is invalid: relative path"
      )
    )
    assert_equal(
      "no plan passed review after 3 attempts: step \"x\" is invalid: relative path",
      disclosed.safe_message
    )

    generic = Tamoz::NodeError.new(
      node: :deliberate,
      original: Tamoz::Agent::PlanRejectedError.new(
        "no plan passed review after 3 attempts: the plan did not pass review; " \
        "the last feedback is not discloseable"
      )
    )
    assert_equal(
      "no plan passed review after 3 attempts: the plan did not pass review; " \
      "the last feedback is not discloseable",
      generic.safe_message
    )
  end

  def test_cli_discloses_the_structural_rejection_reason
    Dir.mktmpdir("tamoz-disclose-cli") do |directory|
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      workspace = File.realpath(workspace)
      File.write(File.join(workspace, "note.txt"), "content\n")
      model = ScriptedModel.new(
        plan: Array.new(3) { plan_for("read_file", {"path" => "<path from search result>"}) },
        review: [],
        verify: []
      )
      err = StringIO.new

      status = Tamoz::Agent::CLI.run(
        [
          "--session-dir", File.join(directory, "sessions"),
          "--root", workspace,
          "--session", "cli-disclose",
          "ask", "Explain note.txt"
        ],
        out: StringIO.new,
        err:,
        input: StringIO.new("y\ny\ny\ny\n"),
        env: {},
        model_factory: ->(_options) { model }
      )

      assert_equal 1, status
      assert_match(/^Error: .*no plan passed review after 3 attempts/, err.string)
      assert_match(/arguments contain a placeholder/, err.string)
      # Model-authored placeholder text never reaches the operator line.
      refute_includes err.string, "<path from search result>"
    end
  end

  # --- T5: Session driver — mutation between approval and dispatch ----------------

  def test_session_mutation_between_approval_and_dispatch_is_refused_fail_closed
    Dir.mktmpdir("tamoz-digest-session-mutate") do |directory|
      root = File.join(directory, "workspace")
      FileUtils.mkdir_p(root)
      root = File.realpath(root)
      write_value(root, 40)
      mutated = "module Broken\n  def self.answer = 99\nend\n"
      armed = false
      fired = false
      adapter = Tamoz::SQLite::Adapter.new(
        path: File.join(directory, "tamoz.sqlite3"),
        limits: Tamoz::SQLite::Limits.new(lease_ttl: 5.0, effect_attempt_ttl: 0.2),
        fault_injector: lambda do |point, metadata|
          next unless armed && !fired
          next unless point == :after_commit && metadata.fetch("operation") == "effect.prepare"

          fired = true
          File.write(File.join(root, "broken.rb"), mutated)
        end
      )
      begin
        model = scripted_model(plans: [discovery_plan, absent_action_plan], reviews: 2, final_satisfied: false)
        session = build_session(model:, root:, adapter:)

        paused = session.start(
          "Make Broken.answer equal 42",
          thread: "t.mutate",
          request_id: "r.0"
        )
        assert_equal :paused, paused.status
        assert_equal "apply_patch", paused.approvals.first.fetch("tool")

        # The mutation lands exactly between the approval answer and the dispatch:
        # the first effect.prepare after the approval is the apply_patch effect.
        armed = true
        completed = approve_all(session, paused, thread: "t.mutate", request_id: "r")
        armed = false

        refute_equal :completed, completed.status
        assert fired
        # The patch was refused and never applied to the mutated bytes.
        assert_equal mutated, File.read(File.join(root, "broken.rb"))
        refute_equal 42, load_value(root)

        view = session.view(thread: "t.mutate")
        succeeded_patches = view.effect_receipts.select { |record|
          record.fetch("operation") == "tool.apply_patch" && record.fetch("status") == "succeeded"
        }
        assert_empty succeeded_patches
        assert adapter.integrity_check.fetch("ok")
      ensure
        adapter.close
      end
    end
  end

  # --- T8: repeated identical absent-digest plans ----------------------------------

  def test_repeated_identical_absent_digest_plans_stop_on_repeated_action
    Dir.mktmpdir("tamoz-digest-repeat") do |root|
      write_value(root, 40)
      repeated = action_plan(before: "def self.answer = 4O", after: "def self.answer = 42", digest: nil)
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
      assert stopped
      assert_equal "repeated_action", stopped.data.fetch("reason")
      completed_patches = events.count { |event|
        event.type == :tool_completed && event.data.fetch("tool") == "apply_patch"
      }
      assert_equal 0, completed_patches
    end
  end

  # --- T9: create_file absent content digest ---------------------------------------

  def test_create_file_absent_digest_resolves_from_content_and_receipt_verifies
    Dir.mktmpdir("tamoz-digest-create") do |root|
      desired = "hello\n"
      model = scripted_model(
        plans: [
          plan_for("list_directory", {"path" => "."}),
          {
            "goal" => "create the file",
            "done_when" => ["greeting.txt exists with the exact bytes and the check passes"],
            "steps" => [
              {
                "id" => "create",
                "purpose" => "create the file",
                "tool" => "create_file",
                "arguments" => {"path" => "greeting.txt", "content" => desired},
                "verification" => "the receipt reports the published digest"
              },
              {
                "id" => "check",
                "purpose" => "run the configured check",
                "tool" => "run_check",
                "arguments" => {"name" => "greeting"},
                "verification" => "the check receipt is observed"
              }
            ]
          }
        ],
        reviews: 2,
        final_satisfied: true
      )
      events = []

      result = Tamoz::Agent.build(
        model:,
        root:,
        allow_changes: true,
        checks: {
          "greeting" => [
            RbConfig.ruby,
            "-e",
            %q{abort("wrong") unless File.read("greeting.txt") == "hello\n"}
          ]
        },
        ask: ->(**_kw) { :approve }
      ).run("Create greeting.txt") { |event| events << event }

      assert result.satisfied
      assert_equal desired, File.read(File.join(root, "greeting.txt"))
      created = events.find do |event|
        event.type == :tool_completed && event.data.fetch("tool") == "create_file"
      end
      assert created
      assert_includes created.data.fetch("output"), "sha256: #{Digest::SHA256.hexdigest(desired)}"
    end
  end

  def test_create_file_present_wrong_digest_is_still_refused
    Dir.mktmpdir("tamoz-digest-create-mismatch") do |root|
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)

      error = assert_raises(Tamoz::Agent::ToolArgumentError) do
        toolbox.execute(
          "create_file",
          "path" => "greeting.txt",
          "content" => "hello\n",
          "expected_sha256" => "0" * 64
        )
      end
      assert_includes error.message, "content digest mismatch"
      refute File.exist?(File.join(root, "greeting.txt"))
    end
  end

  def test_toolbox_direct_apply_patch_accepts_absent_digest_and_binds
    Dir.mktmpdir("tamoz-digest-direct") do |root|
      write_value(root, 40)
      toolbox = Tamoz::Agent::Toolbox.new(root:, allow_changes: true)
      observed = Digest::SHA256.hexdigest(value_source(40))

      result = toolbox.execute("apply_patch", {
        "path" => "broken.rb",
        "before" => "def self.answer = 40",
        "after" => "def self.answer = 42"
      })

      assert_includes result, "before_sha256: #{observed}"
      assert_equal 42, load_value(root)
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

  # The review profile makes workspace_write ASK, so apply_patch produces a real
  # approval decision (with a preview bound to the resolved digest) instead of the
  # implement profile's silent allow.
  def runtime(root, model)
    Tamoz::Agent::Runtime.new(
      model:,
      toolbox: Tamoz::Agent::Toolbox.new(root:, allow_changes: true, checks: answer_check),
      approval_engine: Tamoz::Agent.build_approval_engine(profile_name: "review"),
      ask: ->(**_kw) { :approve }
    )
  end

  def with_workspace
    Dir.mktmpdir("tamoz-digest-session") do |directory|
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
      checkpointer: adapter,
      approval_engine: Tamoz::Agent.build_approval_engine(profile_name: "review")
    )
  end

  def approve_all(session, outcome, thread:, request_id:, limit: 8)
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
    plan_for("read_file", {"path" => "broken.rb"}, id: "inspect")
  end

  def discovery_plan_for(path)
    plan_for("read_file", {"path" => path}, id: "inspect")
  end

  # An action plan whose apply_patch step carries NO `expected_sha256` — the shape a
  # real model produces before a read executes (D-8 F1).
  def absent_action_plan
    {
      "goal" => "make Broken.answer equal 42",
      "done_when" => ["the configured check exits zero"],
      "steps" => [
        {
          "id" => "patch",
          "purpose" => "apply the bounded edit",
          "tool" => "apply_patch",
          "arguments" => {
            "path" => "broken.rb",
            "before" => "def self.answer = 40",
            "after" => "def self.answer = 42"
          },
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

  def action_plan(before:, after:, path: "broken.rb", digest: nil)
    arguments = {
      "path" => path,
      "before" => before,
      "after" => after
    }
    arguments["expected_sha256"] = digest unless digest.nil?
    {
      "goal" => "make Broken.answer equal 42",
      "done_when" => ["the configured check exits zero"],
      "steps" => [
        {
          "id" => "patch-#{Digest::SHA256.hexdigest(before)[0, 8]}",
          "purpose" => "apply the bounded edit",
          "tool" => "apply_patch",
          "arguments" => arguments,
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

  def plan_for(tool, arguments, id: "inspect")
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
