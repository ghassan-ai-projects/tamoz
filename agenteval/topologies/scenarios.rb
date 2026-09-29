# frozen_string_literal: true

# The hard pack (docs/subagent-topologies-2026-09-29/DESIGN.md §3). A `chain` needle shares no distinctive word with
# what the agent is shown (bar H1); in a `survey`, the lines the obvious searches return are the same for a handler
# that mutates and one that does not, so the answer needs reading across files (H2). Names and values come from the
# seed; every prompt carries a canary the task never needs.
module Agenteval
  module TopologyPack
    S = SessionChain::Session
    CHECK = SubagentPack::CHECK
    WORDS = SubagentPack::WORDS

    # `grep` is what the H2 control leaves: the best of the search-only policies below, run over the files.
    Spec = Data.define(:tag, :needle, :canary, :solution, :grep, :tests, :shown, :answer)

    module_function

    def ok(detail) = Judgement.ok(detail)
    def no(detail) = Judgement.no(detail)
    def canary(seed) = SubagentPack.canary("topologies/#{seed}")
    def prompt(seed, text) = SubagentPack.prompt("topologies/#{seed}", text)
    def random(family, seed) = Random.new(Digest::SHA256.hexdigest("#{family}/#{seed}")[0, 8].to_i(16))

    # What a search for `pattern` returns: "path:line:text" per matching line.
    def search(files, pattern)
      files.flat_map do |path, text|
        text.lines.each_with_index.filter_map { |line, index| "#{path}:#{index + 1}:#{line.chomp}" if line.match?(pattern) }
      end
    end

    def passes_hidden(chain, spec)
      result = chain.workspace.verify_with(overlay: spec.tests, command: CHECK)
      result.ok ? ok("hidden tests pass") : no("hidden tests fail: #{Verify.tail(result.output)}")
    end

    def only_changed(chain, allowed)
      extra = chain.workspace.mutations - allowed
      extra.empty? ? nil : no("changed outside the task: #{extra.first(5).join(', ')}")
    end

    def scenario(id:, seed:, title:, files:, text:, spec:, oracle:)
      SessionChain::Scenario.new(
        id: "#{id}.#{seed}", title:, kind: "topologies", files: { "a" => files }, check: CHECK,
        sessions: [S.new(prompt: prompt(seed, text))], oracle:, controls: { spec: },
        notes: { "tag" => spec.tag, "needle" => spec.needle, "canary" => spec.canary, "family" => id }
      )
    end

    # HA1: the wrong surcharge is reached through invoice -> engine -> loader -> region file -> alias table -> zone file;
    # the same wrong value sits in four decoy zones, so fixing the files a search for it returns changes the wrong data.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one generated project
    def chain(seed)
      random = random("ha1", seed)
      zones = WORDS.sample(24, random:).map { |word| "#{word}#{random.rand(10..99)}" }
      region = zones.sample(random:)
      aliases = zones.to_h { |zone| ["r#{random.rand(100..999)}#{zone[0, 2]}", zone] }
      code = aliases.key(region)
      right = [5, 6, 7, 8, 9].sample(random:)
      wrong = right + [11, 12, 13].sample(random:)
      decoys = (zones - [region]).sample(4, random:)
      zone = ->(value, name) { "surcharge: 0.#{format('%02d', value)}\nlabel: #{name.capitalize} district\n" }
      files = zones.to_h { |name| ["config/zones/#{name}.yml", zone.call(decoys.include?(name) ? wrong : random.rand(1..4), name)] }
      files["config/zones/#{region}.yml"] = zone.call(wrong, region)
      files.merge!(
        "config/deploy.txt" => "#{code}\n",
        "config/aliases.yml" => aliases.map { |key, value| "#{key}: #{value}\n" }.join,
        "lib/settings/loader.rb" => "require 'yaml'\n\nmodule Loader\n  ROOT = File.expand_path('../../config', __dir__)\n\n" \
                                    "  def self.site = YAML.load_file(File.join(ROOT, 'aliases.yml'))" \
                                    ".fetch(File.read(File.join(ROOT, 'deploy.txt')).strip)\n\n" \
                                    "  def self.rate_for(name) = YAML.load_file(File.join(ROOT, 'zones', \"\#{name}.yml\"))" \
                                    ".fetch('surcharge')\nend\n",
        "lib/pricing/engine.rb" => "require_relative '../settings/loader'\n\nmodule Engine\n  def self.total(lines) = " \
                                   "(lines.sum * (1 + Loader.rate_for(Loader.site))).round(2)\nend\n",
        "lib/invoice.rb" => "require_relative 'pricing/engine'\n\ndef invoice_total(lines) = Engine.total(lines)\n"
      )
      files.merge!(SubagentPack.noise(random, 60))
      expected = (30 * (1 + (right / 100.0))).round(2)
      test = "require_relative '../lib/invoice'\nactual = invoice_total([10, 20])\n" \
             "abort \"invoice_total([10, 20]) is \#{actual}, expected #{expected}\" unless actual == #{expected}\n"
      files["test/invoice_test.rb"] = test
      needle = "config/zones/#{region}.yml"
      hits = search(files, /0\.#{format('%02d', wrong)}/).map { |hit| hit.split(":").first }.uniq
      spec = Spec.new(tag: "chain", needle:, canary: canary(seed), solution: { needle => zone.call(right, region) },
                      grep: hits.to_h { |path| [path, files.fetch(path).sub(/0\.#{format('%02d', wrong)}/, "0.#{format('%02d', right)}")] },
                      tests: { "test/invoice_test.rb" => test }, answer: nil,
                      shown: "invoice_total([10, 20]) is #{(30 * (1 + (wrong / 100.0))).round(2)}, expected #{expected}")
      oracle = ->(chain) { only_changed(chain, [needle]) || passes_hidden(chain, spec) }
      scenario(id: "HA1", seed:, title: "chain", files:, spec:, oracle:,
               text: "test/invoice_test.rb fails: invoice_total([10, 20]) should be #{expected}. Find the cause and fix " \
                     "the data at its source, without changing code or tests.")
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # Each handler's effect is in its own code, in forms that defeat the search policies below: aliases and `to_h`
    # (a Hash's to_h is itself), block parameters, a helper in the same file, a snapshot copy beside a real change, and a
    # mutating call on a fresh hash. [body, helper or nil, mutates the event?]
    FORMS = [
      ->(_, v) { ["#{v} = event\n    #{v}.store(:tagged, true)", nil, true] },
      ->(_, v) { ["#{v} = event.to_h\n    #{v}.delete(:draft)", nil, true] },
      ->(_, v) { ["event.tap { |#{v}| #{v}.merge!(checked: true) }", nil, true] },
      ->(_, v) { ["[event].each { |#{v}| #{v}.update(seen: true) }", nil, true] },
      ->(n, _) { ["stamp_#{n}(event)", "def self.stamp_#{n}(item) = item.store(:stamp, 1)", true] },
      ->(n, v) { ["#{v} = event.dup\n    stamp_#{n}(event)\n    #{v}", "def self.stamp_#{n}(item) = item.delete(:draft)", true] },
      ->(_, v) { ["#{v} = event.dup\n    event.store(:seen, true)\n    #{v}", nil, true] },
      ->(n, _) { ["Support.prep_#{n}(event)", [:shared, "def self.prep_#{n}(item) = item.merge!(prepped: true)"], true] },
      ->(_, v) { ["#{v} = event.dup\n    #{v}.store(:tagged, true)", nil, false] },
      ->(_, v) { ["#{v} = event.to_a.to_h\n    #{v}.delete(:draft)", nil, false] },
      ->(_, v) { ["event.dup.tap { |#{v}| #{v}.merge!(checked: true) }", nil, false] },
      ->(n, _) { ["stamp_#{n}(event)", "def self.stamp_#{n}(item) = item.merge(stamp: 1)", false] },
      ->(n, _) { ["stamp_#{n}(event)", "def self.stamp_#{n}(item) = item.dup.tap { |copy| copy.delete(:draft) }", false] },
      ->(_, v) { ["event.merge(checked: true).then { |#{v}| #{v}.store(:seen, true) }", nil, false] },
      ->(_, v) { ["#{v} = Marshal.load(Marshal.dump(event))\n    #{v}.update(seen: true)", nil, false] },
      ->(n, _) { ["Support.prep_#{n}(event)", [:shared, "def self.prep_#{n}(item) = item.to_a.to_h.store(:prepped, true)"], false] }
    ].freeze
    VERBS = /\.(store|delete|merge!|update|compact!|clear)\b|\.merge!\(/
    COPIES = /\.(dup|clone|to_a)\b|Marshal|Hash\[/

    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one generated project
    def survey(seed, padded:)
      random = random(padded ? "ha3" : "ha2", seed)
      names = WORDS.flat_map { |word| [word, "#{word}_batch"] }.sample(padded ? 40 : 36, random:)
      forms = names.to_h { |name| [name, FORMS.sample(random:).call(name, WORDS.sample(random:))] }
      files = names.to_h do |name|
        body, helper, = forms.fetch(name)
        local = helper.is_a?(String) ? "\n  #{helper}\n" : ""
        ["lib/handlers/#{name}.rb",
         "require_relative 'support'\n\nmodule Handlers\n  def self.handle_#{name}(event)\n    #{body}\n    event\n  end\n" \
         "#{padded ? filler(random, name, 36) : ''}#{local}end\n"]
      end
      shared = forms.values.filter_map { |_, helper, _| helper.last if helper.is_a?(Array) }
      files["lib/handlers/support.rb"] = "module Support\n#{shared.map { |line| "  #{line}\n" }.join}end\n"
      answer = names.select { |name| forms.fetch(name)[2] }.map { |name| "handle_#{name}" }.sort
      spec = Spec.new(tag: "survey", needle: nil, canary: canary(seed), solution: { "MUTATING.txt" => "#{answer.join("\n")}\n" },
                      grep: { "MUTATING.txt" => "#{grep_survey(files, names, answer).join("\n")}\n" }, tests: {}, shown: nil,
                      answer:)
      oracle = lambda do |chain|
        stray = only_changed(chain, ["MUTATING.txt"])
        return stray if stray

        listed = chain.read("MUTATING.txt").to_s.lines.map(&:strip).reject(&:empty?).sort
        missed = answer - listed
        wrong = listed - answer
        missed.empty? && wrong.empty? ? ok("exact set") : no("missed #{missed.length}, wrongly listed #{wrong.length}")
      end
      scenario(id: padded ? "HA3" : "HA2", seed:, title: padded ? "big survey" : "survey", files:, spec:, oracle:,
               text: "Under lib/handlers, some handle_* methods modify the event hash they are given (the hash itself, " \
                     "possibly through a helper they call); others leave it untouched. Write the names of those that " \
                     "modify it into MUTATING.txt, one per line, sorted. Change no other file.")
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # The search-only policies H2 pits against a survey, each deciding per handler file from search hits alone: a
    # mutating call on `event` itself; any mutating call in the file; the same but excusing files that copy; a mutating
    # call on a plain alias of `event`; every handler. The control leaves the policy that scores best against the
    # answer key, so it fails only if every policy does.
    def grep_survey(files, names, answer)
      text = ->(name) { files.fetch("lib/handlers/#{name}.rb") }
      policies = [
        ->(name) { text.call(name).match?(/\bevent#{VERBS.source}/) },
        ->(name) { text.call(name).match?(VERBS) },
        ->(name) { text.call(name).match?(VERBS) && !text.call(name).match?(COPIES) },
        ->(name) { text.call(name).match?(/(\w+) = event(\.to_h)?\n\s*\1#{VERBS.source}/) },
        ->(name) { mutates_unless_copied?(text.call(name), /event\.(dup|to_a|merge\()|Marshal/) },
        ->(name) { mutates_unless_copied?(text.call(name), /event\.(dup|to_a|merge)|Marshal/) },
        ->(_) { true }
      ]
      picks = policies.map { |policy| names.select(&policy).map { |name| "handle_#{name}" }.sort }
      picks.max_by { |picked| (picked & answer).length - (picked - answer).length - (answer - picked).length }
    end

    # A review-found policy: a mutating call in the file counts unless the event is copied, except that a bare helper
    # call on the event always counts.
    def mutates_unless_copied?(text, copied)
      text.match?(VERBS) && (!text.match?(copied) || text.match?(/^\s+\w+\(event\)$/))
    end

    def filler(random, name, count)
      (1..count).map do |index|
        "\n  # Formats the #{WORDS.sample(random:)} summary line #{index} for #{name}; kept for the reporting job.\n" \
          "  def self.summary_#{name}_#{index}(rows)\n    rows.map { |row| format('%-12s %8.2f', row.fetch(:label), " \
          "row.fetch(:amount) * #{index}) }\n  end\n"
      end.join
    end

    # HA4: the obvious edit to format_amount breaks a caller two hops away (through a label helper) that no visible test
    # covers, among distractor modules.
    # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- one generated project
    def change(seed)
      random = random("ha4", seed)
      currency = %w[EUR CHF SEK NOK DKK].sample(random:)
      reporter = WORDS.sample(random:)
      money = ->(body) { "def format_amount(value) = #{body}\n" }
      ledger = ->(body) { "require_relative '../text/labels'\n\ndef #{reporter}_ledger_total(values)\n  #{body}\nend\n" }
      files = SubagentPack.noise(random, 60).merge(
        "lib/money.rb" => money.call("value.to_s"),
        "lib/text/labels.rb" => "require_relative '../money'\n\nmodule Labels\n  def self.amount(value) = format_amount(value)\nend\n",
        "lib/export/#{reporter}_ledger.rb" => ledger.call("values.sum { |value| Integer(Labels.amount(value)) }"),
        "test/money_test.rb" => "require_relative '../lib/money'\nabort 'format' unless format_amount(3) == '3.00 #{currency}'\n"
      )
      hidden = files.slice("test/money_test.rb").merge(
        "test/ledger_test.rb" => "require_relative '../lib/export/#{reporter}_ledger'\nabort 'ledger' unless " \
                                 "#{reporter}_ledger_total([1, 2]) == 3\n"
      )
      fixed = money.call("format('%.2f #{currency}', value)")
      hits = search(files, /format_amount/).map { |hit| hit.split(":").first }.uniq - ["lib/money.rb"]
      spec = Spec.new(tag: "change", needle: "lib/export/#{reporter}_ledger.rb", canary: canary(seed),
                      solution: { "lib/money.rb" => fixed, "lib/export/#{reporter}_ledger.rb" => ledger.call("values.sum") },
                      grep: { "lib/money.rb" => fixed }.merge(hits.to_h { |path| [path, files.fetch(path)] }),
                      tests: hidden, shown: nil, answer: nil)
      scenario(id: "HA4", seed:, title: "change with a hidden caller", files:, spec:,
               oracle: ->(chain) { passes_hidden(chain, spec) },
               text: "Make format_amount in lib/money.rb return two decimals and the currency: format_amount(3) must be " \
                     "'3.00 #{currency}' (test/money_test.rb). Nothing else in the project may break.")
    end
    # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

    # HA5 and HA6: the place is one search away, so the search-only policy solves them from its own hits.
    def narrow(seed)
      random = random("ha5", seed)
      limit = [4, 6, 7, 9].sample(random:)
      files = SubagentPack.noise(random, 30).merge(
        "lib/retry.rb" => "MAX_RETRIES = 3\n",
        "test/retry_test.rb" => "require_relative '../lib/retry'\nabort 'retries' unless MAX_RETRIES == #{limit}\n"
      )
      searched = search(files, /MAX_RETRIES = \d/).map { |hit| hit.split(":").first }.uniq
      spec = Spec.new(tag: "narrow", needle: nil, canary: canary(seed), solution: { "lib/retry.rb" => "MAX_RETRIES = #{limit}\n" },
                      grep: searched.to_h { |path| [path, files.fetch(path).sub(/MAX_RETRIES = \d+/, "MAX_RETRIES = #{limit}")] },
                      tests: files.slice("test/retry_test.rb"), shown: nil, answer: nil)
      scenario(id: "HA5", seed:, title: "narrow", files:, spec:, oracle: ->(chain) { passes_hidden(chain, spec) },
               text: "The retry limit MAX_RETRIES must be #{limit}. Change it.")
    end

    def trivial(seed)
      base = SubagentPack.trivial("topologies/#{seed}")
      files = base.files.fetch("a")
      searched = search(files.except("test/greeting_test.rb"), /Helo/).map { |hit| hit.split(":").first }.uniq
      spec = base.controls.fetch(:spec)
      spec = Spec.new(tag: "trivial", needle: nil, canary: canary(seed), solution: spec.solution,
                      grep: searched.to_h { |path| [path, files.fetch(path).sub("Helo", "Hello")] },
                      tests: spec.tests, shown: nil, answer: nil)
      scenario(id: "HA6", seed:, title: "trivial", files:, spec:, oracle: ->(chain) { passes_hidden(chain, spec) },
               text: "lib/greeting.rb has a typo: Helo should be Hello. Fix it.")
    end

    def scenarios(seeds)
      seeds.flat_map do |seed|
        [chain(seed), survey(seed, padded: false), survey(seed, padded: true), change(seed), narrow(seed), trivial(seed)]
      end
    end
  end
end
