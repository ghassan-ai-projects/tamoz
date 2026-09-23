# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # The stable request prefix: system text and tool schemas, in a fixed,
    # locale-independent order. Equality is byte equality of the canonical form.
    class RequestHeader
      DIGEST_DOMAIN = "tamoz.context.request_header.v1\n"

      attr_reader :model, :system, :tools, :bytes, :digest

      def self.build(sections:, tools:, model:)
        ordered = sections.sort_by(&:sort_key)
        reject_duplicates!(ordered.map(&:name), 'section')
        schemas = tools.sort_by { |tool| tool.name.b }
        reject_duplicates!(schemas.map(&:name), 'tool')
        system = ordered.map(&:text).reject(&:empty?).join("\n\n")
        new(model:, system:, tools: schemas.map(&:to_wire))
      end

      def self.reject_duplicates!(names, label)
        duplicate = names.tally.find { |_, count| count > 1 }
        raise Error, "duplicate #{label} #{duplicate.first}" if duplicate
      end
      private_class_method :reject_duplicates!

      def initialize(model:, system:, tools:)
        raise Error, 'header model must be a non-empty String' unless model.is_a?(String) && !model.empty?

        @model = model.dup.freeze
        @system = system.dup.freeze
        @tools = Tamoz::Core.deep_freeze(tools)
        @bytes = Tamoz::Core.jcs(to_h).freeze
        @digest = Tamoz::Core.digest(DIGEST_DOMAIN, to_h)
        freeze
      end

      def to_h = { 'model' => model, 'system' => system, 'tools' => tools }

      def system_message = { 'role' => 'system', 'content' => system }

      def tool_names = tools.map { |tool| tool.fetch('function').fetch('name') }

      def ==(other) = other.is_a?(RequestHeader) && other.bytes == bytes
      alias eql? ==

      def hash = bytes.hash
    end
  end
end
