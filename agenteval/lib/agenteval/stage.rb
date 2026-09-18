# frozen_string_literal: true

module Agenteval
  # Where a trial ended, derived from what the agent left behind rather than from its own
  # account of itself. A single `failed` bucket cannot distinguish "never acted" from
  # "acted and wrote the wrong code", and that distinction was the whole finding of the
  # 2026-09-17 review: 28 of 28 failures were the same abort, and 8 of the solves were the
  # same abort too.
  #
  # The signals are observable facts: whether the workspace changed, whether the process
  # ran out of budget, what the agent's own diagnostics say about where it stopped.
  module Stage
    # Ordered most-specific first; the first match wins.
    PLAN_REJECTED = "plan_rejected"
    NEVER_ACTED = "never_acted"
    TIMED_OUT = "timed_out"
    ACTED_UNVERIFIED = "acted_unverified"
    ACTED_VERIFIED = "acted_verified"

    ALL = [PLAN_REJECTED, NEVER_ACTED, TIMED_OUT, ACTED_UNVERIFIED, ACTED_VERIFIED].freeze

    # Phrases the agent prints when its own review loop refused to accept a plan. These are
    # read from the product's own vocabulary, not invented here.
    PLAN_GATE_PHRASES = [
      "no plan passed review",
      "did not pass review",
      "plan was rejected"
    ].freeze

    def self.of(workspace, status:)
      return TIMED_OUT if workspace.timed_out

      touched = !workspace.mutations.empty?
      return ACTED_VERIFIED if touched && status == :solved
      return ACTED_UNVERIFIED if touched

      return PLAN_REJECTED if plan_rejected?(workspace.answer)

      NEVER_ACTED
    end

    def self.plan_rejected?(answer)
      text = answer.to_s.downcase
      PLAN_GATE_PHRASES.any? { |phrase| text.include?(phrase) }
    end

    # A stage is "acted" when the agent changed the workspace, whatever the outcome.
    def self.acted?(stage) = [ACTED_VERIFIED, ACTED_UNVERIFIED].include?(stage)
  end
end
