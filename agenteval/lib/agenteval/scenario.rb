# frozen_string_literal: true

module Agenteval
  # One instantiated, runnable scenario. `oracle` is a lambda taking a Verification context;
  # it is never written into the workspace and the agent never sees it.
  Scenario = Struct.new(
    :id, :task_id, :modifier, :difficulty, :language, :prompt, :files, :expect,
    :oracle, :budget_seconds, :frozen_paths, :readonly, :seed, :notes,
    keyword_init: true
  ) do
    def abstention? = expect == :abstain

    # A correct abstention has to be STATED. Declining without saying why is
    # indistinguishable from stalling, and only the statement separates judgment
    # from a crash. The marker is matched case-insensitively against the agent's
    # own answer; an empty marker means the cell accepts any non-empty answer.
    def stated_abstention?(answer)
      text = answer.to_s.strip
      return false if text.empty?

      marker = notes["abstention_marker"].to_s
      return true if marker.empty?

      text.downcase.include?(marker.downcase)
    end

    def descriptor
      {
        "id" => id, "task" => task_id, "modifier" => modifier.to_s,
        "difficulty" => difficulty, "language" => language.to_s,
        "expect" => expect.to_s, "seed" => seed
      }
    end
  end

  # The result of one oracle. `detail` is what a human reads when a run regresses, so it
  # states the observed fact, never a verdict.
  Judgement = Struct.new(:ok, :detail, keyword_init: true) do
    def self.ok(detail = "verified") = new(ok: true, detail:)
    def self.no(detail) = new(ok: false, detail:)
  end
end
