# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent/errors"
require "tamoz/agent/reasoning_document"

module Tamoz
  module Agent
    # P2/§8.3: budget enforcement FROM RECEIPTS, never from counted events. The
    # controller is a PURE projection: every budget_state is recomputed from
    # (committed state, journaled receipt), so a replayed or fence+1
    # redelivered run reproduces the same committed states and the same
    # reconciliation. Pre-dispatch "reservation" is a CHECK against the
    # committed projection — not a debit — so a reused receipt never
    # double-counts. Missing usage stays usage_unavailable, never zero.
    #
    # The wire envelope (Agentic Stream's EpisodeBudget) is the only budget
    # input; this controller adds nothing aggregate (Go's costcontrol.Controller
    # stays the sole aggregate authority).
    class ReceiptBudgetController
      ZERO = {
        "model_calls_used" => 0,
        "tool_calls_used" => 0,
        "input_tokens" => 0,
        "output_tokens" => 0,
        "tool_result_bytes_used" => 0,
        "cost_microunits" => 0,
        "provider_retries_used" => 0
      }.freeze

      # budget: the wire EpisodeBudget hash (nil fields are unbounded).
      def initialize(budget)
        @budget = budget || {}
        freeze
      end

      def empty? = @budget.empty?

      # The CHECK before a model call. Exhaustion raises typed, BEFORE any
      # provider call.
      def check_model_call!(state)
        max = @budget["max_model_calls"]
        return if max.nil? || max.to_i <= 0

        used = (state || ZERO).fetch("model_calls_used", 0).to_i
        if used + 1 > max.to_i
          raise StreamBudgetExceededError,
                "model call budget exhausted at #{used} calls (max #{max})"
        end
      end

      # Tool calls this episode may still dispatch. An unset wire limit is one document's worth.
      def tool_calls_left(state)
        [tool_limit - used(state, "tool_calls_used"), 0].max
      end

      # True when the next reason call is the last either budget allows: it must decide.
      def final_call?(state)
        return true if tool_calls_left(state).zero?

        max = @budget["max_model_calls"].to_i
        max.positive? && used(state, "model_calls_used") + 1 >= max
      end

      # True when the call just made was the last either budget allows.
      def spent?(state)
        return true if tool_calls_left(state).zero?

        max = @budget["max_model_calls"].to_i
        max.positive? && used(state, "model_calls_used") >= max
      end

      def tool_limit
        max = @budget["max_tool_calls"].to_i
        max.positive? ? max : ReasoningDocument::MAX_TOOL_REQUESTS
      end

      # Reconcile a model receipt: the state advances by one call + the
      # receipt's usage. Usage.unavailable contributes nothing (it is never
      # fabricated as zero tokens).
      def reconcile_model(state, usage)
        base = (state || ZERO).dup
        base["model_calls_used"] = base.fetch("model_calls_used", 0).to_i + 1
        add_available_usage(base, usage)
        enforce_input_token_budget!(base)
        enforce_output_token_budget!(base)
        enforce_cost_budget!(base)
        base
      end

      # Reconcile a tool result: one tool call + its result bytes.
      def reconcile_tool(state, projection)
        base = (state || ZERO).dup
        base["tool_calls_used"] = base.fetch("tool_calls_used", 0).to_i + 1
        bytes = Integer(projection.fetch("result_bytes", 0))
        base["tool_result_bytes_used"] = base.fetch("tool_result_bytes_used", 0).to_i + bytes
        enforce_tool_result_byte_budget!(base)
        base
      end

      private

      def used(state, key) = (state || ZERO).fetch(key, 0).to_i

      def add_available_usage(base, usage)
        return unless usage && usage.available

        base["input_tokens"] = base.fetch("input_tokens", 0).to_i + usage.input_tokens
        base["output_tokens"] = base.fetch("output_tokens", 0).to_i + usage.output_tokens
        base["cost_microunits"] = base.fetch("cost_microunits", 0).to_i + usage.cost_microunits
      end

      def enforce_input_token_budget!(base)
        max = @budget["max_input_tokens"]
        return if max.nil? || max.to_i <= 0

        if base.fetch("input_tokens", 0).to_i > max.to_i
          raise StreamBudgetExceededError, "input token budget exhausted"
        end
      end

      def enforce_output_token_budget!(base)
        max = @budget["max_output_tokens"]
        return if max.nil? || max.to_i <= 0

        if base.fetch("output_tokens", 0).to_i > max.to_i
          raise StreamBudgetExceededError, "output token budget exhausted"
        end
      end

      def enforce_cost_budget!(base)
        max = @budget["max_cost_microunits"]
        return if max.nil? || max.to_i <= 0

        if base.fetch("cost_microunits", 0).to_i > max.to_i
          raise StreamBudgetExceededError, "cost budget exhausted"
        end
      end

      def enforce_tool_result_byte_budget!(base)
        max = @budget["max_total_tool_result_bytes"]
        return if max.nil? || max.to_i <= 0

        if base.fetch("tool_result_bytes_used", 0).to_i > max.to_i
          raise StreamBudgetExceededError, "tool result byte budget exhausted"
        end
      end
    end

    # The typed budget error the graph nodes raise; the runner maps its
    # category (the shared wire category name) to
    # TERMINAL_STATUS_BUDGET_EXHAUSTED.
    class StreamBudgetExceededError < Error
      CATEGORY = "stream_budget_exceeded"
    end
  end
end
