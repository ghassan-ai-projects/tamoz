# frozen_string_literal: true

require "digest"

module Tamoz
  module Agent
    # One place where every externally visible agent operation crosses the effect
    # journal. It owns no state and creates no second effect model: it drives the
    # existing `prepare` / `start` / `complete` / `reconcile` transitions on
    # `Tamoz::SQLite::EffectJournal` (or any journal with the same contract).
    module EffectDispatcher
      # An effect is never granted more than this many attempts in total. Beyond it a
      # reconcilable effect is forced to `:unknown` rather than attempted again, so a
      # reconciliation loop is impossible by construction.
      MAX_ATTEMPTS = 3

      Outcome = Data.define(
        :status,          # :succeeded | :failed | :unknown | :wait
        :value,
        :error,
        :effect_key,
        :attempt_number,
        :attempt_identity,
        :reconciliation,  # nil | "completed" | "not_applied" | "unknown"
        :reused           # true when the recorded receipt was returned without acting
      )

      module_function

      # `perform` runs the real operation and must return the receipt value.
      # `reconcile` is required for `:reconcilable` effects and must return
      # `[:completed | :not_applied | :unknown, evidence_hash, value_or_nil]`.
      def run(
        context:,
        operation:,
        safety:,
        call_index:,
        request:,
        actor:,
        reconcile: nil,
        after_start: nil,
        logical_key: nil,
        logical_identity: nil,
        &perform
      )
        effects = context.effects
        unless effects.respond_to?(:prepare)
          raise ConfigurationError,
                "durable effects require a graph task Context bound to an effect journal"
        end
        if safety.to_sym == :reconcilable && reconcile.nil?
          raise ConfigurationError, "a reconcilable effect requires a reconciler"
        end

        key, logical_key = resolve_key(
          effects, context, operation:, call_index:, logical_key:, logical_identity:
        )
        decision = effects.prepare(
          execution_id: context.execution_id,
          task_id: context.task_id,
          call_index:,
          operation:,
          safety: safety.to_s,
          request:,
          logical_key:
        )
        reconciliation = nil

        if decision.action == :reconcile
          decision, reconciliation, recovered =
            run_reconciliation(effects, key, decision, actor:, reconcile:)
          if decision.action == :return
            return recorded_outcome(
              :succeeded, decision.record, key, reconciliation:, value: recovered, reused: true
            )
          end
        end

        case decision.action
        when :return
          attempt = terminal_attempt(decision.record)
          recorded_outcome(
            :succeeded, decision.record, key, reconciliation:, value: attempt&.result, reused: true
          )
        when :failed
          attempt = terminal_attempt(decision.record)
          recorded_outcome(
            :failed, decision.record, key, reconciliation:, error: attempt&.error, reused: true
          )
        when :unknown, :wait
          recorded_outcome(decision.action, decision.record, key, reconciliation:, reused: false)
        when :execute
          execute_outcome(effects, decision, key, reconciliation:, after_start:, &perform)
        else
          raise CheckpointCorruptionError,
                "unhandled effect decision #{decision.action.inspect}"
        end
      end

      # Returns [key, logical_key] — the journal's prepare needs the effective
      # logical key (built from the identity when the caller passed none), so
      # both resolved values flow back to `run`.
      def resolve_key(effects, context, operation:, call_index:, logical_key:, logical_identity:)
        generated_logical_key = logical_key.nil? && logical_identity
        logical_key ||= build_logical_key(effects, context, logical_identity)
        key = if logical_key
                if generated_logical_key
                  logical_key
                elsif !effects.respond_to?(:logical_key)
                  raise ConfigurationError,
                        "logical effects require a journal with logical_key support"
                else
                  effects.logical_key(logical_key)
                end
              else
                effects.key(
                  execution_id: context.execution_id,
                  task_id: context.task_id,
                  call_index:,
                  operation:
                )
              end
        [key, logical_key]
      end

      # Returns [decision, reconciliation_string, recovered] — the string feeds
      # the Outcome's `reconciliation` field; `recovered` is the reconciler's
      # value, nil whenever the attempt budget was exhausted before reconciling.
      def run_reconciliation(effects, key, decision, actor:, reconcile:)
        if decision.record.current_attempt >= MAX_ATTEMPTS
          decision = effects.reconcile(
            key:,
            disposition: :unknown,
            actor:,
            evidence: {"reason" => "reconciliation attempt budget exhausted"}
          )
          [decision, "unknown", nil]
        else
          disposition, evidence, recovered = reconcile.call
          decision = effects.reconcile(
            key:,
            disposition:,
            actor:,
            evidence: evidence || {}
          )
          [decision, disposition.to_s, recovered]
        end
      end

      def recorded_outcome(status, record, key, reconciliation:, value: nil, error: nil, reused:)
        Outcome.new(
          status:,
          value:,
          error:,
          effect_key: key,
          attempt_number: record.current_attempt,
          attempt_identity: current_attempt_identity(record),
          reconciliation:,
          reused:
        )
      end

      def execute_outcome(effects, decision, key, reconciliation:, after_start:, &perform)
        token = decision.attempt_token
        effects.start(key:, attempt_token: token)
        after_start&.call
        begin
          value = perform.call
        # Spelled fully: the Tamoz::Agent::ToolError spelling is an alias that
        # only exists after the runtime facade loads, and this gem must rescue
        # correctly on its own.
        rescue Tamoz::Tools::ToolError => error
          detail = tool_error_detail(error)
          effects.complete(key:, attempt_token: token, status: :failed, error: detail)
          return recorded_outcome(
            :failed, decision.record, key, reconciliation:, error: detail, reused: false
          )
        rescue Tamoz::EffectUnknownError => error
          # A request was sent whose external outcome is unknown (e.g. an MCP
          # non-idempotent call that failed after send). Record the started
          # attempt as terminal :unknown here rather than letting it stay
          # running until a later recovery pass, and never repair it.
          detail = unknown_error_detail(error)
          effects.complete(key:, attempt_token: token, status: :unknown, error: detail)
          return recorded_outcome(
            :unknown, decision.record, key, reconciliation:, error: detail, reused: false
          )
        end
        record = effects.complete(
          key:,
          attempt_token: token,
          status: :succeeded,
          result: value
        )
        recorded_outcome(:succeeded, record, key, reconciliation:, value:, reused: false)
      end

      def build_logical_key(effects, context, identity)
        return unless identity
        unless effects.respond_to?(:logical_identity)
          raise ConfigurationError,
                "structured logical effects require a journal with logical_identity support"
        end

        effects.logical_identity(
          request_id: identity.fetch(:request_id, context.request_id),
          execution_id: identity.fetch(:execution_id, context.execution_id),
          operation: identity.fetch(:operation),
          capability_id: identity.fetch(:capability_id),
          arguments: identity.fetch(:arguments),
          authority_revision: identity.fetch(:authority_revision),
          catalog_revision: identity.fetch(:catalog_revision),
          iteration: identity.fetch(:iteration),
          sub_operation: identity.fetch(:sub_operation)
        )
      end

      # Repairability is decided from the exception *type* at the raise site and then
      # journalled, so a replayed `:failed` decision reaches the same conclusion as the
      # original attempt without re-deriving anything from message text. A record
      # written before this field existed has no key, and the reader's `== true` test
      # therefore treats it as terminal. P16: the taxonomy classes now live in
      # tamoz-core, so the serialized "class" is mapped back to the public
      # `Tamoz::Agent::Tool*` spelling via `Tamoz::Core::TOOL_ERROR_CLASS_NAMES`;
      # the repair-loop dedup keys never include the class name, so the mapping
      # cannot churn dedup.
      def tool_error_detail(error)
        {
          "class" => Tamoz::Core.serialized_tool_error_name(error.class.name),
          "message" => error.message,
          "repairable" => error.repairable?
        }.freeze
      end

      # Bounded evidence for a terminal :unknown attempt. An unknown outcome is
      # never repairable, so no repair field is recorded — the attempt is done.
      def unknown_error_detail(error)
        {
          "class" => Tamoz::Core.serialized_tool_error_name(error.class.name),
          "message" => Tamoz::Error.disclosable_message(
            error.message, fallback: "effect outcome is unknown"
          )
        }.freeze
      end

      def terminal_attempt(record)
        record.attempts.reverse.find { |attempt| attempt.status == :succeeded } ||
          record.attempts.last
      end

      def current_attempt_identity(record)
        record.attempts.find { |attempt| attempt.attempt_number == record.current_attempt }&.identity
      end

      # Filesystem reconciliation: execute only from a proven before-state, complete
      # only from a proven after-state, otherwise mark unknown. The before/after digests
      # come from the checkpointed `effect_intent`, never from the live workspace, so a
      # third-party edit cannot make an ambiguous effect look resolved.
      def reconcile_filesystem(toolbox:, intent:, receipt:)
        tool = intent.fetch("tool")
        path = toolbox.root.join(intent.fetch("path"))
        observed = observe(path)
        after_digest = intent["after_digest"]
        before_state = intent["before_state"]
        evidence = {
          "tool" => tool,
          "path" => intent.fetch("path"),
          "observed" => observed.fetch("state"),
          "expected_before" => before_state,
          "expected_after" => after_digest
        }

        if observed.fetch("state") == after_digest &&
           mode_matches?(tool, intent, observed)
          [:completed, evidence, receipt]
        elsif observed.fetch("state") == before_state
          [:not_applied, evidence, nil]
        else
          [:unknown, evidence, nil]
        end
      end

      # P16: the observation helper is homed on the toolbox in tamoz-tools so the
      # moved digest-resolution path never references agent machinery; this keeps
      # the agent-side callers (`verify_intent_before_state!`,
      # `resolved_effect_arguments`) on the same single implementation.
      def observe(path) = Tamoz::Tools::Toolbox.observe(path)

      def mode_matches?(tool, intent, observed)
        return true unless tool == "create_file"
        return true unless intent.key?("after_mode")

        observed["mode"] == intent.fetch("after_mode")
      end
    end
  end
end
