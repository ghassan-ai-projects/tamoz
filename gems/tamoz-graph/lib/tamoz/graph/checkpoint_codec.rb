# frozen_string_literal: true

require "json"

module Tamoz
  module Graph
    class CheckpointCodec
      FORMAT = "tamoz.graph.checkpoint"
      FORMAT_VERSION = 1
      DEFAULT_MAX_BYTES = 16 * 1024 * 1024
      MAX_BYTES = 64 * 1024 * 1024
      WIRE_SIZE = 16
      FRONTIER_SIZE = 6
      OUTCOME_SIZE = 7
      INTERRUPT_SIZE = 3
      SEND_SIZE = 4
      PULL_SIZE = 2
      END_SIZE = 1
      STATUSES = %w[running paused failed completed].freeze
      KINDS = %w[pull push].freeze

      attr_reader :definition, :definition_digest, :state_codec, :max_bytes

      def initialize(
        definition:,
        definition_digest:,
        state_codec:,
        max_bytes: DEFAULT_MAX_BYTES
      )
        unless definition.respond_to?(:channels) &&
               definition.respond_to?(:nodes) &&
               definition.respond_to?(:name) &&
               definition.respond_to?(:version)
          raise ConfigurationError, "checkpoint codec requires a graph definition"
        end
        unless state_codec.respond_to?(:dump) && state_codec.respond_to?(:load)
          raise ConfigurationError, "checkpoint codec requires a StateCodec-compatible value"
        end
        unless max_bytes.is_a?(Integer) && max_bytes.positive? && max_bytes <= MAX_BYTES
          raise ConfigurationError,
                "checkpoint max_bytes must be between 1 and #{MAX_BYTES}"
        end

        @definition = definition
        @definition_digest = String(definition_digest).dup.freeze
        @state_codec = state_codec
        @max_bytes = max_bytes
        @channels_by_name = definition.channels.to_h do |name, _channel|
          [name.to_s.freeze, name]
        end.freeze
        @nodes_by_name = definition.nodes.to_h do |name, _node|
          [name.to_s.freeze, name]
        end.freeze
        freeze
      end

      def dump(attributes)
        wire = [
          FORMAT,
          FORMAT_VERSION,
          String(attributes.fetch(:graph_name)),
          String(attributes.fetch(:graph_version)),
          String(attributes.fetch(:definition_digest)),
          String(attributes.fetch(:execution_id)),
          attributes.fetch(:status).to_s,
          attributes.fetch(:logical_step),
          canonical_value_bytes(attributes.fetch(:state_bytes)),
          encode_frontier(attributes.fetch(:frontier)),
          encode_pending(attributes.fetch(:pending)),
          encode_interrupts(attributes.fetch(:interrupts)),
          encode_resume_values(attributes.fetch(:resume_values)),
          encode_attempts(attributes.fetch(:attempts)),
          dump_value(attributes.fetch(:failure)),
          attributes.fetch(:total_tasks)
        ]
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

      def load(bytes)
        text = validate_input(bytes)
        wire = JSON.parse(text, create_additions: false, max_nesting: 512)
        unless JSON.generate(wire) == text
          raise CheckpointCorruptionError, "checkpoint envelope is not canonical JSON"
        end
        require_array!(wire, WIRE_SIZE, "checkpoint envelope")
        validate_identity!(wire)

        attributes = {
          graph_name: wire.fetch(2).dup.freeze,
          graph_version: wire.fetch(3).dup.freeze,
          definition_digest: wire.fetch(4).dup.freeze,
          execution_id: bounded_string!(wire.fetch(5), "execution id"),
          status: status!(wire.fetch(6)),
          logical_step: non_negative_integer!(wire.fetch(7), "logical step"),
          state_bytes: canonical_value_bytes(wire.fetch(8)),
          frontier: decode_frontier(wire.fetch(9)),
          pending: decode_pending(wire.fetch(10)),
          interrupts: decode_interrupts(wire.fetch(11)),
          resume_values: decode_resume_values(wire.fetch(12)),
          attempts: decode_attempts(wire.fetch(13)),
          failure: load_value(wire.fetch(14)),
          total_tasks: non_negative_integer!(wire.fetch(15), "total tasks")
        }
        attributes[:state] = decode_state(attributes.fetch(:state_bytes))
        attributes.freeze
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
        wire = [
          "tamoz.graph.outcome",
          1,
          outcome.task_id,
          outcome.attempt_id,
          outcome.base_checkpoint_id,
          outcome.node.to_s,
          outcome.path,
          dump_value(outcome.update),
          encode_goto(outcome.goto)
        ]
        JSON.generate(wire).freeze
      rescue JSON::GeneratorError => error
        raise CheckpointCorruptionError.new(
          "task outcome cannot be encoded"
        ), cause: error
      end

      def dump_outcome_writes(outcome)
        writes = outcome.update.keys.sort_by(&:to_s).map.with_index do |channel, index|
          {
            "write_index" => index,
            "kind" => "channel",
            "channel" => channel.to_s,
            "payload" => dump_value(outcome.update.fetch(channel))
          }.freeze
        end
        route_payload = JSON.generate(
          ["tamoz.graph.routes", 1, encode_goto(outcome.goto)]
        ).freeze
        writes << {
          "write_index" => writes.length,
          "kind" => "routes",
          "channel" => nil,
          "payload" => route_payload
        }.freeze
        writes.freeze
      end

      def load_outcome(metadata:, writes:)
        unless metadata.is_a?(Hash) && writes.is_a?(Array) && !writes.empty?
          raise CheckpointCorruptionError, "pending outcome rows are incomplete"
        end
        ordered = writes.sort_by { |write| write.fetch("write_index") }
        unless ordered.map { |write| write.fetch("write_index") } ==
               (0...ordered.length).to_a
          raise CheckpointCorruptionError,
                "pending outcome write indices are not contiguous"
        end

        update = {}
        routes = nil
        routes_seen = false
        ordered.each do |write|
          case write.fetch("kind")
          when "channel"
            if routes_seen
              raise CheckpointCorruptionError,
                    "pending channel write appears after routes"
            end
            channel = channel!(write.fetch("channel"), "pending write channel")
            if update.key?(channel)
              raise CheckpointCorruptionError,
                    "pending outcome repeats channel #{channel}"
            end
            update[channel] = load_value(write.fetch("payload"))
          when "routes"
            if routes_seen || write.fetch("channel")
              raise CheckpointCorruptionError, "pending routes write is invalid"
            end
            route_wire = parse_canonical_json(
              write.fetch("payload"),
              "pending routes"
            )
            require_array!(route_wire, 3, "pending routes")
            unless route_wire.fetch(0) == "tamoz.graph.routes" &&
                   route_wire.fetch(1) == 1
              raise CheckpointVersionError, "pending routes format is unsupported"
            end
            routes = decode_goto(route_wire.fetch(2))
            routes_seen = true
          else
            raise CheckpointCorruptionError, "pending write kind is invalid"
          end
        end
        unless ordered.last.fetch("kind") == "routes"
          raise CheckpointCorruptionError, "pending outcome is missing routes"
        end

        Outcome.new(
          task_id: bounded_string!(metadata.fetch("task_id"), "pending task id"),
          attempt_id: bounded_string!(
            metadata.fetch("attempt_id"),
            "pending attempt id"
          ),
          base_checkpoint_id: bounded_string!(
            metadata.fetch("base_checkpoint_id"),
            "pending base checkpoint id"
          ),
          node: node!(metadata.fetch("node"), "pending node"),
          path: decode_path_bytes(metadata.fetch("path")),
          update: update.freeze,
          goto: routes
        )
      rescue KeyError => error
        raise CheckpointCorruptionError.new(
          "pending outcome row is missing #{error.key.inspect}"
        ), cause: error
      end

      def dump_request_payload(operation, payload)
        return state_codec.dump(payload) unless operation.to_s == "resume"

        JSON.generate(
          ["tamoz.graph.request", 1, "resume", encode_resume_values(payload)]
        ).freeze
      rescue JSON::GeneratorError => error
        raise CheckpointCorruptionError.new(
          "resume request payload cannot be encoded"
        ), cause: error
      end

      def load_request_payload(operation, bytes)
        return load_value(bytes) unless operation.to_s == "resume"

        wire = parse_canonical_json(bytes, "resume request")
        require_array!(wire, 4, "resume request")
        unless wire.fetch(0) == "tamoz.graph.request" &&
               wire.fetch(1) == 1 &&
               wire.fetch(2) == "resume"
          raise CheckpointVersionError, "resume request format is unsupported"
        end

        decode_resume_values(wire.fetch(3))
      end

      private

      def parse_canonical_json(bytes, name)
        unless bytes.is_a?(String)
          raise CheckpointCorruptionError, "#{name} must be encoded bytes"
        end
        text = bytes.dup.force_encoding(Encoding::UTF_8)
        unless text.valid_encoding?
          raise CheckpointCorruptionError, "#{name} is not valid UTF-8"
        end
        wire = JSON.parse(text, create_additions: false, max_nesting: 512)
        unless JSON.generate(wire) == text
          raise CheckpointCorruptionError, "#{name} is not canonical JSON"
        end

        wire
      rescue JSON::ParserError, JSON::NestingError => error
        raise CheckpointCorruptionError.new("#{name} is invalid JSON"), cause: error
      end

      def decode_path_bytes(bytes)
        wire = parse_canonical_json(bytes, "pending path")
        string_array!(wire, "pending path")
      end

      def validate_input(bytes)
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

      def encode_frontier(frontier)
        unless frontier.is_a?(Array)
          raise CheckpointCorruptionError, "checkpoint frontier must be an Array"
        end

        frontier.map do |entry|
          [
            entry.node.to_s,
            entry.kind.to_s,
            entry.path,
            entry.input.nil? ? nil : dump_value(entry.input),
            entry.activation_checkpoint_id,
            entry.logical_step
          ]
        end
      end

      def decode_frontier(wire)
        require_array!(wire, nil, "frontier")
        wire.map.with_index do |entry, index|
          require_array!(entry, FRONTIER_SIZE, "frontier[#{index}]")
          node = node!(entry.fetch(0), "frontier[#{index}] node")
          kind = entry.fetch(1)
          unless KINDS.include?(kind)
            raise CheckpointCorruptionError,
                  "frontier[#{index}] kind must be pull or push"
          end
          path = string_array!(entry.fetch(2), "frontier[#{index}] path")
          input = entry.fetch(3).nil? ? nil : load_value(entry.fetch(3))
          activation_checkpoint_id = optional_string!(
            entry.fetch(4),
            "frontier[#{index}] activation checkpoint id"
          )
          logical_step = positive_integer!(
            entry.fetch(5),
            "frontier[#{index}] logical step"
          )
          Frontier.new(
            node:,
            kind: kind == "pull" ? :pull : :push,
            path:,
            input:,
            activation_checkpoint_id:,
            logical_step:
          )
        end.freeze
      end

      def encode_pending(pending)
        unless pending.is_a?(Hash)
          raise CheckpointCorruptionError, "checkpoint pending outcomes must be a Hash"
        end

        pending.keys.sort.map do |task_id|
          outcome = pending.fetch(task_id)
          unless outcome.task_id == task_id
            raise CheckpointCorruptionError, "pending outcome task identity is mismatched"
          end
          [
            outcome.task_id,
            outcome.attempt_id,
            outcome.base_checkpoint_id,
            outcome.node.to_s,
            outcome.path,
            dump_value(outcome.update),
            encode_goto(outcome.goto)
          ]
        end
      end

      def decode_pending(wire)
        require_array!(wire, nil, "pending outcomes")
        previous = nil
        wire.each_with_object({}) do |entry, result|
          require_array!(entry, OUTCOME_SIZE, "pending outcome")
          task_id = bounded_string!(entry.fetch(0), "pending task id")
          if previous && task_id <= previous
            raise CheckpointCorruptionError,
                  "pending outcomes must have unique sorted task ids"
          end
          previous = task_id
          outcome = Outcome.new(
            task_id:,
            attempt_id: bounded_string!(entry.fetch(1), "pending attempt id"),
            base_checkpoint_id: bounded_string!(
              entry.fetch(2),
              "pending base checkpoint id"
            ),
            node: node!(entry.fetch(3), "pending node"),
            path: string_array!(entry.fetch(4), "pending path"),
            update: decode_update(entry.fetch(5)),
            goto: decode_goto(entry.fetch(6))
          )
          result[task_id] = outcome
        end.freeze
      end

      def encode_interrupts(interrupts)
        unless interrupts.is_a?(Array)
          raise CheckpointCorruptionError, "checkpoint interrupts must be an Array"
        end

        interrupts.sort_by(&:key).map do |interrupt|
          [interrupt.task_id, interrupt.call_index, dump_value(interrupt.descriptor)]
        end
      end

      def decode_interrupts(wire)
        require_array!(wire, nil, "interrupts")
        previous = nil
        wire.map.with_index do |entry, index|
          require_array!(entry, INTERRUPT_SIZE, "interrupt[#{index}]")
          interrupt = Interrupt.new(
            task_id: bounded_string!(entry.fetch(0), "interrupt task id"),
            call_index: non_negative_integer!(
              entry.fetch(1),
              "interrupt call index"
            ),
            descriptor: load_value(entry.fetch(2))
          )
          if previous && interrupt.key <= previous
            raise CheckpointCorruptionError,
                  "interrupts must have unique sorted identities"
          end
          previous = interrupt.key
          interrupt
        end.freeze
      end

      def encode_attempts(attempts)
        unless attempts.is_a?(Hash)
          raise CheckpointCorruptionError, "checkpoint attempts must be a Hash"
        end

        attempts.keys.sort.map do |task_id|
          [String(task_id), attempts.fetch(task_id)]
        end
      end

      def decode_attempts(wire)
        require_array!(wire, nil, "attempts")
        previous = nil
        wire.each_with_object({}) do |entry, result|
          require_array!(entry, 2, "attempt")
          task_id = bounded_string!(entry.fetch(0), "attempt task id")
          if previous && task_id <= previous
            raise CheckpointCorruptionError, "attempt ids must be unique and sorted"
          end
          previous = task_id
          result[task_id] = non_negative_integer!(entry.fetch(1), "attempt count")
        end.freeze
      end

      def encode_goto(routes)
        return nil if routes.nil?
        unless routes.is_a?(Array)
          raise CheckpointCorruptionError, "outcome routes must be an Array"
        end

        routes.map do |route|
          if route.equal?(Tamoz::END)
            ["end"]
          elsif route.is_a?(Send)
            ["send", route.node.to_s, dump_value(route.input), route.key]
          else
            ["pull", route.to_s]
          end
        end
      end

      def decode_goto(wire)
        return nil if wire.nil?

        require_array!(wire, nil, "outcome routes")
        wire.map.with_index do |route, index|
          require_array!(route, nil, "route[#{index}]")
          case route.fetch(0, nil)
          when "end"
            require_array!(route, END_SIZE, "route[#{index}]")
            Tamoz::END
          when "pull"
            require_array!(route, PULL_SIZE, "route[#{index}]")
            node!(route.fetch(1), "route[#{index}] node")
          when "send"
            require_array!(route, SEND_SIZE, "route[#{index}]")
            Send.new(
              node: node!(route.fetch(1), "route[#{index}] node"),
              input: load_value(route.fetch(2)),
              key: optional_string!(route.fetch(3), "route[#{index}] key")
            )
          else
            raise CheckpointCorruptionError,
                  "route[#{index}] has an unknown kind"
          end
        end.freeze
      end

      def decode_state(bytes)
        raw = load_value(bytes)
        unless raw.is_a?(Hash)
          raise CheckpointCorruptionError, "checkpoint state must decode to a Hash"
        end
        if raw.keys.sort != @channels_by_name.keys.sort
          raise CheckpointCorruptionError,
                "checkpoint state channels do not match the compiled graph"
        end

        raw.to_h do |name, value|
          [channel!(name, "state channel"), value]
        end.freeze
      end

      def decode_update(bytes)
        raw = load_value(bytes)
        unless raw.is_a?(Hash)
          raise CheckpointCorruptionError, "pending update must decode to a Hash"
        end

        raw.to_h do |name, value|
          [channel!(name, "update channel"), value]
        end.freeze
      end

      def encode_resume_values(values)
        unless values.is_a?(Hash)
          raise CheckpointCorruptionError, "resume values must be a Hash"
        end
        values.keys.sort.map do |task_id|
          indices = values.fetch(task_id)
          unless indices.is_a?(Hash)
            raise CheckpointCorruptionError, "resume task values must be a Hash"
          end
          [
            String(task_id),
            indices.keys.sort.map do |index|
              [
                non_negative_integer!(index, "resume call index"),
                dump_value(indices.fetch(index))
              ]
            end
          ]
        end
      end

      def decode_resume_values(wire)
        require_array!(wire, nil, "resume values")
        previous_task = nil
        wire.to_h do |task_entry|
          require_array!(task_entry, 2, "resume task")
          task_id = bounded_string!(task_entry.fetch(0), "resume task id")
          if previous_task && task_id <= previous_task
            raise CheckpointCorruptionError,
                  "resume task ids must be unique and sorted"
          end
          previous_task = task_id
          indices = task_entry.fetch(1)
          require_array!(indices, nil, "resume task values")
          previous_index = nil
          decoded = indices.to_h do |index_entry|
            require_array!(index_entry, 2, "resume call value")
            index = non_negative_integer!(
              index_entry.fetch(0),
              "resume call index"
            )
            if previous_index && index <= previous_index
              raise CheckpointCorruptionError,
                    "resume call indices must be unique and sorted"
            end
            previous_index = index
            [index, load_value(index_entry.fetch(1))]
          end.freeze
          [task_id, decoded]
        end.freeze
      end

      def dump_value(value)
        state_codec.dump(value).dup.freeze
      rescue CheckpointVersionError, CheckpointCorruptionError, InvalidUpdateError
        raise
      rescue StandardError => error
        raise CheckpointCorruptionError.new(
          "checkpoint value could not be encoded"
        ), cause: error
      end

      def canonical_value_bytes(bytes)
        value = load_value(bytes)
        encoded = state_codec.dump(value)
        # Canonicality is a BYTE property: an adapter may hand back the stored
        # payload as ASCII-8BIT (SQLite BLOB), which never compares equal to a
        # UTF-8 dump unless both are ASCII-only.
        unless encoded.b == bytes.b
          raise CheckpointCorruptionError,
                "checkpoint contains a non-canonical state value"
        end

        bytes.dup.freeze
      end

      def load_value(bytes)
        unless bytes.is_a?(String)
          raise CheckpointCorruptionError, "encoded checkpoint value must be a String"
        end
        value = state_codec.load(bytes)
        unless state_codec.dump(value).b == bytes.b
          raise CheckpointCorruptionError,
                "checkpoint contains a non-canonical encoded value"
        end

        value
      rescue CheckpointVersionError, CheckpointCorruptionError
        raise
      rescue InvalidUpdateError => error
        raise CheckpointCorruptionError.new(
          "checkpoint value cannot be revived"
        ), cause: error
      end

      def node!(value, name)
        text = bounded_string!(value, name)
        @nodes_by_name.fetch(text) do
          raise CheckpointCorruptionError, "#{name} is not declared by the graph"
        end
      end

      def channel!(value, name)
        text = bounded_string!(value, name)
        @channels_by_name.fetch(text) do
          raise CheckpointCorruptionError, "#{name} is not declared by the graph"
        end
      end

      def status!(value)
        unless value.is_a?(String) && STATUSES.include?(value)
          raise CheckpointCorruptionError, "checkpoint status is invalid"
        end

        value.to_sym
      end

      def bounded_string!(value, name)
        SafeText.normalize(
          value,
          name:,
          max_bytes: 256,
          error_class: CheckpointCorruptionError
        )
      end

      def optional_string!(value, name)
        value.nil? ? nil : bounded_string!(value, name)
      end

      def string_array!(value, name)
        require_array!(value, nil, name)
        if value.empty?
          raise CheckpointCorruptionError, "#{name} must not be empty"
        end
        value.map.with_index do |entry, index|
          bounded_string!(entry, "#{name}[#{index}]")
        end.freeze
      end

      def require_array!(value, size, name)
        unless value.is_a?(Array) && (size.nil? || value.length == size)
          expectation = size ? " with #{size} items" : ""
          raise CheckpointCorruptionError, "#{name} must be an Array#{expectation}"
        end
      end

      def positive_integer!(value, name)
        return value if value.is_a?(Integer) && value.positive?

        raise CheckpointCorruptionError, "#{name} must be a positive integer"
      end

      def non_negative_integer!(value, name)
        return value if value.is_a?(Integer) && !value.negative?

        raise CheckpointCorruptionError,
              "#{name} must be a non-negative integer"
      end

      private_constant :DEFAULT_MAX_BYTES, :MAX_BYTES, :WIRE_SIZE, :FRONTIER_SIZE,
                       :OUTCOME_SIZE, :INTERRUPT_SIZE, :SEND_SIZE, :PULL_SIZE,
                       :END_SIZE, :STATUSES, :KINDS
    end
  end
end
