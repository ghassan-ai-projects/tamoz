# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "psych"
require "rbconfig"
require "tmpdir"
require_relative "graders"
require_relative "judge"

module Agenteval
  module Research
    # The deep-research pack (docs/deep-research-2026-09-30/EVAL.md): offline controls that prove the graders
    # discriminate, and real runs of `tamoz deep-research` in two arms under a hard cap on Brave requests.
    module Pack
      ROOT = File.expand_path("../..", __dir__)
      HERE = __dir__
      QUESTIONS = File.join(HERE, "questions.json")
      LEDGER = File.join(HERE, "brave_ledger.json")
      CAP = 500
      SEARCHES_PER_RUN = 15
      ARMS = {
        "fanout" => { "ceilings" => { "searches" => SEARCHES_PER_RUN } },
        "single" => { "ceilings" => { "searches" => SEARCHES_PER_RUN, "children_per_wave" => 1 } }
      }.freeze
      # The plan checkpoint is answered by the runner, not a person; reports say so.
      PLAN_REPLY = "go"
      EGRESS = { "allowlisted_hosts" => ["api.search.brave.com"], "schemes" => ["https"], "deny_private_ranges" => true,
                 "max_request_bytes" => 2048, "max_response_bytes" => 65_536, "connect_timeout_s" => 10,
                 "redirect_max_hops" => 3,
                 "circuit" => { "threshold" => 3, "scope_type" => "egress", "budget_breach" => true },
                 "credential_refs" => ["TAMOZ_BRAVE_API_KEY"], "page_reads" => "public" }.freeze
      ADAPTER_ENV = %w[PATH HOME LANG LC_ALL TAMOZ_WEBSEARCH_GRANT TAMOZ_WEBSEARCH_EGRESS TAMOZ_WEBSEARCH_PROVIDER
                       TAMOZ_WEBSEARCH_LEDGER TAMOZ_WEBSEARCH_CACHE].freeze

      module_function

      def questions(set = nil)
        all = JSON.parse(File.read(QUESTIONS)).fetch("questions")
        set ? all.select { |question| question.fetch("set") == set } : all
      end

      def ledger
        File.write(LEDGER, JSON.generate("cap" => CAP, "used" => 0)) unless File.exist?(LEDGER)
        JSON.parse(File.read(LEDGER))
      end

      # [[control name, passed?]] — every grader must separate a planted good report from a planted bad one.
      def controls
        question = { "facts" => [{ "id" => "a", "any" => ["alpha"] }, { "id" => "b", "any" => ["beta"] }],
                     "after" => "2026-01-01" }
        Dir.mktmpdir do |dir|
          oracle = Graders.load(plant(dir, "oracle", "Alpha holds [1]. Beta holds [2].", published: "2026-03-01"))
          half = Graders.load(plant(dir, "half", "Alpha holds [1]. Nothing else is known [2].", published: "2026-03-01"))
          uncited = Graders.load(plant(dir, "uncited", "Alpha holds. Beta holds.", published: "2026-03-01"))
          dangling = Graders.load(plant(dir, "dangling", "Alpha holds [1]. Beta holds [9].", published: "2026-03-01"))
          stale = Graders.load(plant(dir, "stale", "Alpha holds [1]. Beta holds [2].", published: "2024-03-01"))
          [["recall: oracle 1.0, half 0.5", Graders.recall(oracle, question)["score"] == 1.0 &&
                                              Graders.recall(half, question)["score"] == 0.5],
           ["recall: an uncited fact is not recalled", Graders.recall(uncited, question)["score"].zero?],
           ["structure: a number with no source is dangling",
            Graders.structure(dangling)["dangling"] == [9] && Graders.structure(oracle)["dangling"].empty?],
           ["recency: stale sources score 0, fresh 1",
            Graders.recency(stale, question).zero? && Graders.recency(oracle, question) == 1.0],
           ["support items carry the cited page's excerpt",
            Graders.support_items(oracle).first["excerpts"] == ["Alpha holds, says page 1."]]]
        end
      end

      # A research folder as Tamoz writes one, with two sources.
      def plant(dir, name, findings, published:)
        folder = File.join(dir, name)
        FileUtils.mkdir_p(File.join(folder, "notes"))
        sources = (1..2).map { |number| "[#{number}] Page #{number}. https://site#{number}.example/p. Published #{published}." }
        File.write(File.join(folder, "report.md"),
                   "# Q\n\n## Summary\n\nShort.\n\n## Findings\n\n#{findings}\n\n## Gaps and limits\n\n- None.\n\n" \
                   "## Sources\n\n#{sources.join("\n")}\n")
        File.write(File.join(folder, "notes", "1.md"),
                   "# Child 1 (wave 1)\n\n## Q1: found\n- Alpha holds.\n  > Alpha holds, says page 1.\n  " \
                   "https://site1.example/p\n- Beta holds.\n  > Beta holds, says page 2.\n  https://site2.example/p\n")
        File.write(File.join(folder, "run.json"), JSON.generate("searches" => 2, "page_reads" => 2))
        folder
      end

      # Judge controls, run before any real number is read: a supported and an unsupported sentence must be told
      # apart, and a full report must beat a stub whichever side it is shown on.
      def judge_controls(judge)
        good = { "sentence" => "Oslo had 717,710 residents on 1 January 2025 [1].",
                 "excerpts" => ["Oslo had 717,710 residents on 1 January 2025, up 1.2 percent."] }
        bad = { "sentence" => "Oslo's population fell by 5 percent in 2024 [1].", "excerpts" => good["excerpts"] }
        full = "## Summary\n\nOslo had 717,710 residents on 1 January 2025 and grew 1.2 percent in a year, " \
               "driven mostly by immigration. Growth has slowed since 2019."
        stub = "## Summary\n\nOslo is a city in Norway."
        question = "How many people live in Oslo, and is it growing?"
        forward = judge.compare(question, full, stub)
        backward = judge.compare(question, stub, full)
        [["support: supported vs unsupported", judge.supported([good, bad]) == [true, false]],
         ["pairwise: full report wins in both orders",
          forward["comprehensiveness"] == "A" && backward["comprehensiveness"] == "B"]]
      end

      # Runs a question set in the named arms, stops before the ledger could be overdrawn, and writes the report as
      # it goes. The judge is checked first; a judge that cannot tell good from bad makes every number unreadable.
      def run(set:, arms:, out:, log:, ids: nil)
        judge = Judge.new(base: "https://openrouter.ai/api/v1", key: key("OPENROUTER_API_KEY"),
                          model: ENV.fetch("AGENTEVAL_JUDGE_MODEL", "deepseek/deepseek-v4-pro"))
        failed = judge_controls(judge).reject(&:last)
        raise "judge controls failed: #{failed.map(&:first).join('; ')}" unless failed.empty?

        env = run_env(brave_key: key("BRAVE_API_KEY"), zai_key: key("ZAI_API_KEY"),
                      cache: File.join(File.dirname(out), "research-cache"))
        chosen = questions(set).select { |question| ids.nil? || ids.include?(question.fetch("id")) }
        log.puts("brave ledger at start: #{ledger}")
        results = []
        chosen.each do |question|
          arms.each do |arm|
            if ledger.fetch("cap") - ledger.fetch("used") < SEARCHES_PER_RUN
              results << { "id" => question.fetch("id"), "arm" => arm, "status" => "eval_budget_exhausted" }
              next
            end
            log.puts("#{question.fetch('id')} #{arm} ...")
            root = File.join(File.dirname(out), File.basename(out, ".json"))
            result = finished(root, question, arm) || run_one(question, arm, out: root, env:)
            result["support"] = support(judge, result["folder"]) if result["folder"]
            results << result
            write(out, set, results)
          end
          pairwise(judge, question, results)
          write(out, set, results)
        end
        log.puts("brave ledger at end: #{ledger}")
        write(out, set, results)
      end

      def support(judge, folder)
        items = Graders.support_items(Graders.load(folder))
        verdicts = judge.supported(items)
        { "sentences" => items.length, "supported" => verdicts.count(true),
          "rate" => items.empty? ? nil : verdicts.count(true).fdiv(items.length).round(3) }
      rescue StandardError => e
        { "error" => e.message[0, 200] }
      end

      # A run already on disk is graded again, never run again: a restart spends no search twice.
      def finished(root, question, arm)
        path = File.join(root, arm, question.fetch("id"), "result.json")
        File.exist?(path) ? JSON.parse(File.read(path)) : nil
      end

      # fanout against single on the rubric, both orders; a criterion is won only when both orders agree.
      def pairwise(judge, question, results)
        mine = results.select { |result| result["id"] == question.fetch("id") && result["folder"] }
        fanout = mine.find { |result| result["arm"] == "fanout" }
        single = mine.find { |result| result["arm"] == "single" }
        return unless fanout && single

        first = File.read(File.join(fanout["folder"], "report.md"))
        second = File.read(File.join(single["folder"], "report.md"))
        forward = judge.compare(question.fetch("question"), first, second)
        backward = judge.compare(question.fetch("question"), second, first)
        fanout["pairwise"] = Judge::RUBRIC.to_h do |criterion|
          winner = { %w[A B] => "fanout", %w[B A] => "single" }.fetch([forward[criterion], backward[criterion]], "tie")
          [criterion, winner]
        end
      end

      def write(out, set, results)
        report = { "set" => set, "plan_reply" => "auto: #{PLAN_REPLY}", "searches_per_run" => SEARCHES_PER_RUN,
                   "ledger" => ledger, "summary" => summary(results), "results" => results }
        FileUtils.mkdir_p(File.dirname(out))
        File.write(out, JSON.pretty_generate(report))
        report
      end

      def summary(results)
        results.group_by { |result| result["arm"] }.transform_values do |runs|
          reported = runs.select { |result| result["status"] == "report" }
          mean = lambda do |values|
            values = values.compact
            values.empty? ? nil : (values.sum.fdiv(values.length)).round(3)
          end
          { "runs" => runs.length, "reports" => reported.length,
            "key_fact_recall" => mean.call(reported.map { |result| result.dig("recall", "score") }),
            "citation_support" => mean.call(reported.map { |result| result.dig("support", "rate") }),
            "recency" => mean.call(reported.map { |result| result["recency"] }),
            "searches" => mean.call(reported.map { |result| result.dig("cost", "searches") }),
            "wall_s" => mean.call(reported.map { |result| result["wall_s"] }),
            "stop_reasons" => reported.map { |result| result.dig("cost", "stop_reason") }.tally }
        end
      end

      # A key from the environment, else from the repository's .env (written `KEY = value` or `KEY=value`).
      def key(name)
        value = ENV[name].to_s
        return value unless value.empty?

        dotenv = File.join(ROOT, ".env")
        found = File.exist?(dotenv) ? File.read(dotenv)[/^#{name}\s*=\s*(\S+)/, 1].to_s : ""
        raise "#{name} is not set" if found.empty?

        found
      end

      # One real run; returns its graded result. Spends at most SEARCHES_PER_RUN Brave requests.
      def run_one(question, arm, out:, env:, timeout: 1800)
        dir = File.join(out, arm, question.fetch("id"))
        FileUtils.rm_rf(dir)
        runtime = File.join(dir, "runtime")
        workspace = File.join(dir, "workspace")
        FileUtils.mkdir_p(workspace)
        FileUtils.mkdir_p([runtime, File.join(dir, "sessions")], mode: 0o700)
        init, code = tamoz(env, "--runtime-dir", runtime, "--root", workspace, "init")
        raise "tamoz init failed: #{init}" unless code.zero?

        configure(runtime)
        budgets = File.join(dir, "budgets.json")
        File.write(budgets, JSON.generate(ARMS.fetch(arm)))
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        output, status = tamoz(env, "--runtime-dir", runtime, "--root", workspace, "--session-dir",
                               File.join(dir, "sessions"), "--provider", "zai", "--model", "glm-5.3-flash",
                               "--research-budgets", budgets, "deep-research", question.fetch("question"),
                               input: "#{PLAN_REPLY}\n", timeout:)
        wall = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)
        File.write(File.join(dir, "output.txt"), output)
        folder = Dir[File.join(workspace, "research", "*", "report.md")].first
        result = if folder
                   graded(question, arm, Graders.load(File.dirname(folder)))
                     .merge("exit" => status, "wall_s" => wall, "folder" => File.dirname(folder))
                 else
                   { "id" => question.fetch("id"), "arm" => arm, "status" => "no_report", "exit" => status,
                     "wall_s" => wall }
                 end
        File.write(File.join(dir, "result.json"), JSON.generate(result))
        result
      end

      def graded(question, arm, folder)
        { "id" => question.fetch("id"), "set" => question.fetch("set"), "class" => question.fetch("class"),
          "arm" => arm, "status" => "report", "structure" => Graders.structure(folder),
          "recall" => Graders.recall(folder, question), "recency" => Graders.recency(folder, question),
          "cost" => Graders.cost(folder) }
      end

      def configure(runtime)
        path = File.join(runtime, "config.yaml")
        document = Psych.safe_load_file(path)
        document["sources"] = {
          "websearch" => { "enabled" => true, "command" => RbConfig.ruby,
                           "arguments" => [File.join(ROOT, "script", "websearch_adapter")],
                           "env_allowlist" => ADAPTER_ENV, "credential_refs" => ["TAMOZ_BRAVE_API_KEY"],
                           "read_only_tools" => %w[search read_page] }
        }
        File.write(path, Psych.dump(document))
        File.chmod(0o600, path)
      end

      # The environment a real run needs; the keys come from the caller, never from a file this pack writes.
      def run_env(brave_key:, zai_key:, cache:)
        { "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8", "TAMOZ_WEBSEARCH_GRANT" => "1",
          "TAMOZ_WEBSEARCH_EGRESS" => JSON.generate(EGRESS),
          "TAMOZ_WEBSEARCH_PROVIDER" => JSON.generate("search" => "brave", "reader" => "direct"),
          "TAMOZ_WEBSEARCH_LEDGER" => LEDGER, "TAMOZ_WEBSEARCH_CACHE" => cache, "TAMOZ_BRAVE_API_KEY" => brave_key,
          "ZAI_API_KEY" => zai_key, "ZAI_API_BASE" => "https://api.z.ai/api/coding/paas/v4" }
      end

      def tamoz(env, *args, input: "", timeout: 120)
        command = [RbConfig.ruby, "-rbundler/setup", File.join(ROOT, "gems", "tamoz-agent-cli", "exe", "tamoz"), *args]
        Open3.popen2e(env.merge("BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile")), *command, chdir: ROOT) do |stdin, output, wait|
          stdin.write(input)
          stdin.close
          reader = Thread.new { output.read }
          unless wait.join(timeout)
            Process.kill("KILL", wait.pid)
            return ["#{reader.value}\n[killed after #{timeout}s]", "timeout"]
          end
          [reader.value, wait.value.exitstatus]
        end
      end
    end
  end
end
