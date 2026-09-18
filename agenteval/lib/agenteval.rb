# frozen_string_literal: true

require "digest"

require_relative "agenteval/seeded"
require_relative "agenteval/scenario"
require_relative "agenteval/workspace"
require_relative "agenteval/project"
require_relative "agenteval/task"
require_relative "agenteval/modifier"
require_relative "agenteval/stage"
require_relative "agenteval/cost"
require_relative "agenteval/controls"
require_relative "agenteval/control_suite"
require_relative "agenteval/trial"
require_relative "agenteval/report"

module Agenteval
  VERSION = "0.1.0"
  ROOT = File.expand_path("..", __dir__)

  def self.load_packs
    Dir.glob(File.join(ROOT, "packs", "*.rb")).sort.each { |path| require path }
  end

  def self.load_adapter(id)
    path = File.join(ROOT, "adapters", "#{id}.rb")
    raise ArgumentError, "no adapter #{id} (expected #{path})" unless File.exist?(path)

    load(path)
    Adapters.fetch(id)
  end

  module Adapters
    def self.all = @all ||= {}
    def self.register(adapter) = all[adapter.id] = adapter
    def self.fetch(id) = all.fetch(id) { raise ArgumentError, "adapter #{id} did not register itself" }
  end

  # Expands tasks × modifiers × seeds into scenarios. The corpus digest covers the pack
  # source as well as the selection, so editing a task invalidates comparison against an
  # older report instead of silently changing what a number means.
  class Suite
    attr_reader :tasks, :modifiers, :seeds, :language, :difficulty, :budget_seconds

    def initialize(tasks:, modifiers:, seeds:, language:, difficulty:, budget_seconds:)
      @tasks = tasks
      @modifiers = modifiers
      @seeds = seeds
      @language = language
      @difficulty = difficulty
      @budget_seconds = budget_seconds
    end

    def scenarios
      @scenarios ||= @tasks.flat_map do |task|
        @modifiers.filter_map do |modifier|
          next unless task.applicable?(modifier.id)

          @seeds.map { |seed| instantiate(task, modifier, seed) }
        end.flatten(1)
      end
    end

    def digest
      payload = {
        "framework" => VERSION,
        "tasks" => @tasks.map(&:id).sort,
        "modifiers" => @modifiers.map { |modifier| modifier.id.to_s }.sort,
        "seeds" => @seeds.sort,
        "language" => @language.id.to_s,
        "difficulty" => @difficulty,
        "packs" => pack_digest,
        "scorer" => scorer_digest
      }
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    def descriptor
      {
        "digest" => digest, "scenarios" => scenarios.length,
        "tasks" => @tasks.map(&:id).sort,
        "modifiers" => @modifiers.map { |modifier| modifier.id.to_s }.sort,
        "seeds" => @seeds, "difficulty" => @difficulty, "language" => @language.id.to_s
      }
    end

    private

    def pack_digest
      sources = Dir.glob(File.join(ROOT, "packs", "*.rb")).sort.map do |path|
        Digest::SHA256.hexdigest(File.binread(path))
      end
      Digest::SHA256.hexdigest(sources.join)
    end

    # The scorer is part of the measurement. Without this, editing how a status is
    # assigned leaves the digest unchanged and two runs that were graded by different
    # logic still call themselves comparable.
    def scorer_digest
      sources = Dir.glob(File.join(ROOT, "lib", "**", "*.rb")).sort.map do |path|
        Digest::SHA256.hexdigest(File.binread(path))
      end
      Digest::SHA256.hexdigest(sources.join)
    end

    def instantiate(task, modifier, seed)
      # The scenario seed mixes task and modifier so the same numeric seed does not produce
      # the same project across tasks — one memorised instance never unlocks the corpus.
      mixed = Digest::SHA256.hexdigest("#{task.id}/#{modifier.id}/#{seed}")[0, 8].to_i(16)
      seeded = Seeded.new(mixed)
      project = Project.generate(seeded, language: @language, difficulty: @difficulty)
      built = task.build.call(seeded, project)

      scenario = Scenario.new(
        id: "#{task.id}.#{modifier.id}.#{seed}",
        task_id: task.id,
        modifier: modifier.id,
        difficulty: @difficulty,
        language: @language.id,
        prompt: built.prompt,
        files: built.files,
        expect: task.expect,
        oracle: built.oracle,
        budget_seconds: @budget_seconds,
        frozen_paths: [],
        readonly: task.readonly,
        seed: seed,
        notes: (built.notes || {}).merge("check_command" => project.test_command.join(" "))
      )
      scenario.notes["abstention_markers"] ||= modifier.abstention_markers
      [modifier.apply.call(scenario, project, seeded), built]
    end
  end
end