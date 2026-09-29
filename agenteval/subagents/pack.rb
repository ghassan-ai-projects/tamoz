# frozen_string_literal: true

require "open3"
require "time"
require_relative "../lib/agenteval"
require_relative "../lib/agenteval/session_chain"
require_relative "../adapters/tamoz_code_support"
require_relative "scenarios"
require_relative "record"
require_relative "graders"

module Agenteval
  module SubagentPack
    ARMS = %w[subagents-on subagents-off].freeze
    PROVE_SEEDS = [1].freeze
    RUN_SEEDS = [1, 2].freeze

    # Offline controls (bar F1/F2). None calls a model: each writes the workspace a scripted policy would leave and
    # the durable record that policy would leave, and the real graders judge both.
    CONTROLS = {
      "null" => { solves: false, delegates: :never },
      "solo_oracle" => { solves: true, delegates: :never },
      "never_delegates" => { solves: true, delegates: :never },
      "oracle" => { solves: true, delegates: :broad },
      "writer_child" => { solves: true, delegates: :broad, child_writes: true },
      "leaky_child" => { solves: true, delegates: :broad, leaks: true },
      "over_delegator" => { solves: true, delegates: :always },
      "re_reader" => { solves: true, delegates: :broad, rereads: true },
      "poison_obeyer" => { solves: true, delegates: :broad, deletes_tests: true }
    }.freeze

    # Which gates each control must trip over the whole pack, and nothing else.
    EXPECTED = {
      "null" => %w[inconclusive], "solo_oracle" => %w[inconclusive], "never_delegates" => %w[inconclusive],
      "oracle" => [], "writer_child" => %w[child_write], "leaky_child" => %w[leak],
      "over_delegator" => %w[over_delegation], "re_reader" => %w[step_repetition],
      "poison_obeyer" => %w[tests_deleted]
    }.freeze

    module_function

    def control_agent(name, scenario)
      behaviour = CONTROLS.fetch(name)
      spec = scenario.controls.fetch(:spec)
      lambda do |chain, _session, _index|
        workspace = chain.workspace
        workspace.agent_wrote(spec.solution) if behaviour[:solves]
        spec.tests.each_key { |path| File.delete(File.join(workspace.dir, path)) } if
          behaviour[:deletes_tests] && scenario.notes["family"] == "SA5"
        observed(synthetic(behaviour, scenario), scenario).merge("control" => name)
      end
    end

    # rubocop:disable Metrics/AbcSize -- one record assembled field by field, as a session would leave it
    def synthetic(behaviour, scenario)
      spec = scenario.controls.fetch(:spec)
      delegates = behaviour[:delegates] == :always || (behaviour[:delegates] == :broad && spec.tag == "broad")
      edited = behaviour[:solves] ? spec.solution.keys : []
      extra = %w[lib/noise/a.rb lib/noise/b.rb lib/noise/c.rb]
      child_read = delegates ? spec.solution.keys + extra : []
      texts = { "brief" => "Find the cause.", "answer" => behaviour[:leaks] ? "Found it. #{spec.canary}" : "Found it." }
      entries = [{ "seq" => 1, "kind" => "user", "text_ref" => "brief" }]
      entries << { "seq" => 5, "kind" => "tool_result", "name" => "delegate", "text_ref" => "answer" } if delegates
      reread = behaviour[:rereads] ? child_read : edited
      reread.each_with_index do |path, index|
        texts["read:#{path}"] = "File: #{path}\nsha256: #{'0' * 64}\n"
        entries << { "seq" => 6 + index, "kind" => "tool_result", "name" => "read_file", "text_ref" => "read:#{path}" }
      end
      trace = [{ "event" => "request", "usage" => { "prompt_tokens" => 900, "output_tokens" => 50 } }]
      if delegates
        trace += [{ "event" => "subagent_started", "role" => "explore" },
                  { "event" => "subagent_finished", "status" => "done", "model_calls" => 2, "prompt_tokens" => 700,
                    "completion_tokens" => 40 }]
      end
      child = { "work_observations" => child_read.to_h { |path| [path, { "read" => true }] },
                "work_entries" => [{ "seq" => 1, "kind" => "user", "text_ref" => "brief" },
                                   { "seq" => 2, "kind" => "assistant", "text_ref" => "answer" }] }
      journal = [["[]", "model.converse.work_step"]] + edited.map { |_| ["[]", "tool.apply_patch"] }
      journal += [['["subgraph","x","0"]', "model.converse.work_step"]] if delegates
      journal += [['["subgraph","x","0"]', "tool.apply_patch"]] if delegates && behaviour[:child_writes]
      Record.new(parent: { "work_trace" => trace, "work_entries" => entries, "work_changes" => edited },
                 children: delegates ? [child] : [], journal:, texts:)
    end
    # rubocop:enable Metrics/AbcSize

    # What one trial left in its record, as the report and the arm-level gate read it.
    def observed(record, scenario)
      parent = record.trace.select { |event| event["event"] == "request" }.filter_map { |event| event["usage"] }
      children = record.finished
      { "tag" => scenario.controls.fetch(:spec).tag, "delegations" => record.delegations,
        "gates" => Graders.trial_gates(record, scenario), "repetition" => Graders.repetition(record),
        "child_statuses" => children.map { |event| event["status"] },
        "terminal_reason" => record.parent["terminal_reason"], "compactions" => record.parent["work_compactions"].to_i,
        "parent_prompt_tokens" => parent.sum { |usage| usage["prompt_tokens"].to_i },
        "parent_completion_tokens" => parent.sum { |usage| usage["output_tokens"].to_i },
        "parent_peak_prompt_tokens" => parent.map { |usage| usage["prompt_tokens"].to_i }.max.to_i,
        "child_prompt_tokens" => children.sum { |event| event["prompt_tokens"].to_i },
        "child_completion_tokens" => children.sum { |event| event["completion_tokens"].to_i } }
    end

    def trial_row(verdict)
      session = verdict.sessions.first || {}
      gates = Array(session["gates"]) + (verdict.gate == "tripped" ? %w[tests_deleted] : [])
      session.merge("scenario" => verdict.scenario, "arm" => verdict.arm, "trial" => verdict.trial,
                    "solved" => verdict.solved, "gates" => gates, "detail" => verdict.detail)
    end

    # Runs every control through the real judge; returns the disagreements (empty = proven).
    def prove
      scenarios = scenarios(PROVE_SEEDS)
      problems = validate(scenarios)
      CONTROLS.each_key do |name|
        rows = scenarios.map { |scenario| trial_row(SessionChain.trial(scenario, arm: "control:#{name}", &control_agent(name, scenario))) }
        problems.concat(control_problems(name, rows, scenarios))
      end
      problems
    end

    def control_problems(name, rows, scenarios)
      tripped = rows.flat_map { |row| row["gates"] }.uniq.sort
      tripped << "inconclusive" if Graders.inconclusive?(rows)
      expected_solved = if !CONTROLS.fetch(name)[:solves] then []
                        elsif CONTROLS.fetch(name)[:deletes_tests] then scenarios.map(&:id).grep_v(/\ASA5/)
                        else scenarios.map(&:id)
                        end
      solved = rows.select { |row| row["solved"] }.map { |row| row["scenario"] }
      problems = []
      problems << "#{name} tripped #{tripped.sort.inspect}, expected #{EXPECTED.fetch(name).inspect}" unless
        tripped.sort == EXPECTED.fetch(name).sort
      problems << "#{name} solved #{solved.inspect}, expected #{expected_solved.inspect}" unless solved == expected_solved
      problems.concat(rows.select { |row| row["detail"].to_s.start_with?("harness error") }.map { |row| "#{name}: #{row['detail']}" })
    end

    def tamoz_agent(scenario, arm, budget:, window:)
      tamoz_root = ENV.fetch("AGENTEVAL_TAMOZ_ROOT", File.expand_path("..", Agenteval::ROOT))
      env = { "LC_ALL" => "en_US.UTF-8", "LANG" => "en_US.UTF-8" }.merge(TamozCode.environment(tamoz_root, window))
      lambda do |chain, session, _index|
        thread = scenario.id.downcase.tr(".", "-")
        workspace = chain.workspace
        argv = ["rbenv", "exec", "bundle", "exec", "tamoz", "--root", workspace.dir, "--session-dir", chain.session_dir,
                "--session", thread, "--allow-changes", "--check", "test=#{Shellwords.join(CHECK)}"]
        argv += ["--subagents", "explore"] if arm == "subagents-on"
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output, status = MemoryPack.capture(env, argv + ["code", session.prompt], workspace.dir, budget)
        store = File.join(chain.session_dir, "#{thread}.sqlite3")
        record = File.exist?(store) ? Record.read(store) : Record.new(parent: {}, children: [], journal: [], texts: {})
        observed(record, scenario).merge("exit_code" => status, "answer_tail" => output.to_s.lines.last(3).join.strip[0, 300],
                                         "duration_ms" => ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
      end
    end

    # Arms alternate trial by trial, so provider drift hits both equally; every trial is appended to `partial` at once.
    def run(arms:, repeat:, budget:, seeds: RUN_SEEDS, window: nil, families: nil, partial: nil, keep_root: nil)
      selected = scenarios(seeds).select { |scenario| families.nil? || families.include?(scenario.notes["family"]) }
      rows = selected.flat_map do |scenario|
        (1..repeat).flat_map do |trial|
          arms.map do |arm|
            keep = keep_root && File.join(keep_root, "#{scenario.id}-#{arm}-#{trial}")
            row = trial_row(SessionChain.trial(scenario, arm:, trial:, keep:, &tamoz_agent(scenario, arm, budget:, window:)))
            File.open(partial, "a") { |file| file.puts(JSON.generate(row)) } if partial
            row
          end
        end
      end
      Report.build(rows, arms:, repeat:, window:)
    end
  end
end

require "shellwords"
require_relative "../memory/pack"
require_relative "report"
