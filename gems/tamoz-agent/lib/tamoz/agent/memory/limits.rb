# frozen_string_literal: true

module Tamoz
  module Agent
    module Memory
      # P11 §8 (C9): the bounded memory limits. Budgets are per-turn, per-session
      # (the session's `memory_epoch` snapshot). Overflow behavior: explicit
      # retrieval truncates by rank (never silently); automatic injection over
      # budget drops the lowest-ranked admissible record and records the drop in
      # the trace. The memory budget is separate from input/tools/history.
      MemoryLimits = {
        max_statement_bytes: 4_096,
        max_source_refs: 16,
        max_candidates_per_sweep: 64,
        max_consolidation_candidates: 8,
        max_consolidation_tokens: 2_048,
        retrieval_token_budget: 1_024,
        max_injected_knowledge: 8,
        max_lexical_hits: 200,
        retention_default_seconds: 86_400.0
      }.freeze

      # P11 §3 (C5): the retrieval-eligible state set. Never superseded,
      # quarantined, deleted, purged, or rejected.
      ELIGIBLE_STATES = %i[active consolidated].freeze

      # P11 §3 (C4): the legacy sentinel for sessions built before P11 (exact
      # P9 `LEGACY_SKILL_EPOCH` pattern — filled at load, RECORD_VERSION stays 1).
      LEGACY_MEMORY_EPOCH = "none"

      # The deterministic admission gate (C7): a candidate may only be admitted
      # through (a) a completed bounded episode with an independently observed
      # Outcome, (b) an explicit authorized owner request, or (c) a consolidation
      # candidate that passed the deterministic gates. A model may propose a
      # candidate (consolidation); it never admits one.
      ADMISSION_GATES = %i[episode owner_request consolidation].freeze
    end
  end
end
