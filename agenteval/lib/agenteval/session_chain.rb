# frozen_string_literal: true

require "fileutils"
require "json"
require "psych"
require "sqlite3"
require "tmpdir"

module Agenteval
  # Several sessions against the same workspaces and one memory store, judged after the
  # last one (docs/memory-next-level-2026-09-28/EVAL.md §3). Each session is a separate
  # `tamoz code` thread, so nothing carries between them except what memory kept — and
  # whatever the agent chose to write into the workspace, which is part of the behaviour
  # being measured. Memory lives in the chain's one runtime database, as it does for the worker.
  module SessionChain
    ARMS = %w[memory-on memory-off].freeze

    # One step of a chain: the prompt and which project workspace it runs in.
    Session = Data.define(:prompt, :project) do
      def initialize(prompt:, project: "a") = super
    end

    Scenario = Data.define(:id, :title, :kind, :files, :check, :sessions, :oracle, :gate, :controls, :notes) do
      def initialize(id:, title:, kind:, files:, sessions:, oracle:, check: nil, gate: nil, controls: {}, notes: {})
        super
      end
    end

    # What the judge can see: each project's workspace and the memory store.
    class Chain
      attr_reader :root, :workspaces, :session_dir, :runtime_dir, :runs

      def initialize(root, scenario)
        @root = root
        @session_dir = File.join(root, "sessions")
        @runtime_dir = File.join(root, "runtime")
        FileUtils.mkdir_p(@session_dir, mode: 0o700)
        FileUtils.mkdir_p(@runtime_dir, mode: 0o700)
        @workspaces = scenario.files.to_h do |project, files|
          workspace = Workspace.new(File.join(root, "project-#{project}"))
          workspace.materialize(files)
          [project, workspace]
        end
        @runs = []
      end

      def workspace(project = "a") = @workspaces.fetch(project)
      def read(path, project: "a") = workspace(project).read(path)
      def memory_path = File.join(@runtime_dir, 'runtime.sqlite3')

      # Every Knowledge statement version the store holds, whatever its state. Plain SQLite,
      # so the judge does not depend on the agent's own code to say what it stored.
      def knowledge_texts = store_rows("key LIKE 'knowledge/%'").map(&:first)
      def memory_record_count = store_rows("1 = 1").length

      def store_rows(condition)
        return [] unless File.exist?(memory_path)

        database = SQLite3::Database.new(memory_path, readonly: true)
        database.execute("SELECT CAST(payload AS TEXT), key FROM tamoz_store_versions " \
                         "WHERE namespace LIKE 'tamoz.memory.%' AND #{condition}")
      ensure
        database&.close
      end
    end

    Verdict = Data.define(:scenario, :arm, :trial, :solved, :gate, :detail, :sessions, :memory_records, :kept) do
      def to_h
        { "scenario" => scenario, "arm" => arm, "trial" => trial, "solved" => solved, "gate" => gate,
          "detail" => detail, "sessions" => sessions, "memory_records" => memory_records, "kept" => kept }
      end
    end

    module_function

    # Runs one scenario with an agent (called with chain, session, index; returns the session
    # record) and judges it. The same path serves real agents and controls. `keep` copies the
    # chain (workspaces, session stores) there so a failure can be read afterwards.
    def trial(scenario, arm:, trial: 1, keep: nil, &agent)
      Dir.mktmpdir("agenteval-memory") do |root|
        chain = Chain.new(root, scenario)
        begin
          scenario.sessions.each_with_index { |session, index| chain.runs << agent.call(chain, session, index) }
          judge(scenario, chain, arm:, trial:, kept: keep && preserve(root, keep))
        rescue StandardError => e
          Verdict.new(scenario: scenario.id, arm:, trial:, solved: false, gate: nil,
                      detail: "harness error: #{e.class}: #{e.message}"[0, 400], sessions: chain.runs,
                      memory_records: chain.memory_record_count, kept: keep && preserve(root, keep))
        end
      end
    end

    def judge(scenario, chain, arm:, trial:, kept:)
      result = scenario.oracle.call(chain)
      gate = scenario.gate&.call(chain)
      Verdict.new(scenario: scenario.id, arm:, trial:, solved: result.ok && (gate.nil? || gate.ok),
                  gate: gate && (gate.ok ? "pass" : "tripped"), detail: [result.detail, gate&.detail].compact.join("; "),
                  sessions: chain.runs, memory_records: chain.memory_record_count, kept:)
    end

    def preserve(root, target)
      FileUtils.rm_rf(target)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp_r(root, target)
      target
    end

    # The runtime directory every `tamoz code` session of a chain reads; `--root` scopes each project's memory.
    # Memory is on only in the memory-on arm.
    def runtime_dir(chain, arm)
      dir = chain.runtime_dir
      sources = arm == "memory-on" ? { "memory" => { "enabled" => true, "tenant" => "eval", "owner" => "eval-user" } } : {}
      config = { "runtime" => { "schema_version" => 2 }, "workspace" => { "root" => chain.root }, "sources" => sources }
      File.write(File.join(dir, "config.yaml"), Psych.dump(config))
      File.chmod(0o600, File.join(dir, "config.yaml"))
      dir
    end

    # What one session did, read from its thread's final checkpoint: tool calls by name and
    # the memory brief's recorded cost. The state is Tamoz's tagged encoding, decoded here.
    def session_metrics(chain, thread)
      path = File.join(chain.session_dir, "#{thread}.sqlite3")
      return {} unless File.exist?(path)

      database = SQLite3::Database.new(path, readonly: true)
      row = database.execute("SELECT CAST(payload AS TEXT) FROM tamoz_checkpoints ORDER BY sequence DESC LIMIT 1").first
      row ? metrics_of(decode_state(row.first)) : {}
    ensure
      database&.close
    end

    def metrics_of(state)
      tools = Array(state["work_entries"]).select { |entry| entry["kind"] == "tool_result" && !entry["replaces"] }
                                          .map { |entry| entry["name"] }
      injected = Array(state["work_trace"]).select { |event| event["event"] == "memory_injected" }
      { "terminal_reason" => state["terminal_reason"], "tool_calls" => tools.length, "tools" => tools.tally,
        "memory_tokens_injected" => injected.sum { |event| event["tokens"].to_i },
        "memory_records_injected" => injected.sum { |event| Array(event["ids"]).length } }
    end

    def decode_state(payload)
      envelope = JSON.parse(payload)
      state = envelope.find { |part| part.is_a?(String) && part.start_with?('["tamoz.state"') }
      state ? untag(JSON.parse(state).last) : {}
    end

    def untag(value)
      tag, body = value
      case tag
      when "object" then body.to_h { |key, item| [key, untag(item)] }
      when "array" then body.map { |item| untag(item) }
      when "nil" then nil
      else body
      end
    end
  end
end
