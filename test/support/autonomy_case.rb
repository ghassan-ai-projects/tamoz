# frozen_string_literal: true

# Harness for the autonomy scorecard.
#
# Everything a case does to the product goes through `Tamoz::Agent::CLI.run`.
# The only direct filesystem work here is the setup an operator would do by
# hand: create a runtime directory, write a trusted profile into it, put files
# in a workspace. Nothing here constructs a Session, a store, or a runner —
# if the CLI cannot do it, the scorecard cannot claim it.
#
# The runtime directory is the single operator-owned unit:
#
#   <runtime-dir>/
#     config.yaml        operator configuration (workspace, sources, bounds)
#     profiles/*.yaml    trusted profiles
#     runtime.sqlite3    schedules, request inboxes, checkpoints
#
require "psych"
require "securerandom"
require "shellwords"

module AutonomyCase
  READ_ONLY_TOOLS = %w[list_directory read_file search_text].freeze

  # A model whose answers are fixed, so a case measures the runtime and never
  # the weather inside a real model.
  class ScriptedModel
    attr_reader :calls

    def initialize(**responses)
      @responses = responses.transform_values(&:dup)
      @calls = []
    end

    def generate(stage:, system:, prompt:)
      @calls << {stage:, system:, prompt:}
      queue = @responses.fetch(stage) { raise "no scripted #{stage} response" }
      raise "no scripted #{stage} response" if queue.empty?

      value = queue.length == 1 ? queue.first : queue.shift
      value.is_a?(String) ? value : JSON.generate(value)
    end
  end

  # Dies at a named point in the turn, the way a `kill -9` would: no unwinding,
  # no chance to write a tidy terminal record.
  class CrashingModel < ScriptedModel
    # Deliberately NOT a StandardError. A `kill -9` does not give the worker a
    # chance to rescue, log, and record a tidy terminal failure — and a worker
    # that turns a crash into a clean failure record would pass a recovery test
    # while never exercising recovery. Raising outside the StandardError
    # hierarchy walks through every `rescue StandardError` between here and the
    # process boundary, which is the behaviour being modelled.
    class Killed < Exception; end # rubocop:disable Lint/InheritException

    def initialize(after:, **responses)
      super(**responses)
      @after = after
      @fired = false
    end

    def generate(stage:, system:, prompt:)
      result = super
      if !@fired && crash_point?(stage, result)
        @fired = true
        raise Killed, "simulated kill -9 after #{@after}"
      end
      result
    end

    private

    def crash_point?(stage, _result)
      case @after
      when :claim then stage == :plan
      when :effect_started then stage == :review
      else false
      end
    end
  end

  # The operator's view of one runtime directory.
  class Runtime
    attr_reader :dir, :workspace, :out, :err

    def initialize(dir:, workspace:)
      @dir = dir
      @workspace = workspace
      @out = ""
      @err = ""
      @events = []
    end

    # Every product interaction goes through here.
    def cli(argv, factory: nil, input: "")
      out = StringIO.new
      err = StringIO.new
      status = Tamoz::Agent::CLI.run(
        ["--runtime-dir", dir] + argv,
        out:, err:, input: StringIO.new(input),
        env: {"TAMOZ_CONFIG_HOME" => File.join(dir, "config")},
        model_factory: factory
      )
      @out = out.string
      @err = err.string
      @events.concat(parse_events(@out))
      status
    rescue CrashingModel::Killed
      # The process is gone. Whatever the store committed before this point is
      # all that survives — exactly what a real crash leaves behind.
      @out = out.string
      @err = err.string
      @events.concat(parse_events(@out))
      137
    end

    # Structured events the worker emitted, across every invocation so far.
    def events = @events

    def status_document
      cli(%w[status --json])
      JSON.parse(@out)
    rescue JSON::ParserError
      {}
    end

    def counter(name)
      status_document.dig("safety_counters", name) || 0
    end

    def occurrences(schedule_id)
      cli(%W[schedule occurrences #{schedule_id} --json])
      JSON.parse(@out).fetch("occurrences", [])
    rescue JSON::ParserError
      []
    end

    def pending_approvals = status_document.fetch("paused_approvals", [])
    def blocked_effects = status_document.fetch("blocked_effects", [])
    def budget_exhaustions = status_document.fetch("budget_exhaustions", [])
    def capability_sources = status_document.fetch("capability_sources", [])

    # What the agent can actually dispatch, as opposed to what configuration
    # merely names. A source that appears here is wired into the capability host.
    def capability_catalog = status_document.fetch("capability_catalog", [])
    def queue_depth = status_document.dig("stream", "queue_depth") || 0
    def spool_bytes = status_document.dig("stream", "spool_bytes") || 0

    def publish_burst(count:, bytes:)
      cli(%W[stream publish --channel probe --count #{count} --bytes #{bytes}])
    end

    # Operator turns a shipped capability source on. Only this may grant it.
    def enable_source(name)
      path = File.join(dir, "config.yaml")
      document = Psych.safe_load_file(path)
      document["sources"] ||= {}
      document["sources"][name] = {"enabled" => true}
      File.write(path, Psych.dump(document))
    end

    private

    def parse_events(text)
      text.each_line.filter_map do |line|
        line = line.strip
        next if line.empty? || !line.start_with?("{")

        begin
          JSON.parse(line)
        rescue JSON::ParserError
          nil
        end
      end
    end
  end

  # -------------------------------------------------------------- fixtures

  def with_runtime(unattended: nil, budgets: nil, stream: nil)
    Dir.mktmpdir("tamoz-autonomy") do |directory|
      runtime_dir = File.join(directory, "runtime")
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      File.chmod(0o700, runtime_dir)

      write_config(runtime_dir, workspace, stream:)
      write_trusted_profile(runtime_dir, workspace, unattended:, budgets:)

      yield Runtime.new(dir: runtime_dir, workspace:)
    end
  end

  def write_config(runtime_dir, workspace, stream: nil)
    document = {
      "runtime" => {"schema_version" => 1},
      "workspace" => {"root" => workspace},
      "sources" => {}
    }
    document["stream"] = stream if stream
    File.write(File.join(runtime_dir, "config.yaml"), Psych.dump(document))
    File.chmod(0o600, File.join(runtime_dir, "config.yaml"))
  end

  # The trusted profile is the ONLY thing that may preauthorize unattended work.
  # The profile always ALLOWS the edit tools — `tools.allowed` is what is
  # possible on this project. What varies per case is the `unattended` section:
  # what may happen with nobody watching. That separation is the whole point of
  # the policy, so the fixture must not collapse the two.
  def write_trusted_profile(runtime_dir, workspace, unattended: nil, budgets: nil)
    tools = READ_ONLY_TOOLS + %w[apply_patch create_file]
    allow_changes = true

    preauthorized = READ_ONLY_TOOLS + Array(unattended && unattended["reconcilable"])
    unattended_approval = tools - preauthorized

    digest = Tamoz::Agent::Toolbox.new(
      root: workspace, allow_changes:, checks: {},
      allowed_tools: tools, approval_required: []
    ).catalog_digest
    # The catalog a WORKER sees: same tools, approval required on everything the
    # unattended section did not preauthorize.
    unattended_digest = Tamoz::Agent::Toolbox.new(
      root: workspace, allow_changes:, checks: {},
      allowed_tools: tools, approval_required: unattended_approval
    ).catalog_digest

    document = {
      "profile" => {
        "schema_version" => 1,
        "profile_id" => "trusted",
        "profile_version" => "1.0",
        "canonical_root" => workspace
      },
      "roots" => {"workspace" => workspace},
      "tools" => {"allowed" => tools, "approval_required" => []},
      "policy" => {
        "allow_changes" => allow_changes,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => digest,
        "unattended_catalog_digest" => unattended_digest
      }
    }
    # The unattended section names, by risk class, what may run with nobody
    # watching. Absent section = nothing runs unattended beyond read-only.
    document["unattended"] = {
      "read_only" => READ_ONLY_TOOLS,
      "reconcilable" => Array(unattended && unattended["reconcilable"]),
      "approval_required" => [],
      "forbidden" => []
    }
    document["budgets"] = budgets if budgets

    directory = File.join(runtime_dir, "profiles")
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.chmod(0o700, directory)
    path = File.join(directory, "trusted.yaml")
    File.write(path, Psych.dump(document))
    File.chmod(0o600, path)
    path
  end

  # -------------------------------------------------------------- factories

  def read_only_factory
    ->(_options) do
      ScriptedModel.new(
        plan: [plan_step("read_file", {"path" => "note.txt"})],
        review: [accepted_review],
        verify: [{"answer" => "hello", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
    end
  end

  def edit_factory
    ->(_options) do
      ScriptedModel.new(
        plan: [
          plan_step("read_file", {"path" => "note.txt"}),
          edit_plan
        ],
        review: [accepted_review],
        verify: [{"answer" => "fixed", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
    end
  end

  # Never finishes on its own — only a budget can stop it.
  def looping_factory
    ->(_options) do
      ScriptedModel.new(
        plan: [plan_step("read_file", {"path" => "note.txt"})],
        review: [{"decision" => "revise", "issues" => ["try again"], "rationale" => "loop"}],
        verify: [{"answer" => "", "satisfied" => false, "evidence" => []}]
      )
    end
  end

  def crashing_factory(after:)
    ->(_options) do
      CrashingModel.new(
        after:,
        plan: [plan_step("read_file", {"path" => "note.txt"}), edit_plan],
        review: [accepted_review],
        verify: [{"answer" => "fixed", "satisfied" => true, "evidence" => ["note.txt"]}]
      )
    end
  end

  def plan_step(tool, arguments, id: "s1")
    {
      "goal" => "answer the task",
      "done_when" => ["the tool returned evidence"],
      "steps" => [
        {"id" => id, "purpose" => "gather evidence", "tool" => tool,
         "arguments" => arguments, "verification" => "the output is present"}
      ]
    }
  end

  def edit_plan
    {
      "goal" => "fix note.txt",
      "done_when" => ["note.txt reads fixed"],
      "steps" => [
        {
          "id" => "edit",
          "purpose" => "apply the exact replacement",
          "tool" => "apply_patch",
          "arguments" => {"path" => "note.txt", "before" => "hello", "after" => "fixed"},
          "verification" => "the receipt reports the new digest"
        }
      ]
    }
  end

  def accepted_review = {"decision" => "accept", "issues" => [], "rationale" => "sound"}

  # ------------------------------------------------------------- assertions

  # The four counters that must never move, in every case, without exception.
  HARD_COUNTERS = %w[
    unauthorized_effects
    duplicate_effects
    unknown_effect_retries
    headless_auto_approvals
  ].freeze

  def assert_hard_counters_zero(runtime)
    document = runtime.status_document
    HARD_COUNTERS.each do |name|
      value = document.dig("safety_counters", name) || 0
      assert_equal 0, value, "hard safety counter #{name} is #{value}, must be 0"
    end
  end
end
