# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/gen"
require "tamoz/stream/errors"

Tamoz::Stream::Gen.load!

module Tamoz
  module Stream
    # T6.1 (PLAN_TAMOZ_STREAM_BUILD T6.1): RECONSIDER episodes. The stream
    # detects the condition deterministically (a correction superseded a
    # Situation version whose accepted Decision produced an already-executed
    # command) and admits a kind: RECONSIDER episode carrying the prior
    # Decision, the executed commands, their outcomes, and the correction
    # (PROTOCOL §4.2). What to DO about it — withdraw, downgrade, or let it
    # stand — is the judgment this module owns.
    #
    # The judgment policy is deterministic and documented, exactly like the
    # DIAGNOSE path's watch-condition preference: the correction names the
    # commands it invalidates; a command that never left the queue is
    # withdrawn, a command whose effect already exists is DOWNGRADED (the
    # freezer scenario's right answer — the observation history stays intact
    # and the corrective note rides along, rather than the audit trail being
    # torn out), and an unaffected command stands. The graph node may
    # supersede the policy by returning its own judgements, but the default
    # must be defensible on its own.
    #
    # A compensating intent passes the full policy pipeline under ITS OWN risk
    # class — never assumed safe merely because it undoes something
    # (PROTOCOL §4.2: withdrawing a maintenance ticket is R1; cancelling a
    # product transfer already in motion could be R3), and never escalated
    # above the episode's risk ceiling.
    class Reconsideration
      # The wire Reconsideration message parsed into plain hashes.
      Parsed = Data.define(:prior_decision, :commands, :outcomes, :correction) do
        def to_h
          {prior_decision:, commands:, outcomes:, correction:}
        end
      end

      # One command's judgment.
      Judgement = Data.define(:command_id, :intent_type, :decision, :reason) do
        def let_stand? = decision == :let_stand
      end

      # Risk class a compensating intent carries per action family
      # (PROTOCOL §4.2). Compensation is never "safe because it undoes".
      COMPENSATION_RISK = {
        "maintenance" => "R1",
        "transfer" => "R3"
      }.freeze
      DEFAULT_COMPENSATION_RISK = "R1"

      # Compensating intent types, keyed by the original intent family.
      WITHDRAW_TYPES = {
        "maintenance" => "withdraw_maintenance_ticket",
        "transfer" => "cancel_product_transfer"
      }.freeze
      DOWNGRADE_TYPES = {
        "maintenance" => "downgrade_maintenance_ticket",
        "transfer" => "downgrade_product_transfer"
      }.freeze

      MAX_COMMANDS = 64
      MAX_INTENTS = 16

      class ReconsiderationError < StreamError
        CATEGORY = "stream_reconsideration_invalid"
      end

      # Parses and validates the wire Reconsideration payload. Returns a
      # Parsed value; a missing or malformed payload is a typed refusal — a
      # RECONSIDER episode without the prior decision cannot judge.
      def self.parse(wire)
        if wire.nil? || wire.prior_decision_json.to_s.empty?
          raise ReconsiderationError,
                "a RECONSIDER episode requires the prior decision"
        end

        Parsed.new(
          prior_decision: strict_parse(wire.prior_decision_json, "prior decision"),
          commands: Array(wire.executed_command_json).first(MAX_COMMANDS).map do |raw|
            strict_parse(raw, "executed command")
          end,
          outcomes: Array(wire.observed_outcome_json).first(MAX_COMMANDS).map do |raw|
            strict_parse(raw, "observed outcome")
          end,
          correction: strict_parse(wire.correction_json, "correction")
        )
      end

      # Rebuilds a Parsed value from the runner-injected payload hash (the
      # durable payload carries the parsed form, never the wire bytes). Key
      # normalization mirrors the memory admission convention: the payload may
      # arrive symbol- or string-keyed. A missing member is a typed refusal —
      # the durable payload must never be half-shaped.
      def self.from_hash(hash)
        unless hash.is_a?(Hash)
          raise ReconsiderationError, "reconsideration payload is not an object"
        end

        normalized = hash.transform_keys(&:to_s)
        missing = %w[prior_decision commands outcomes correction].reject do |key|
          normalized.key?(key)
        end
        unless missing.empty?
          raise ReconsiderationError,
                "reconsideration payload is missing: #{missing.join(", ")}"
        end

        Parsed.new(
          prior_decision: normalized.fetch("prior_decision"),
          commands: Array(normalized["commands"]),
          outcomes: Array(normalized["outcomes"]),
          correction: normalized.fetch("correction")
        )
      end

      # The deterministic judgment: one entry per executed command. A command
      # is invalidated only when the correction names it (invalidates/refutes/
      # explains references the command id or the intent digest it executed).
      # Invalidated: pending commands are withdrawn, dispatched commands are
      # downgraded, everything else stands. The judgment itself never gates on
      # the risk ceiling — that is the compensation builder's decision (a
      # ceiling too low for a compensation leaves the command standing).
      def self.judge(parsed:)
        invalidated = invalidated_command_ids(parsed)
        parsed.commands.first(MAX_COMMANDS).map do |command|
          unless invalidated.include?(command.fetch("command_id"))
            next Judgement.new(
              command_id: command.fetch("command_id").to_s.byteslice(0, 256),
              intent_type: command.fetch("intent_type", "").to_s.byteslice(0, 256),
              decision: :let_stand,
              reason: "correction does not reference this command"
            )
          end

          if pending?(command)
            Judgement.new(
              command_id: command.fetch("command_id").to_s.byteslice(0, 256),
              intent_type: command.fetch("intent_type", "").to_s.byteslice(0, 256),
              decision: :withdraw,
              reason: "corrected before dispatch"
            )
          else
            Judgement.new(
              command_id: command.fetch("command_id").to_s.byteslice(0, 256),
              intent_type: command.fetch("intent_type", "").to_s.byteslice(0, 256),
              decision: :downgrade,
              reason: "effect exists; correction explains the initial signal"
            )
          end
        end
      end

      # Builds the compensating intents for the judgements that act. Each
      # intent carries its OWN risk class (from the action family, never
      # inherited from the original intent), is bounded to the decision schema,
      # and is refused when its risk class exceeds the episode's ceiling —
      # the episode never compensates above what the runtime allowed.
      # `episode` is the episode identity hash (episode_id/attempt_id/fence/
      # tenant_id/situation_id/situation_version).
      def self.build_compensating_intents(judgements, episode:, snapshot:, now: Time.now)
        decision_id = "decision.#{episode.fetch(:episode_id)}." \
                      "#{episode.fetch(:attempt_id)}.#{episode.fetch(:fence)}"
        judgements.select { |j| j.decision != :let_stand }.first(MAX_INTENTS).filter_map do |judgement|
          family = family_for(judgement.intent_type)
          risk_class = COMPENSATION_RISK.fetch(family, DEFAULT_COMPENSATION_RISK)
          next if above_ceiling?(risk_class, episode.fetch(:risk_ceiling))

          build_intent(
            type: compensation_type(judgement.decision, family),
            risk_class:,
            decision_id:,
            episode:, snapshot:, now:,
            compensates: judgement.command_id.to_s.byteslice(0, 256),
            parameters: compensation_parameters(judgement)
          )
        end
      end

      # The compensating intent digest must cover the intent WITHOUT its own
      # digest (the shared :intent domain), like every other intent.
      def self.build_intent(type:, risk_class:, decision_id:, episode:, snapshot:,
                            now:, compensates: nil, parameters: {})
        intent = {
          "intent_id" => "intent.#{episode.fetch(:episode_id)}.#{episode.fetch(:attempt_id)}." \
                         "#{episode.fetch(:fence)}.#{type}",
          "decision_id" => decision_id,
          "tenant_id" => episode.fetch(:tenant_id),
          "situation_id" => episode.fetch(:situation_id),
          "situation_version" => episode.fetch(:situation_version),
          "type" => type,
          "risk_class" => risk_class,
          "parameters" => parameters,
          "expires_at" => (now + 86_400).utc.iso8601
        }
        intent["compensates"] = compensates if compensates
        intent.merge("intent_digest" => Tamoz::Core.digest(
          :intent, intent.reject { |key, _| key == "intent_digest" }
        ))
      end

      def self.compensation_type(decision, family)
        types = decision == :withdraw ? WITHDRAW_TYPES : DOWNGRADE_TYPES
        types.fetch(family, decision == :withdraw ? "withdraw_command" : "downgrade_command")
      end

      def self.compensation_risk_for(intent_type)
        COMPENSATION_RISK.fetch(family_for(intent_type), DEFAULT_COMPENSATION_RISK)
      end

      # Validation used by the decision builder at its boundary: a
      # compensating intent offered by the graph must carry its own verified
      # digest, a known type, a compensates target, a risk class WITHIN the
      # ceiling, AND the family's OWN class — a graph labeling
      # cancel_product_transfer as R1 is refused, not honored (the "own risk
      # class" property is enforced here, not merely by convention).
      def self.valid_compensation?(intent, risk_ceiling:)
        return false unless intent.is_a?(Hash)
        return false unless intent.fetch("compensates", "").is_a?(String) &&
                            !intent.fetch("compensates", "").empty?
        return false unless Tamoz::Core.verify_digest(
          :intent, intent.reject { |key, _| key == "intent_digest" },
          intent.fetch("intent_digest", "")
        )

        family = family_for(intent.fetch("type", ""))
        expected = COMPENSATION_RISK.fetch(family, DEFAULT_COMPENSATION_RISK)
        return false unless intent.fetch("risk_class", "").to_s == expected

        !above_ceiling?(intent.fetch("risk_class", ""), risk_ceiling)
      end

      def self.family_for(intent_type)
        case intent_type.to_s
        when /^maintenance\./ then "maintenance"
        # Word-bounded: "move_asset" or "remove" must not be classified as a
        # physical transfer — misclassification would escalate the compensation
        # risk class.
        when /\b(?:transfer|shipment|move)\b/ then "transfer"
        else "maintenance"
        end
      end

      def self.above_ceiling?(risk_class, ceiling)
        risk = RISK_ORDER.fetch(risk_class.to_s.downcase, 99)
        risk > RISK_ORDER.fetch(ceiling.to_s, 0)
      end

      RISK_ORDER = {
        "r0" => 0, "r1" => 1, "r2" => 2, "r3" => 3, "r4" => 4
      }.freeze

      def self.pending?(command)
        %w[pending queued scheduled].include?(command.fetch("status", "").to_s)
      end

      def self.invalidated_command_ids(parsed)
        correction = parsed.correction
        return [] unless correction.is_a?(Hash)

        Array(correction["invalidates"]).map(&:to_s) +
          Array(correction["explains"]).map(&:to_s) +
          referenced_intent_digests(parsed, Array(correction["refutes"]).map(&:to_s))
      end

      def self.referenced_intent_digests(parsed, refuted_digests)
        return [] if refuted_digests.empty?

        parsed.commands.filter_map do |command|
          command.fetch("command_id") if refuted_digests.include?(command["intent_digest"].to_s)
        end
      end

      def self.compensation_parameters(judgement)
        {
          "note" => String(judgement.reason).byteslice(0, 512),
          "priority" => judgement.decision == :downgrade ? "routine" : nil
        }.compact
      end

      def self.strict_parse(raw, name)
        document = raw.to_s.dup.force_encoding(Encoding::UTF_8)
        unless document.valid_encoding?
          raise ReconsiderationError, "#{name} is not valid UTF-8"
        end

        Tamoz::Core.parse_json_strict(document)
      rescue Tamoz::Core::JCS::Error => error
        raise ReconsiderationError, "#{name} is malformed: #{error.message.byteslice(0, 256)}"
      end
    end
  end
end
