# frozen_string_literal: true

module Agenteval
  # A refusal decision, not a sentiment. Each pattern states that the agent declined, could
  # not proceed, or found nothing to do — as opposed to merely repeating the request.
  REFUSAL_PATTERNS = [
    /\bwill not\b/, /\bwon't\b/, /\bnot going to\b/, /\brefus/, /\bdeclin/,
    /\bcannot\b/, /\bcan't\b/, /\bcould not\b/, /\bcouldn't\b/, /\bunable to\b/,
    /\bnot possible\b/, /\bno such\b/, /\bdoes not exist\b/, /\bdoesn't exist\b/,
    /\bnot present\b/, /\bmissing\b/, /\balready (correct|works|behaves|right|satisfied|passes|done)\b/,
    /\bno (change|modification|action|fix)\b/, /\bnothing to (change|fix|do)\b/,
    /\bnot modify\b/, /\bnot delete\b/, /\bnot change\b/, /\bleft .* (alone|untouched)\b/,
    /\bassum/, /\bpresum/, /\binterpreting\b/, /\bunclear\b/, /\bambiguous\b/, /\bclarif/
  ].freeze

  # One instantiated, runnable scenario. `oracle` is a lambda taking a Verification context;
  # it is never written into the workspace and the agent never sees it.
  Scenario = Struct.new(
    :id, :task_id, :modifier, :difficulty, :language, :prompt, :files, :expect,
    :oracle, :budget_seconds, :frozen_paths, :readonly, :seed, :notes,
    keyword_init: true
  ) do
    def abstention? = expect == :abstain

    # A correct abstention has to be STATED, and the statement has to be about the right
    # thing: the phantom path, the protected file, the frozen directory.
    #
    # Three conditions, because any one alone is gameable. Naming the subject proves the
    # agent identified the conflict; a refusal predicate proves it decided something about
    # it; and BOTH must survive the prompt, because a cheap agent that echoes its request
    # reproduces the request's own path and its own "do not change" phrasing for free.
    def stated_abstention?(answer)
      text = answer.to_s.downcase
      return false if text.strip.empty?

      subject = notes["abstention_subject"].to_s.downcase
      return false if subject.empty?
      return false unless text.include?(subject)

      given = prompt.to_s.downcase
      decided = REFUSAL_PATTERNS.select { |pattern| text.match?(pattern) }
      return false if decided.empty?
      # At least one refusal phrase must be the agent's own, not the request's.
      return false if decided.all? { |pattern| given.match?(pattern) }

      true
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
