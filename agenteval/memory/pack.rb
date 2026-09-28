# frozen_string_literal: true

require "open3"
require "shellwords"
require "time"
require_relative "../lib/agenteval"
require_relative "../lib/agenteval/session_chain"
require_relative "../adapters/tamoz_code_support"
require_relative "scenarios"

module Agenteval
  module MemoryPack
    # Offline control agents (bars F2/F3). None calls a model. `oracle` and `amnesiac_oracle`
    # run the SAME scripted policy and differ only in whether they keep a memory, so a
    # scenario the amnesiac fails is one its oracle cannot pass without memory.
    CONTROLS = {
      "null" => { acts: false, remembers: false },
      "amnesiac_oracle" => { acts: true, remembers: false },
      "oracle" => { acts: true, remembers: true },
      "poison_obeyer" => { acts: true, remembers: true, poison: true },
      "scope_leaker" => { acts: true, remembers: true, unscoped: true }
    }.freeze

    EXPECTED = {
      "null" => [],
      "amnesiac_oracle" => %w[MP5],
      "oracle" => %w[MP1 MP2 MP3 MP5 MP6],
      "poison_obeyer" => %w[MP1 MP2 MP3 MP6],
      "scope_leaker" => %w[MP1 MP2 MP3 MP5]
    }.freeze

    CONTROL_NAMESPACE = "tamoz.memory.control"

    module_function

    def control_agent(name, scenario)
      behaviour = CONTROLS.fetch(name)
      lambda do |chain, session, index|
        project = session.project
        if behaviour[:acts]
          memory = control_memory(chain, behaviour[:unscoped] ? nil : project)
          chain.workspace(project).agent_wrote(scenario.controls.fetch(:act).fetch(index).call(memory))
        end
        kept = behaviour[:remembers] ? Array(scenario.controls.dig(:remember, index)) : []
        kept += [PLANTED] if behaviour[:poison] && index.zero?
        keep(chain, kept, project)
        { "session" => index + 1, "control" => name }
      end
    end

    # A control's memory, in the table and key shape the judge reads.
    def keep(chain, statements, project)
      return if statements.empty?

      with_control_store(chain) do |database|
        statements.each do |text|
          database.execute("INSERT INTO tamoz_store_versions VALUES (?, ?, ?)",
                           [CONTROL_NAMESPACE, "knowledge/#{text.hash.abs}", JSON.generate("statement" => text, "project" => project)])
        end
      end
    end

    def control_memory(chain, project)
      return [] unless File.exist?(chain.memory_path)

      with_control_store(chain) do |database|
        database.execute("SELECT payload FROM tamoz_store_versions").map { |(payload)| JSON.parse(payload) }
                .select { |row| project.nil? || row["project"] == project }.map { |row| row["statement"] }
      end
    end

    def with_control_store(chain)
      database = SQLite3::Database.new(chain.memory_path)
      database.execute("CREATE TABLE IF NOT EXISTS tamoz_store_versions (namespace TEXT, key TEXT, payload TEXT)")
      yield database
    ensure
      database&.close
    end

    # Runs every control through the real judge; returns the disagreements (empty = proven).
    def prove
      problems = validate
      CONTROLS.each_key do |name|
        verdicts = SCENARIOS.map { |scenario| SessionChain.trial(scenario, arm: "control:#{name}", &control_agent(name, scenario)) }
        solved = verdicts.select(&:solved).map(&:scenario)
        expected = EXPECTED.fetch(name)
        problems << "#{name} solved #{solved.inspect}, expected #{expected.inspect}" unless solved == expected
      end
      problems
    end

    def tamoz_agent(scenario, arm, budget:)
      tamoz_root = ENV.fetch("AGENTEVAL_TAMOZ_ROOT", File.expand_path("..", Agenteval::ROOT))
      env = { "LC_ALL" => "en_US.UTF-8", "LANG" => "en_US.UTF-8" }
            .merge(TamozCode.environment(tamoz_root, ENV.fetch("AGENTEVAL_CONTEXT_WINDOW", nil)))
      lambda do |chain, session, index|
        thread = "#{scenario.id.downcase}-s#{index + 1}"
        workspace = chain.workspace(session.project)
        argv = ["rbenv", "exec", "bundle", "exec", "tamoz", "--root", workspace.dir, "--session-dir", chain.session_dir,
                "--runtime-dir", SessionChain.runtime_dir(chain, session.project, arm), "--session", thread,
                "--allow-changes", "--check", "test=#{Shellwords.join(scenario.check)}", "code", session.prompt]
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output, status = capture(env, argv, workspace.dir, budget)
        { "session" => index + 1, "exit_code" => status,
          "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
          "answer_tail" => output.to_s.lines.last(3).join.strip[0, 300],
          **SessionChain.session_metrics(chain, thread) }
      end
    end

    def capture(env, argv, dir, budget)
      Open3.popen2e(env, *argv, chdir: dir, pgroup: true) do |stdin, stream, waiter|
        stdin.write("y\n" * 200)
        stdin.close
        reader = Thread.new { stream.read.to_s }
        unless waiter.join(budget)
          begin
            Process.kill("KILL", -Process.getpgid(waiter.pid))
          rescue Errno::ESRCH
            nil
          end
          return ["[agenteval] killed at the #{budget}s budget", nil]
        end
        [reader.value.force_encoding(Encoding::UTF_8).scrub("?"), waiter.value.exitstatus]
      end
    end

    # Each finished trial is appended to `partial` at once, so an interrupted paid run keeps
    # what it paid for; each chain is kept under `keep_root` for reading afterwards.
    def run(arms:, repeat:, budget:, partial: nil, keep_root: nil)
      unknown = arms - SessionChain::ARMS
      raise ArgumentError, "unknown arms #{unknown.inspect}; one of #{SessionChain::ARMS.inspect}" unless unknown.empty?

      verdicts = arms.flat_map do |arm|
        SCENARIOS.flat_map do |scenario|
          (1..repeat).map do |trial|
            keep = keep_root && File.join(keep_root, "#{scenario.id}-#{arm}-#{trial}")
            verdict = SessionChain.trial(scenario, arm:, trial:, keep:, &tamoz_agent(scenario, arm, budget:))
            File.open(partial, "a") { |file| file.puts(JSON.generate(verdict.to_h)) } if partial
            verdict
          end
        end
      end
      report(verdicts, arms:, repeat:)
    end

    def report(verdicts, arms:, repeat:)
      {
        "report_type" => "agenteval.memory_pack", "generated_at" => Time.now.utc.iso8601,
        "provider" => TamozCode.provider, "model" => TamozCode.provider_model, "repeat" => repeat,
        "evidence" => "Trials are real-model results. The graders were proven offline by `agenteval memory prove` " \
                      "(controls: #{CONTROLS.keys.join(', ')}); no control result is a model result.",
        "limits" => ["memory-off has no memory store, so its storage gate cannot trip; its zero is by construction",
                     "#{SCENARIOS.length} scenarios: every arm difference is a finding, not a significance claim"],
        "arms" => arms.to_h { |arm| [arm, summary(verdicts.select { |verdict| verdict.arm == arm })] },
        "trials" => verdicts.map(&:to_h)
      }
    end

    def summary(verdicts)
      by_scenario = verdicts.group_by(&:scenario)
      sessions = verdicts.flat_map(&:sessions)
      tokens = sessions.filter_map { |session| session["memory_tokens_injected"] }.sort
      {
        "scenarios_solved_every_trial" => by_scenario.count { |_id, trials| trials.all?(&:solved) },
        "scenarios" => by_scenario.length,
        "solved_trials" => verdicts.count(&:solved), "trials" => verdicts.length,
        "hard_gate_trips" => verdicts.count { |verdict| verdict.gate == "tripped" },
        "harness_errors" => verdicts.count { |verdict| verdict.detail.start_with?("harness error") },
        "per_scenario" => by_scenario.transform_values { |trials| trials.map(&:solved) },
        "tool_calls" => sessions.sum { |session| session["tool_calls"].to_i },
        "memory_tool_calls" => sessions.each_with_object(Hash.new(0)) do |session, counts|
          Hash(session["tools"]).slice("recall_memory", "remember", "forget").each { |name, n| counts[name] += n }
        end,
        "memory_tokens_injected_p50_p95" => [percentile(tokens, 0.5), percentile(tokens, 0.95)]
      }
    end

    def percentile(sorted, fraction) = sorted.empty? ? nil : sorted[((sorted.length - 1) * fraction).round]
  end
end
