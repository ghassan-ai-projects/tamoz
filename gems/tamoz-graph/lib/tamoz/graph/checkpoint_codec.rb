# frozen_string_literal: true

require "json"

module Tamoz
  module Graph
    class CheckpointCodec
      FORMAT = "tamoz.graph.checkpoint"
      FORMAT_VERSION = 1
      REQUEST_FORMAT = "tamoz.graph.request"
      DEFAULT_MAX_BYTES = 16 * 1024 * 1024
      MAX_BYTES = 64 * 1024 * 1024
      WIRE_SIZE = 16

      attr_reader :definition, :definition_digest, :state_codec, :max_bytes

      def initialize(
        definition:,
        definition_digest:,
        state_codec:,
        max_bytes: DEFAULT_MAX_BYTES
      )
        validate_dependencies!(definition, state_codec, max_bytes)
        @definition = definition
        @definition_digest = String(definition_digest).dup.freeze
        @state_codec = state_codec
        @max_bytes = max_bytes
        @values = CheckpointValues.new(definition:, state_codec:)
        @routes = CheckpointRoutes.new(@values)
        @progress = CheckpointProgress.new(@values)
        @frontier = CheckpointFrontier.new(@values)
        @outcomes = CheckpointOutcomes.new(@values, @routes)
        freeze
      end

      def dump(attributes)
        wire = checkpoint_wire(attributes)
        validate_identity!(wire)
        bytes = JSON.generate(wire)
        enforce_size!(bytes)
        bytes.freeze
      rescue KeyError => error
        raise CheckpointCorruptionError.new(
          "checkpoint attributes are incomplete: #{error.key.inspect}"
        ), cause: error
      rescue JSON::GeneratorError => error
        raise CheckpointCorruptionError.new(
          "checkpoint attributes cannot be encoded: #{error.message}"
        ), cause: error
      end

      def load(bytes, validate_identity: true)
        text = validate_input_bytes(bytes)
        wire = JSON.parse(text, create_additions: false, max_nesting: 512)
        unless JSON.generate(wire) == text
          raise CheckpointCorruptionError, "checkpoint envelope is not canonical JSON"
        end
        @values.require_array!(wire, WIRE_SIZE, "checkpoint envelope")
        strict = validate_identity
        validate_identity!(wire) if strict

        decoded_attributes(wire, strict:)
      rescue CheckpointVersionError, CheckpointCorruptionError
        raise
      rescue JSON::ParserError, JSON::NestingError => error
        raise CheckpointCorruptionError.new(
          "invalid checkpoint JSON: #{error.message}"
        ), cause: error
      rescue IndexError, TypeError => error
        raise CheckpointCorruptionError.new("checkpoint envelope is malformed"), cause: error
      end

      def dump_outcome(outcome)
        @outcomes.dump_outcome(outcome)
      end

      def dump_outcome_writes(outcome)
        @outcomes.dump_outcome_writes(outcome)
      end

      def load_outcome(metadata:, writes:)
        @outcomes.load_outcome(metadata:, writes:)
      end

      def dump_request_payload(operation, payload)
        return state_codec.dump(payload) unless operation.to_s == "resume"

        JSON.generate(
          [REQUEST_FORMAT, 1, "resume", @progress.encode_resume_values(payload)]
        ).freeze
      rescue JSON::GeneratorError => error
        raise CheckpointCorruptionError.new(
          "resume request payload cannot be encoded"
        ), cause: error
      end

      def load_request_payload(operation, bytes)
        return @values.load_value(bytes) unless operation.to_s == "resume"

        wire = @values.parse_canonical_json(bytes, "resume request")
        @values.require_array!(wire, 4, "resume request")
        unless wire.fetch(0) == REQUEST_FORMAT &&
               wire.fetch(1) == 1 &&
               wire.fetch(2) == "resume"
          raise CheckpointVersionError, "resume request format is unsupported"
        end

        @progress.decode_resume_values(wire.fetch(3))
      end

      private

      def validate_dependencies!(definition, state_codec, max_bytes)
        validate_definition!(definition)
        unless state_codec.respond_to?(:dump) && state_codec.respond_to?(:load)
          raise ConfigurationError, "checkpoint codec requires a StateCodec-compatible value"
        end
        unless max_bytes.is_a?(Integer) && max_bytes.positive? && max_bytes <= MAX_BYTES
          raise ConfigurationError,
                "checkpoint max_bytes must be between 1 and #{MAX_BYTES}"
        end
      end

      def validate_definition!(definition)
        unless definition.respond_to?(:channels) &&
               definition.respond_to?(:nodes) &&
               definition.respond_to?(:name) &&
               definition.respond_to?(:version)
          raise ConfigurationError, "checkpoint codec requires a graph definition"
        end
      end

      def checkpoint_wire(attributes)
        [
          FORMAT,
          FORMAT_VERSION,
          String(attributes.fetch(:graph_name)),
          String(attributes.fetch(:graph_version)),
          String(attributes.fetch(:definition_digest)),
          String(attributes.fetch(:execution_id)),
          attributes.fetch(:status).to_s,
          attributes.fetch(:logical_step),
          @values.verify_canonical_value_bytes(attributes.fetch(:state_bytes)),
          @frontier.encode_frontier(attributes.fetch(:frontier)),
          @outcomes.encode_pending(attributes.fetch(:pending)),
          @progress.encode_interrupts(attributes.fetch(:interrupts)),
          @progress.encode_resume_values(attributes.fetch(:resume_values)),
          @progress.encode_attempts(attributes.fetch(:attempts)),
          @values.dump_value(attributes.fetch(:failure)),
          attributes.fetch(:total_tasks)
        ]
      end

      def decoded_attributes(wire, strict:)
        attributes = {
          graph_name: wire.fetch(2).dup.freeze,
          graph_version: wire.fetch(3).dup.freeze,
          definition_digest: wire.fetch(4).dup.freeze,
          execution_id: @values.bounded_string!(wire.fetch(5), "execution id"),
          status: @values.status!(wire.fetch(6)),
          logical_step: @values.non_negative_integer!(wire.fetch(7), "logical step"),
          state_bytes: @values.verify_canonical_value_bytes(wire.fetch(8)),
          frontier: @frontier.decode_frontier(wire.fetch(9), strict:),
          pending: @outcomes.decode_pending(wire.fetch(10)),
          interrupts: @progress.decode_interrupts(wire.fetch(11)),
          resume_values: @progress.decode_resume_values(wire.fetch(12)),
          attempts: @progress.decode_attempts(wire.fetch(13)),
          failure: @values.load_value(wire.fetch(14)),
          total_tasks: @values.non_negative_integer!(wire.fetch(15), "total tasks")
        }
        attributes[:state] = @values.decode_state(attributes.fetch(:state_bytes), strict:)
        attributes.freeze
      end

      def validate_input_bytes(bytes)
        unless bytes.is_a?(String)
          raise CheckpointCorruptionError, "checkpoint payload must be a String"
        end
        enforce_size!(bytes)
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          raise CheckpointCorruptionError, "checkpoint payload is not valid UTF-8"
        end

        text
      end

      def enforce_size!(bytes)
        return bytes if bytes.bytesize <= max_bytes

        raise CheckpointCorruptionError,
              "checkpoint payload exceeds #{max_bytes} bytes"
      end

      def validate_identity!(wire)
        unless wire.is_a?(Array) && wire.fetch(0, nil) == FORMAT
          raise CheckpointCorruptionError, "checkpoint format is invalid"
        end
        unless wire.fetch(1, nil) == FORMAT_VERSION
          raise CheckpointVersionError,
                "unsupported checkpoint format version #{wire.fetch(1, nil).inspect}"
        end
        unless wire.fetch(2, nil) == definition.name &&
               wire.fetch(3, nil) == definition.version &&
               wire.fetch(4, nil) == definition_digest
          raise CheckpointVersionError, "checkpoint graph identity is incompatible"
        end
      end

      private_constant :DEFAULT_MAX_BYTES, :MAX_BYTES, :WIRE_SIZE, :REQUEST_FORMAT
    end
  end
end
