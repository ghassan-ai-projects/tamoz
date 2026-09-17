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
    # indistinguishable from stalling, and only the statement separates judgment from a
    # crash. `abstention_markers` lists alternative phrasings, each of which only a
    # deliberate refusal contains; no marker may appear in the prompt, or an agent that
    # echoes the request would satisfy it without deciding anything.
    #
    # An abstention cell with NO markers is a corpus defect, not a permissive default:
    # treating "no markers" as "anything counts" lets an agent that echoes the prompt
    # score a correct abstention.
    def stated_abstention?(answer)
      text = answer.to_s.downcase
      return false if text.strip.empty?

      markers = Array(notes["abstention_markers"]).map(&:downcase).reject(&:empty?)
      return false if markers.empty?

      markers.any? { |marker| text.include?(marker) }
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
