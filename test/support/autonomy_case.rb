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

    def after_effect_started(operation:)
      return unless @after == :effect_started && operation == "tool.apply_patch" && !@fired

      @fired = true
      raise Killed, "simulated kill -9 after effect started"
    end

    private

    def crash_point?(stage, _result)
      case @after
      when :claim then stage == :plan
      else false
      end
    end
  end

  # The operator's view of one runtime directory.
  class Runtime
    attr_reader :dir, :workspace, :out, :err
    attr_accessor :client

    def initialize(dir:, workspace:)
      @dir = dir
      @workspace = workspace
      @out = ""
      @err = ""
      @events = []
      @client = nil
    end

    # Every product interaction goes through here.
    def cli(argv, factory: nil, input: "", comms_factory: nil)
      out = StringIO.new
      err = StringIO.new
      env = {"TAMOZ_CONFIG_HOME" => File.join(dir, "config")}
      env["TAMOZ_TELEGRAM_BOT_TOKEN"] = "12345:secret" if @client
      status = Tamoz::Agent::CLI.run(
        ["--runtime-dir", dir] + argv,
        out:, err:, input: StringIO.new(input),
        env:,
        model_factory: factory,
        comms_client_factory: comms_factory || (@client && ->(_token) { @client })
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
    rescue JSON::ParserError => e
      # A gate that cannot fail is not a gate: unparseable status output is a
      # real failure (a crashed/garbled status command), never empty data that
      # would let assert_hard_counters_zero pass vacuously.
      raise "`status --json` did not return parseable JSON (#{e.message}): #{@out.inspect}"
    end

    def counter(name)
      status_document.dig("safety_counters", name) || 0
    end

    def occurrences(schedule_id)
      cli(%W[schedule occurrences #{schedule_id} --json])
      JSON.parse(@out).fetch("occurrences", [])
    rescue JSON::ParserError => e
      raise "`schedule occurrences --json` did not return parseable JSON (#{e.message}): #{@out.inspect}"
    end

    def pending_approvals = status_document.fetch("paused_approvals", [])
    def blocked_effects = status_document.fetch("blocked_effects", [])
    def budget_exhaustions = status_document.fetch("budget_exhaustions", [])
    def capability_sources = status_document.fetch("capability_sources", [])

    # What the agent can actually dispatch, as opposed to what configuration
    # merely names. A source that appears here is wired into the capability host.
    def capability_catalog = status_document.fetch("capability_catalog", [])

    # Enabling skills changes the tool catalog (the skill verbs join it), and a
    # profile pins the exact catalog. Re-pinning is what an operator does after
    # changing the surface; the digest is authority, so it must be recomputed
    # deliberately rather than drift.
    def rewrite_profile_for_skills
      path = File.join(dir, "profiles", "trusted.yaml")
      document = Psych.safe_load_file(path)
      snapshot = Tamoz::Tools::Skills::Compiler.new(
        sources: [Tamoz::Tools::Skills::SkillSource.new(
          id: "operator", root: File.join(dir, "skills"), trust: "operator", precedence: 0
        )]
      ).compile
      tools = document.fetch("tools").fetch("allowed")
      digest = Tamoz::Agent::Toolbox.new(
        root: workspace, allow_changes: true, checks: {},
        allowed_tools: tools, skills: snapshot
      ).catalog_digest
      document["policy"]["tool_catalog_digest"] = digest
      document["policy"]["unattended_catalog_digest"] = digest
      File.write(path, Psych.dump(document))
      File.chmod(0o600, path)
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

  def with_runtime(approval_profile: nil, budgets: nil, channels: nil, approval_ask: nil)
    Dir.mktmpdir("tamoz-autonomy") do |directory|
      runtime_dir = File.join(directory, "runtime")
      workspace = File.join(directory, "workspace")
      FileUtils.mkdir_p(workspace)
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      File.chmod(0o700, runtime_dir)

      write_config(runtime_dir, workspace, channels:, approval_profile:, approval_ask:)
      write_trusted_profile(runtime_dir, workspace, budgets:)

      runtime = Runtime.new(dir: runtime_dir, workspace:)
      runtime.client = FixtureTelegramClient.new if channels
      yield runtime
    end
  end

  # A minimal, valid operator skill on disk.
  def write_skill(root, name)
    directory = File.join(root, name)
    FileUtils.mkdir_p(directory)
    front = <<~YAML
      name: #{name}
      description: A skill used to prove where skills may come from.
      allowed-tools: [read_file]
      metadata:
        version: "1.0.0"
        tamoz.risk: guarded
    YAML
    File.write(File.join(directory, "SKILL.md"),
               "---\n#{front}---\n\nRead note.txt and report what it says.\n",
               encoding: Encoding::UTF_8)
    directory
  end

  def write_config(runtime_dir, workspace, channels: nil, approval_profile: nil, approval_ask: nil)
    document = {
      "runtime" => {"schema_version" => channels ? 2 : 1},
      "workspace" => {"root" => workspace},
      "sources" => {}
    }
    document["channels"] = channels if channels
    # What runs unattended is approval-policy data, not a profile section: the
    # operator names the policy profile (e.g. "unattended") in their config.
    if approval_ask
      policy_dir = File.join(runtime_dir, "policy")
      write_ask_policy(policy_dir, **approval_ask)
      document["approval"] = {
        "profile" => "unattended",
        "policy_path" => File.join(policy_dir, "base.yaml")
      }
    elsif approval_profile
      document["approval"] = {"profile" => approval_profile}
    end
    File.write(File.join(runtime_dir, "config.yaml"), Psych.dump(document))
    File.chmod(0o600, File.join(runtime_dir, "config.yaml"))
  end

  # The trusted profile is capability authority only: what is possible on this
  # project (`tools.allowed`), the pinned catalog, budgets. Whether a queued
  # effect asks a human first is the approval engine's policy decision.
  def write_trusted_profile(runtime_dir, workspace, budgets: nil)
    tools = READ_ONLY_TOOLS + %w[apply_patch create_file]
    allow_changes = true

    digest = Tamoz::Agent::Toolbox.new(
      root: workspace, allow_changes:, checks: {},
      allowed_tools: tools
    ).catalog_digest

    document = {
      "profile" => {
        "schema_version" => 1,
        "profile_id" => "trusted",
        "profile_version" => "1.0",
        "canonical_root" => workspace
      },
      "roots" => {"workspace" => workspace},
      "tools" => {"allowed" => tools},
      "policy" => {
        "allow_changes" => allow_changes,
        "default_check_safety" => "read_only",
        "graph_version" => "1",
        "behavior_version" => "1.0",
        "tool_catalog_digest" => digest,
        "unattended_catalog_digest" => digest
      }
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

  # The fixture CLIENT the channel cases inject through the CLI's
  # comms_client_factory seam (design §15: tests inject a fixture client rather
  # than weakening the production origin rule). It is a scripted Telegram Bot
  # API: getMe/getUpdates/sendMessage/answerCallbackQuery/getWebhookInfo, with
  # the send-ambiguity switch case 15 needs.
  class FixtureTelegramClient
    attr_reader :sent
    attr_accessor :updates, :webhook_url, :ambiguous_sends

    def initialize(bot_id: 7_463_512_990)
      @bot_id = bot_id
      @updates = []
      @sent = []
      @webhook_url = ""
      @offset = 0
      @ambiguous_sends = 0
    end

    def call(method, params, idempotent: false)
      case method
      when "getMe" then {"id" => @bot_id, "username" => "ops_bot", "is_bot" => true, "first_name" => "Ops"}
      when "getUpdates"
        taken, remaining = @updates.partition { |update| update.fetch("update_id") > @offset }
        @updates = remaining
        @offset = taken.map { |update| update.fetch("update_id") }.max || @offset
        taken
      when "sendMessage", "editMessageText"
        if @ambiguous_sends.positive?
          @ambiguous_sends -= 1
          raise Tamoz::Comms::AmbiguousDeliveryError, "fixture send timeout"
        end
        @sent << params
        {"message_id" => @sent.length, "date" => 1_752_700_800}
      when "answerCallbackQuery" then true
      when "getWebhookInfo" then {"url" => @webhook_url}
      else
        raise ArgumentError, "unexpected method #{method}"
      end
    end
  end

  # -------------------------------------------------------------- factories

  # A minimal valid policy base with one ask tier, for tests that need to pin
  # the ask deadline and its expiry outcome.
  def write_ask_policy(dir, timeout_s:, on_timeout:)
    require "fileutils"
    FileUtils.mkdir_p(File.join(dir, "profiles"))
    File.write(File.join(dir, "base.yaml"), <<~YAML)
      version: 1
      tool_tiers:
        apply_patch:
          tier: local_execute
          verb: execute
          grant_scopes: [once]
        run_check:
          tier: local_execute
          verb: execute
          grant_scopes: [once]
      fallback_tier:
        tier: read
        verb: unknown
        grant_scopes: [once]
      tiers:
        read:
          default: allow
        local_execute:
          default: ask
          grant_scopes: [once]
      grant_keys:
        local_execute: [verb, tool]
      rules: []
      evidence:
        approve: filesystem_operator
        deny: chat_bound
      simulations: []
      ask:
        timeout_s: #{timeout_s}
        on_timeout: #{on_timeout}
    YAML
    File.write(File.join(dir, "profiles", "unattended.yaml"), <<~YAML)
      profile:
        name: unattended
    YAML
  end

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
