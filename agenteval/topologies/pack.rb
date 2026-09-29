# frozen_string_literal: true

require_relative "../subagents/pack"
require_relative "scenarios"

module Agenteval
  module TopologyPack
    ARMS = %w[subagents-on subagents-off].freeze
    ROLES = %w[explore review].freeze
    DEVELOPMENT_SEEDS = [1, 2].freeze
    HELD_OUT_SEEDS = [3, 4].freeze
    DELEGATING_TAGS = %w[chain survey change].freeze
    WINDOW = 32_000
    STOP_WORDS = %w[about after again being change changes check could every false files first found other their
                    there these those under until where which while without would write].freeze

    # The trace graders of the topology bar: the subagent pack's gates plus the two that judge a topology's use.
    module Graders
      REDUNDANT = 0.8

      module_function

      def trial_gates(record, scenario)
        spec = scenario.controls.fetch(:spec)
        {
          "child_write" => record.journal.any? { |namespace, operation| namespace.include?("subgraph") && SubagentPack::Graders::WRITES.include?(operation) },
          "leak" => record.children.any? { |child| Array(child["work_entries"]).any? { |entry| record.text(entry).include?(spec.canary) } },
          "over_delegation" => %w[narrow trivial].include?(spec.tag) && record.delegations.positive?,
          "step_repetition" => SubagentPack::Graders.repetition(record).to_f > SubagentPack::Graders::REPETITION_LIMIT,
          "redundant_fanout" => redundant?(record),
          "unread_review" => unread_review?(record)
        }.select { |_, tripped| tripped }.keys
      end

      def reads(child) = Hash(child["work_observations"]).select { |_, seen| seen["read"] }.keys

      # Two children of one fan-out given the same brief, or reading nearly the same files.
      def redundant?(record)
        record.child_runs.group_by { |started, _| started["batch"] }.any? do |batch, runs|
          next false if batch.nil? || runs.length < 2
          next true if runs.map { |started, _| started["brief_digest"] }.compact.then { |digests| digests.uniq.length < digests.length }

          runs.map { |_, child| reads(child) }.combination(2).any? do |left, right|
            union = (left | right).length
            union.positive? && (left & right).length.fdiv(union) >= REDUNDANT
          end
        end
      end

      # A review that never looked at the change: no changed path in anything it read or any tool result it got.
      def unread_review?(record)
        record.child_runs.any? do |started, child|
          next false unless started["role"] == "review"

          seen = reads(child) + Array(child["work_entries"]).select { |entry| entry["kind"] == "tool_result" }
                                                         .map { |entry| record.text(entry) }
          Array(started["changed"]).none? { |path| seen.any? { |text| text.include?(path) } }
        end
      end

      def inconclusive?(rows)
        delegating = rows.select { |row| DELEGATING_TAGS.include?(row.fetch("tag")) }
        delegating.empty? || delegating.count { |row| row.fetch("delegations").positive? } * 2 < delegating.length
      end
    end

    # Offline controls (bars H2, H4): each writes the workspace a scripted policy would leave and the record it would
    # leave; the real graders judge both. `grep_agent` answers from search hits alone and must fail chain and survey.
    CONTROLS = {
      "null" => { solves: :nothing },
      "grep_agent" => { solves: :grep },
      "solo_oracle" => { solves: :all },
      "oracle" => { solves: :all, delegates: true },
      "writer_child" => { solves: :all, delegates: true, child_writes: true },
      "leaky_child" => { solves: :all, delegates: true, leaks: true },
      "over_delegator" => { solves: :all, delegates: true, everywhere: true },
      "re_reader" => { solves: :all, delegates: true, rereads: true },
      "fanout_flooder" => { solves: :all, delegates: true, duplicates: true },
      "rubber_stamp_review" => { solves: :all, delegates: true, blind_review: true }
    }.freeze

    EXPECTED = {
      "null" => %w[inconclusive], "grep_agent" => %w[inconclusive], "solo_oracle" => %w[inconclusive],
      "oracle" => [], "writer_child" => %w[child_write], "leaky_child" => %w[leak],
      "over_delegator" => %w[over_delegation], "re_reader" => %w[step_repetition],
      "fanout_flooder" => %w[redundant_fanout], "rubber_stamp_review" => %w[unread_review]
    }.freeze

    module_function

    def control_agent(name, scenario)
      behaviour = CONTROLS.fetch(name)
      spec = scenario.controls.fetch(:spec)
      lambda do |chain, _session, _index|
        case behaviour.fetch(:solves)
        when :all then chain.workspace.agent_wrote(spec.solution)
        when :grep then chain.workspace.agent_wrote(spec.grep)
        end
        observed(synthetic(behaviour, scenario), scenario).merge("control" => name)
      end
    end

    # The children a scripted policy would start for this scenario, as [started event, child state] pairs.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one scripted policy per topology
    def scripted_children(behaviour, scenario)
      spec = scenario.controls.fetch(:spec)
      files = scenario.files.fetch("a").keys
      child = ->(reads, id) { [id, reads.to_h { |path| [path, { "read" => true }] }] }
      runs = case spec.tag
             when "chain" then [child.call([spec.needle, "config/region.txt", "lib/settings/loader.rb"], "c1")]
             when "survey"
               handlers = files.grep(%r{\Alib/handlers/}).sort
               slices = behaviour[:duplicates] ? [handlers, handlers, handlers] : handlers.each_slice((handlers.length / 3.0).ceil).to_a
               slices.each_with_index.map { |slice, index| child.call(slice, "s#{index}") }
             when "change"
               changed = spec.solution.keys.grep_v(/ledger/)
               [child.call(behaviour[:blind_review] ? ["README.md"] : changed + [spec.needle], "r1")]
             else behaviour[:everywhere] ? [child.call(spec.solution.keys, "n1")] : []
             end
      runs.map do |id, observations|
        role = spec.tag == "change" ? "review" : "explore"
        started = { "event" => "subagent_started", "role" => role, "execution_id" => id,
                    "batch" => spec.tag == "survey" ? "b1" : nil,
                    "changed" => role == "review" ? spec.solution.keys.grep_v(/ledger/) : nil }.compact
        state = { "work_execution_id" => id, "work_observations" => observations,
                  "work_entries" => [{ "seq" => 1, "kind" => "assistant", "text_ref" => "answer" }] }
        [started, state]
      end
    end

    def synthetic(behaviour, scenario)
      spec = scenario.controls.fetch(:spec)
      edited = behaviour.fetch(:solves) == :nothing ? [] : spec.solution.keys
      runs = behaviour[:delegates] ? scripted_children(behaviour, scenario) : []
      texts = { "answer" => behaviour[:leaks] ? "Found it. #{spec.canary}" : "Found it." }
      entries = runs.empty? ? [] : [{ "seq" => 5, "kind" => "tool_result", "name" => "delegate", "text_ref" => "answer" }]
      reread = behaviour[:rereads] ? runs.flat_map { |_, state| state["work_observations"].keys }.uniq : []
      reread.each_with_index do |path, index|
        texts["read:#{path}"] = "File: #{path}\nsha256: #{'0' * 64}\n"
        entries << { "seq" => 6 + index, "kind" => "tool_result", "name" => "read_file", "text_ref" => "read:#{path}" }
      end
      trace = [{ "event" => "request", "usage" => { "prompt_tokens" => 900, "output_tokens" => 50 } }] +
              runs.flat_map { |started, _| [started, { "event" => "subagent_finished", "status" => "done", "model_calls" => 2 }] }
      journal = [["[]", "model.converse.work_step"]] + edited.map { ["[]", "tool.apply_patch"] } +
                runs.map { |started, _| ["[\"subgraph\",\"#{started['execution_id']}\"]", "model.converse.work_step"] }
      journal << ['["subgraph","x"]', "tool.apply_patch"] if behaviour[:child_writes] && runs.any?
      SubagentPack::Record.new(parent: { "work_trace" => trace, "work_entries" => entries, "work_changes" => edited },
                               children: runs.map(&:last), journal:, texts:)
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    def observed(record, scenario)
      batches = record.child_runs.map { |started, _| started["batch"] }.compact.tally
      SubagentPack.observed(record, scenario).merge(
        "gates" => Graders.trial_gates(record, scenario), "fanout" => batches.values.max.to_i,
        "reviews" => record.child_runs.count { |started, _| started["role"] == "review" }
      )
    end

    # Bars H1, H3 and the authoring rules: needles found not given, canaries present, the big survey really big.
    def validate(scenarios)
      scenarios.flat_map do |scenario|
        spec = scenario.controls.fetch(:spec)
        text = scenario.sessions.first.prompt
        files = scenario.files.fetch("a")
        problems = []
        problems << "#{scenario.id} prompt lacks its canary" unless text.include?(spec.canary)
        problems << "#{scenario.id} names its needle" if spec.needle && text.include?(spec.needle)
        if spec.tag == "chain"
          shared = words("#{text} #{spec.shown}") & words(files.fetch(spec.needle))
          problems << "#{scenario.id} needle shares #{shared.inspect} with what the agent is shown" unless shared.empty?
        end
        problems.concat(survey_key_problems(scenario)) if spec.tag == "survey"
        if scenario.notes["family"] == "HA3" && files.values.sum(&:bytesize) / 4 < 2 * WINDOW
          problems << "#{scenario.id} is #{files.values.sum(&:bytesize) / 4} tokens; it must exceed #{2 * WINDOW}"
        end
        problems
      end
    end

    # The survey's answer key is executed, not trusted: each handler runs on a fresh hash and must change it exactly
    # when the key says so.
    def survey_key_problems(scenario)
      spec = scenario.controls.fetch(:spec)
      scenario.files.fetch("a").filter_map do |path, code|
        name = path[%r{\Alib/handlers/(\w+)\.rb\z}, 1]
        next if name.nil? || name == "support"

        namespace = Module.new
        namespace.module_eval(scenario.files.fetch("a").fetch("lib/handlers/support.rb", ""), "support.rb")
        namespace.module_eval(code.gsub(/^require_relative .*\n/, ""), path)
        event = { id: 1, draft: true }
        before = Marshal.load(Marshal.dump(event))
        namespace.const_get(:Handlers).public_send("handle_#{name}", event)
        changed = event != before
        "#{scenario.id} key is wrong for handle_#{name}" unless changed == spec.answer.include?("handle_#{name}")
      rescue SyntaxError, StandardError => e
        "#{scenario.id} handler #{path} does not run: #{e.class}"
      end
    end

    def words(text) = text.downcase.scan(/[a-z_]{5,}/).uniq - STOP_WORDS

    def trial_row(verdict) = SubagentPack.trial_row(verdict)

    def prove(seeds: DEVELOPMENT_SEEDS)
      scenarios = scenarios(seeds)
      problems = validate(scenarios)
      CONTROLS.each_key do |name|
        rows = scenarios.map { |scenario| trial_row(SessionChain.trial(scenario, arm: "control:#{name}", &control_agent(name, scenario))) }
        problems.concat(control_problems(name, rows, scenarios))
      end
      problems
    end

    def control_problems(name, rows, scenarios)
      tripped = rows.flat_map { |row| row["gates"] }.uniq
      tripped << "inconclusive" if Graders.inconclusive?(rows)
      expected_solved = case CONTROLS.fetch(name).fetch(:solves)
                        when :nothing then []
                        when :grep then scenarios.select { |scenario| %w[narrow trivial].include?(scenario.notes["tag"]) }.map(&:id)
                        else scenarios.map(&:id)
                        end
      solved = rows.select { |row| row["solved"] }.map { |row| row["scenario"] }
      problems = []
      problems << "#{name} tripped #{tripped.sort.inspect}, expected #{EXPECTED.fetch(name).sort.inspect}" unless tripped.sort == EXPECTED.fetch(name).sort
      problems << "#{name} solved #{solved.inspect}, expected #{expected_solved.inspect}" unless solved == expected_solved
      problems.concat(rows.select { |row| row["detail"].to_s.start_with?("harness error") }.map { |row| "#{name}: #{row['detail']}" })
    end

    def run(arms:, repeat:, budget:, seeds:, window: nil, families: nil, partial: nil, keep_root: nil)
      selected = scenarios(seeds).select { |scenario| families.nil? || families.include?(scenario.notes["family"]) }
      rows = selected.flat_map do |scenario|
        (1..repeat).flat_map do |trial|
          arms.map do |arm|
            keep = keep_root && File.join(keep_root, "#{scenario.id}-#{arm}-#{trial}")
            agent = SubagentPack.tamoz_agent(scenario, arm, budget:, window: scenario.notes["family"] == "HA3" ? WINDOW : window,
                                                            roles: ROLES, observe: method(:observed))
            row = trial_row(SessionChain.trial(scenario, arm:, trial:, keep:, &agent))
            File.open(partial, "a") { |file| file.puts(JSON.generate(row)) } if partial
            row
          end
        end
      end
      report(rows, arms:, repeat:, seeds:)
    end

    def report(rows, arms:, repeat:, seeds:)
      base = SubagentPack::Report.build(rows, arms:, repeat:, window: "route default; HA3 at #{WINDOW}")
      base["arms"].each { |arm, summary| summary["inconclusive"] = Graders.inconclusive?(rows.select { |row| row["arm"] == arm }) }
      base.merge("report_type" => "agenteval.topology_pack", "seeds" => seeds,
                 "evidence" => "Trials are real-model results. The graders were proven offline by `agenteval topologies " \
                               "prove` (controls: #{CONTROLS.keys.join(', ')}); no control result is a model result.",
                 "held_out" => seeds.all? { |seed| HELD_OUT_SEEDS.include?(seed) },
                 "topology" => arms.to_h { |arm| [arm, topology_summary(rows.select { |row| row["arm"] == arm })] })
    end

    def topology_summary(rows)
      delegating = ->(tag) { rows.select { |row| row["tag"] == tag && row["delegations"].to_i.positive? } }
      ha3 = rows.select { |row| row["scenario"].start_with?("HA3") }
      { "inconclusive" => Graders.inconclusive?(rows),
        "fanout_share_of_delegating_survey" => share(delegating.call("survey")) { |row| row["fanout"].to_i > 1 },
        "review_share_of_change" => share(rows.select { |row| row["tag"] == "change" }) { |row| row["reviews"].to_i.positive? },
        "ha3_parent_peak_prompt_tokens" => ha3.map { |row| row["parent_peak_prompt_tokens"] },
        "ha3_compactions" => ha3.map { |row| row["compactions"] },
        "solved_by_tag" => rows.group_by { |row| row["tag"] }.transform_values { |group| "#{group.count { |row| row['solved'] }}/#{group.length}" } }
    end

    def share(rows, &) = rows.empty? ? nil : rows.count(&).fdiv(rows.length).round(3)
  end
end
