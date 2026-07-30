# frozen_string_literal: true

require "json"

module Tamoz
  module SQLite
    module BoundaryRegistry
      VERSION = 1
      POINTS = %w[
        before_begin after_begin before_sql after_sql before_commit after_commit
      ].freeze
      MAX_OPERATION_BYTES = 128
      MAX_STATEMENT_BYTES = 128

      def self.statement(template, access, max_instances = 1)
        {
          "template" => template.freeze,
          "access" => access.freeze,
          "max_instances" => max_instances
        }.freeze
      end
      private_class_method :statement

      READ = ->(template, maximum = 1) { statement(template, "read", maximum) }
      WRITE = ->(template, maximum = 1) { statement(template, "write", maximum) }

      OPERATIONS = [
        {
          "operation" => "lease.acquire",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("lease.acquire.time"),
            WRITE.call("lease.acquire.thread"),
            READ.call("lease.acquire.thread_state"),
            WRITE.call("lease.acquire.namespace"),
            READ.call("lease.acquire.row"),
            WRITE.call("lease.acquire.update")
          ].freeze
        },
        {
          "operation" => "lease.validate",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("lease.validate.time"),
            READ.call("lease.validate.thread"),
            READ.call("lease.validate.row"),
            WRITE.call("lease.validate.clock")
          ].freeze
        },
        {
          "operation" => "lease.renew",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("lease.renew.time"),
            READ.call("lease.renew.thread"),
            READ.call("lease.renew.row"),
            WRITE.call("lease.renew.update")
          ].freeze
        },
        {
          "operation" => "lease.release",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("lease.release.time"),
            READ.call("lease.release.row"),
            WRITE.call("lease.release.update")
          ].freeze
        },
        {
          "operation" => "request.enqueue",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("request.enqueue.time"),
            WRITE.call("request.enqueue.thread"),
            READ.call("request.enqueue.tombstone"),
            WRITE.call("request.enqueue.namespace"),
            READ.call("request.enqueue.existing"),
            READ.call("request.enqueue.sequence"),
            WRITE.call("request.enqueue.insert"),
            READ.call("request.transition.index"),
            WRITE.call("request.transition.insert"),
            WRITE.call("request.enqueue.advance"),
            READ.call("request.enqueue.result")
          ].freeze
        },
        {
          "operation" => "request.claim",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("request.claim.time"),
            READ.call("request.claim.lease.thread"),
            READ.call("request.claim.lease.row"),
            READ.call("request.claim.next"),
            READ.call("request.claim.active_execution"),
            READ.call("request.claim.redirect_target"),
            READ.call("request.claim.cancellation_generation"),
            WRITE.call("request.claim.update"),
            READ.call("request.transition.index"),
            WRITE.call("request.transition.insert"),
            READ.call("request.claim.result")
          ].freeze
        },
        {
          "operation" => "request.recover",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("request.recover.time"),
            READ.call("request.recover.lease.thread"),
            READ.call("request.recover.lease.row"),
            READ.call("request.recover.row"),
            READ.call("request.recover.earlier"),
            WRITE.call("request.recover.update"),
            READ.call("request.transition.index"),
            WRITE.call("request.transition.insert"),
            READ.call("request.recover.result")
          ].freeze
        },
        {
          "operation" => "request.redirect_ready",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("request.redirect_ready.time"),
            READ.call("request.redirect_ready.lease.thread"),
            READ.call("request.redirect_ready.lease.row"),
            READ.call("request.redirect_ready.effects")
          ].freeze
        },
        {
          "operation" => "request.transition",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("request.transition.time"),
            READ.call("request.transition.lease.thread"),
            READ.call("request.transition.lease.row"),
            READ.call("request.commit.row"),
            WRITE.call("request.commit.update"),
            READ.call("request.transition.index"),
            WRITE.call("request.transition.insert"),
            READ.call("request.transition.result")
          ].freeze
        },
        {
          "operation" => "checkpoint.append_writes",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("checkpoint.writes.time"),
            READ.call("checkpoint.writes.lease.thread"),
            READ.call("checkpoint.writes.lease.row"),
            READ.call("checkpoint.writes.base"),
            READ.call("checkpoint.writes.existing"),
            WRITE.call("checkpoint.writes.activation"),
            WRITE.call("checkpoint.writes.item.{index}", 65_536),
            READ.call("checkpoint.writes.verify")
          ].freeze
        },
        {
          "operation" => "checkpoint.commit",
          "phase" => 2,
          "kill_required" => true,
          "statements" => [
            READ.call("checkpoint.commit.time"),
            READ.call("checkpoint.commit.lease.thread"),
            READ.call("checkpoint.commit.lease.row"),
            READ.call("checkpoint.commit.head"),
            READ.call("checkpoint.commit.base"),
            WRITE.call("checkpoint.commit.insert"),
            WRITE.call("checkpoint.commit.consume.{index}", 65_536),
            READ.call("request.commit.row"),
            WRITE.call("request.commit.update"),
            READ.call("request.transition.index"),
            WRITE.call("request.transition.insert"),
            WRITE.call("checkpoint.commit.advance")
          ].freeze
        },
        {
          "operation" => "checkpoint.prune",
          "phase" => 4,
          "kill_required" => false,
          "statements" => [
            READ.call("checkpoint.prune.time"),
            READ.call("checkpoint.prune.thread"),
            READ.call("checkpoint.prune.exists"),
            READ.call("checkpoint.prune.candidates"),
            WRITE.call("checkpoint.prune.delete", 100_000)
          ].freeze
        },
        {
          "operation" => "checkpoint.latest",
          "phase" => 2,
          "kill_required" => false,
          "statements" => [READ.call("checkpoint.latest")].freeze
        },
        {
          "operation" => "checkpoint.find",
          "phase" => 2,
          "kill_required" => false,
          "statements" => [READ.call("checkpoint.find")].freeze
        },
        {
          "operation" => "checkpoint.history",
          "phase" => 2,
          "kill_required" => false,
          "statements" => [READ.call("checkpoint.history")].freeze
        },
        {
          "operation" => "checkpoint.pending",
          "phase" => 2,
          "kill_required" => false,
          "statements" => [READ.call("checkpoint.pending.activations")].freeze
        },
        {
          "operation" => "checkpoint.pending_writes",
          "phase" => 2,
          "kill_required" => false,
          "statements" => [READ.call("checkpoint.pending.writes")].freeze
        },
        {
          "operation" => "request.fetch",
          "phase" => 2,
          "kill_required" => false,
          "statements" => [READ.call("request.fetch")].freeze
        }
      ].map(&:freeze).freeze

      OPERATION_INDEX = OPERATIONS.to_h do |entry|
        [entry.fetch("operation"), entry]
      end.freeze

      DOCUMENT = {
        "registry_version" => VERSION,
        "operations" => OPERATIONS
      }.freeze

      module_function

      def document
        DOCUMENT
      end

      def digest
        @digest ||= Wire.digest(
          canonical_json(DOCUMENT),
          domain: "tamoz.sqlite.boundary_registry"
        )
      end

      def operation(name)
        OPERATION_INDEX[name]
      end

      def phase_operations(phase:, kill_required: nil)
        OPERATIONS.select do |entry|
          entry.fetch("phase") == phase &&
            (kill_required.nil? ||
             entry.fetch("kill_required") == kill_required)
        end.freeze
      end

      def resolve_statement(operation_name, statement_name)
        entry = operation(operation_name)
        return nil unless entry && statement_name.is_a?(String)

        entry.fetch("statements").each do |statement|
          match = match_template(
            statement.fetch("template"),
            statement_name,
            statement.fetch("max_instances")
          )
          return statement.merge("instance" => match).freeze unless match.nil?
        end
        nil
      end

      def validate_hook!(point, metadata)
        point_name = point.to_s
        unless POINTS.include?(point_name)
          raise ConfigurationError, "unknown SQLite hook point #{point.inspect}"
        end
        expected_keys = %w[attempt hook_version kind operation statement]
        unless metadata.is_a?(Hash) &&
               metadata.length == expected_keys.length &&
               expected_keys.all? { |key| metadata.key?(key) }
          raise ConfigurationError, "SQLite hook metadata shape is invalid"
        end
        unless metadata.fetch("hook_version") == VERSION
          raise ConfigurationError, "SQLite hook metadata version is invalid"
        end

        kind = metadata.fetch("kind")
        operation_name = bounded_identifier(
          metadata.fetch("operation"),
          name: "SQLite hook operation",
          maximum: MAX_OPERATION_BYTES
        )
        unless operation(operation_name)
          raise ConfigurationError,
                "SQLite hook operation is absent from the boundary registry"
        end
        attempt = metadata.fetch("attempt")
        unless attempt.nil? || (attempt.is_a?(Integer) && attempt.positive?)
          raise ConfigurationError, "SQLite hook attempt is invalid"
        end

        statement_name = metadata.fetch("statement")
        if kind == "transaction"
          unless statement_name.nil? &&
                 %w[before_begin after_begin before_commit after_commit].include?(point_name)
            raise ConfigurationError, "transaction hook metadata is inconsistent"
          end
        elsif kind == "statement"
          unless %w[before_sql after_sql].include?(point_name)
            raise ConfigurationError, "statement hook point is inconsistent"
          end
          normalized = bounded_identifier(
            statement_name,
            name: "SQLite hook statement",
            maximum: MAX_STATEMENT_BYTES
          )
          unless resolve_statement(operation_name, normalized)
            raise ConfigurationError,
                  "SQLite statement is absent from its operation registry"
          end
        else
          raise ConfigurationError, "SQLite hook kind is invalid"
        end
        true
      end

      def canonical_json(value)
        JSON.generate(canonicalize(value))
      end
      private_class_method :canonical_json

      private_class_method def canonicalize(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
        when Array
          value.map { |entry| canonicalize(entry) }
        else
          value
        end
      end

      def match_template(template, value, maximum)
        return 0 if template == value
        return nil unless template.include?("{index}")

        prefix, suffix = template.split("{index}", 2)
        return nil unless value.start_with?(prefix) && value.end_with?(suffix)

        width = value.bytesize - prefix.bytesize - suffix.bytesize
        return nil unless width.positive?

        encoded = value.byteslice(prefix.bytesize, width)
        return nil unless encoded.match?(/\A(?:0|[1-9][0-9]*)\z/)

        index = Integer(encoded, 10)
        index < maximum ? index : nil
      end
      private_class_method :match_template

      def bounded_identifier(value, name:, maximum:)
        unless value.is_a?(String) && value.valid_encoding? &&
               !value.empty? && value.bytesize <= maximum &&
               value.match?(/\A[a-z0-9][a-z0-9._-]*\z/)
          raise ConfigurationError, "#{name} is invalid"
        end

        value
      end
      private_class_method :bounded_identifier

      private_constant :READ, :WRITE, :OPERATION_INDEX, :DOCUMENT
    end

    private_constant :BoundaryRegistry
  end
end
