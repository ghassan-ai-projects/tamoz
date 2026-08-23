# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent/errors"

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

      # The CHECK before a tool execution.
      def check_tool_call!(state)
        max = @budget["max_tool_calls"]
        return if max.nil? || max.to_i <= 0

        used = (state || ZERO).fetch("tool_calls_used", 0).to_i
        if used + 1 > max.to_i
          raise StreamBudgetExceededError,
                "tool call budget exhausted at #{used} calls (max #{max})"
        end
      end

      # Reconcile a model receipt: the state advances by one call + the
      # receipt's usage. Usage.unavailable contributes nothing (it is never
      # fabricated as zero tokens).
      def reconcile_model(state, usage)
        base = (state || ZERO).dup
        base["model_calls_used"] = base.fetch("model_calls_used", 0).to_i + 1
        if usage && usage.available
          base["input_tokens"] = base.fetch("input_tokens", 0).to_i + usage.input_tokens
          base["output_tokens"] = base.fetch("output_tokens", 0).to_i + usage.output_tokens
          base["cost_microunits"] = base.fetch("cost_microunits", 0).to_i + usage.cost_microunits
        end
        check_input_tokens!(base)
        check_output_tokens!(base)
        check_cost!(base)
        base
      end

      # Reconcile a tool result: one tool call + its result bytes.
      def reconcile_tool(state, projection)
        base = (state || ZERO).dup
        base["tool_calls_used"] = base.fetch("tool_calls_used", 0).to_i + 1
        bytes = Integer(projection.fetch("result_bytes", 0))
        base["tool_result_bytes_used"] = base.fetch("tool_result_bytes_used", 0).to_i + bytes
        check_tool_bytes!(base)
        base
      end

      private

      def check_input_tokens!(base)
        max = @budget["max_input_tokens"]
        return if max.nil? || max.to_i <= 0

        if base.fetch("input_tokens", 0).to_i > max.to_i
          raise StreamBudgetExceededError, "input token budget exhausted"
        end
      end

      def check_output_tokens!(base)
        max = @budget["max_output_tokens"]
        return if max.nil? || max.to_i <= 0

        if base.fetch("output_tokens", 0).to_i > max.to_i
          raise StreamBudgetExceededError, "output token budget exhausted"
        end
      end

      def check_cost!(base)
        max = @budget["max_cost_microunits"]
        return if max.nil? || max.to_i <= 0

        if base.fetch("cost_microunits", 0).to_i > max.to_i
          raise StreamBudgetExceededError, "cost budget exhausted"
        end
      end

      def check_tool_bytes!(base)
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
