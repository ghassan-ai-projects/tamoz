# frozen_string_literal: true

module Agenteval
  # A task is a generator. `build` receives a seeded generator and a freshly generated
  # project and returns the scenario parts. It never names an agent and never inspects one.
  #
  # `hidden` is the acceptance suite: files overlaid onto a copy of the agent's result at
  # judgement time. The agent cannot read, edit or fit them, which is what makes editing the
  # visible tests a useless cheat rather than a passing strategy.
  # `horizon` is the task-length axis (METR's lesson): a declared property of the task, not
  # a measured runtime. Today every task is `:short` (seconds-to-minutes); the axis exists so
  # a report states its horizon coverage rather than assuming it, and so `:medium`/`:long`
  # read as gaps until a soak-scale task lands (the honest home is the physical fault soak).
  Task = Struct.new(
    :id, :use_case, :title, :expect, :readonly, :supports, :horizon, :build,
    keyword_init: true
  ) do
    def applicable?(modifier) = supports.nil? || supports.include?(modifier)
  end

  # The declared task-length classes. A task names one; an unknown value is a typo that would
  # otherwise surface silently as its own horizon bucket, so it is refused at definition time.
  HORIZONS = %i[short medium long].freeze

  Built = Struct.new(:prompt, :files, :hidden, :oracle, :notes, :solution, keyword_init: true)

  class Registry
    def self.tasks = @tasks ||= {}

    def self.define(id:, use_case:, title:, expect: :solve, readonly: false, supports: nil, horizon: :short, &build)
      unless HORIZONS.include?(horizon)
        raise ArgumentError, "task #{id} declares an unknown horizon #{horizon.inspect}; one of #{HORIZONS.inspect}"
      end

      tasks[id] = Task.new(id:, use_case:, title:, expect:, readonly:, supports:, horizon:, build:)
    end

    def self.fetch(id, &block) = tasks.fetch(id, &block)

    def self.all = tasks.values
  end

  # Verification primitives shared by tasks, so an oracle reads as a statement of fact.
  module Verify
    module_function

    # The pristine suite, run against whatever the agent left behind. This is the spine of
    # capability scoring: the agent's edits to visible tests cannot influence it.
    def hidden_suite(workspace, overlay, command)
      result = workspace.verify_with(overlay: overlay, command: command)
      if result.timed_out
        Judgement.no("acceptance suite timed out")
      elsif result.ok
        Judgement.ok("acceptance suite passed")
      else
        Judgement.no("acceptance suite failed: #{tail(result.output)}")
      end
    end

    # Credits a written test suite only if it actually detects a broken implementation.
    # A suite that passes everything measures nothing.
    def kills_mutant(workspace, mutant_files, command)
      result = workspace.verify_with(overlay: mutant_files, command: command)
      # `ok` is false for a timed-out run too, so reading only `ok` credits a suite that
      # merely hung as one that detected the mutant.
      return Judgement.no("the mutant run timed out") if result.timed_out
      return Judgement.ok("suite failed against the mutant, as it must") unless result.ok

      Judgement.no("the written tests still pass against deliberately broken code")
    end

    def unchanged(workspace, detail: "workspace")
      touched = workspace.mutations
      return Judgement.ok("#{detail} untouched") if touched.empty?

      Judgement.no("#{detail} modified: #{touched.join(", ")}")
    end

    def all(*judgements)
      failed = judgements.find { |judgement| !judgement.ok }
      failed || Judgement.ok(judgements.map(&:detail).join("; "))
    end

    def tail(output, lines: 3)
      output.to_s.lines.map(&:rstrip).reject(&:empty?).last(lines).join(" | ")[0, 400]
    end
  end
end
