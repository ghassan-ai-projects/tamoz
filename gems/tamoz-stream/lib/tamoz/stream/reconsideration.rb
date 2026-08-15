# frozen_string_literal: true

require "tamoz/core"
require "tamoz/stream/gen"
require "tamoz/stream/errors"

Tamoz::Stream::Gen.load!

module Tamoz
  module Stream
    # T6.1/P6: the wire Reconsideration payload helpers. P6 moved the
    # JUDGMENT (withdraw/downgrade/stand) and the COMPENSATION (type + own
    # risk from the intent catalog) into the fixed graph's judge/compensate
    # nodes — the domain tables (COMPENSATION_RISK, WITHDRAW_TYPES,
    # DOWNGRADE_TYPES, family_for, RISK_ORDER) are deleted; the module keeps
    # only the strict wire parsing the envelope uses.
    module Reconsideration
      MAX_COMMANDS = 64

      # The wire Reconsideration message parsed into plain hashes.
      Parsed = Data.define(:prior_decision, :commands, :outcomes, :correction) do
        def to_h
          {prior_decision:, commands:, outcomes:, correction:}
        end
      end

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
        normalized = Tamoz::Core.normalize_reconsideration(hash)
        Parsed.new(
          prior_decision: normalized.fetch("prior_decision"),
          commands: Array(normalized["commands"]),
          outcomes: Array(normalized["outcomes"]),
          correction: normalized.fetch("correction")
        )
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
