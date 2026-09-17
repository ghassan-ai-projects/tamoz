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

    # A correct abstention is decided by the ORACLE — a factual predicate over the
    # workspace — not by the phrasing of the answer. Grading the words was tried and
    # removed: a pattern list authored against one author's examples rejected 73% of
    # naturally-worded, genuinely correct refusals, while a constant sentence satisfied
    # 67% of the cells it was meant to protect. Both failures are worse than the one it
    # was meant to fix.
    #
    # Did the agent address the thing it was asked about? Only that the subject appears,
    # with no requirement on phrasing. This check exists for one narrow job — separating a
    # decision from a crash — because a crashed planner names nothing at all (the recorded
    # one reads "no plan passed review after 3 attempts"). A cell with no declared subject
    # is not gated on it, so an authoring omission fails open rather than closed.
    def addressed?(answer)
      subject = notes["abstention_subject"].to_s
      return !answer.to_s.strip.empty? if subject.empty?

      answer.to_s.downcase.include?(subject.downcase)
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
