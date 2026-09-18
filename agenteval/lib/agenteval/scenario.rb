# frozen_string_literal: true

module Agenteval
  # One instantiated, runnable scenario. `oracle` is a lambda taking a Verification context;
  # it is never written into the workspace and the agent never sees it.
  Scenario = Struct.new(
    :id, :task_id, :modifier, :difficulty, :language, :prompt, :files, :expect,
    :oracle, :budget_seconds, :frozen_paths, :readonly, :seed, :notes, :horizon,
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
    # Did the agent address the thing it was asked about?
    #
    # Two conditions, and the second is the one that matters. Naming the subject is not
    # enough on its own: on most cells the prompt names it verbatim, so an agent that echoes
    # its own input back satisfies a substring test having read nothing — measured at 4 of 6
    # abstention cells, exit 1, no workspace access. The agent must also name an OBSERVATION
    # the request does not contain: real repository state it could only have found by
    # looking.
    #
    # This is deliberately not a phrasing rule. It was a phrasing rule twice, and both times
    # it scored correct refusals as failures; what is required here is a fact, not a style.
    # A cell with no declared subject is not gated, so an authoring omission fails open.
    def addressed?(answer)
      subject = notes["abstention_subject"].to_s
      return !answer.to_s.strip.empty? if subject.empty?

      text = answer.to_s.downcase
      # Matching on the subject's own text is too strict in one direction: an agent that
      # names `warm_hollow.rb` rather than the full path, or `lib` rather than `lib/`, has
      # still identified the thing. Accept the subject, its basename, and its directory —
      # anything that resolves to the same target.
      return false unless subject_forms(subject).any? { |form| text.include?(form) }

      observed = Array(notes["abstention_evidence"]).reject { |item| item.to_s.empty? }
      return true if observed.empty?

      given = prompt.to_s.downcase
      usable = observed.map(&:downcase).reject { |item| given.include?(item) }
      return false if usable.empty?

      # The subject and the observation must be RELATED, which one sentence expresses and a
      # file listing structurally cannot: a listing contains every real path, in no relation
      # to anything, so an agent that echoes one would otherwise satisfy this by accident.
      # This is the same rule the control suite applies, for the same reason.
      #
      # Split on sentence-ENDING punctuation only. Splitting on `.` would cut `lib/x.rb` in
      # half and destroy the very paths being compared.
      #
      # A short subject like `lib/` is contained in the evidence path itself, so a bare
      # containment test would be satisfied by the path alone. The subject must be named
      # somewhere OTHER than inside the observation.
      forms = subject_forms(subject)
      answer.to_s.split(/(?<=[.!?])\s+|\n/).any? do |sentence|
        line = sentence.downcase
        usable.any? do |item|
          next false unless line.include?(item)

          rest = line.gsub(item, " ")
          forms.any? { |form| rest.include?(form) }
        end
      end
    end

    # The ways an agent may reasonably refer to the subject it was asked about.
    def subject_forms(subject)
      base = subject.downcase.chomp("/")
      forms = [subject.downcase, base]
      forms << File.basename(base) unless base.empty?
      forms << "#{base}/" unless base.empty?
      forms.reject(&:empty?).uniq
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
