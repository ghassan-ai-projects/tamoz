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

        key = effects.key(
          execution_id: context.execution_id,
          task_id: context.task_id,
          call_index:,
          operation:
        )
        decision = effects.prepare(
          execution_id: context.execution_id,
          task_id: context.task_id,
          call_index:,
          operation:,
          safety: safety.to_s,
          request:
        )
        reconciliation = nil

        if decision.action == :reconcile
          if decision.record.current_attempt >= MAX_ATTEMPTS
            decision = effects.reconcile(
              key:,
              disposition: :unknown,
              actor:,
              evidence: {"reason" => "reconciliation attempt budget exhausted"}
            )
            reconciliation = "unknown"
          else
            disposition, evidence, recovered = reconcile.call
            reconciliation = disposition.to_s
            decision = effects.reconcile(
              key:,
              disposition:,
              actor:,
              evidence: evidence || {}
            )
            if decision.action == :return
              return Outcome.new(
                status: :succeeded,
                value: recovered,
                error: nil,
                effect_key: key,
                attempt_number: decision.record.current_attempt,
                reconciliation:,
                reused: true
              )
            end
          end
        end

        case decision.action
        when :return
          attempt = terminal_attempt(decision.record)
          return Outcome.new(
            status: :succeeded,
            value: attempt&.result,
            error: nil,
            effect_key: key,
            attempt_number: decision.record.current_attempt,
            reconciliation:,
            reused: true
          )
        when :failed
          attempt = terminal_attempt(decision.record)
          return Outcome.new(
            status: :failed,
            value: nil,
            error: attempt&.error,
            effect_key: key,
            attempt_number: decision.record.current_attempt,
            reconciliation:,
            reused: true
          )
        when :unknown
          return Outcome.new(
            status: :unknown,
            value: nil,
            error: nil,
            effect_key: key,
            attempt_number: decision.record.current_attempt,
            reconciliation:,
            reused: false
          )
        when :wait
          return Outcome.new(
            status: :wait,
            value: nil,
            error: nil,
            effect_key: key,
            attempt_number: decision.record.current_attempt,
            reconciliation:,
            reused: false
          )
        when :execute
          token = decision.attempt_token
          effects.start(key:, attempt_token: token)
          begin
            value = perform.call
          rescue ToolError => error
            effects.complete(
              key:,
              attempt_token: token,
              status: :failed,
              error: {"class" => error.class.name, "message" => error.message}
            )
            return Outcome.new(
              status: :failed,
              value: nil,
              error: {"class" => error.class.name, "message" => error.message},
              effect_key: key,
              attempt_number: decision.record.current_attempt,
              reconciliation:,
              reused: false
            )
          end
          record = effects.complete(
            key:,
            attempt_token: token,
            status: :succeeded,
            result: value
          )
          Outcome.new(
            status: :succeeded,
            value:,
            error: nil,
            effect_key: key,
            attempt_number: record.current_attempt,
            reconciliation:,
            reused: false
          )
        else
          raise CheckpointCorruptionError,
                "unhandled effect decision #{decision.action.inspect}"
        end
      end

      def terminal_attempt(record)
        record.attempts.reverse.find { |attempt| attempt.status == :succeeded } ||
          record.attempts.last
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

      def observe(path)
        return {"state" => "absent"} unless path.exist?
        return {"state" => "not_a_regular_file"} unless path.file?
        return {"state" => "symlink"} if path.symlink?

        content = path.read(mode: "rb")
        {
          "state" => Digest::SHA256.hexdigest(content),
          "mode" => path.stat.mode & 0o777
        }
      rescue SystemCallError
        {"state" => "unreadable"}
      end

      def mode_matches?(tool, intent, observed)
        return true unless tool == "create_file"
        return true unless intent.key?("after_mode")

        observed["mode"] == intent.fetch("after_mode")
      end
    end
  end
end
