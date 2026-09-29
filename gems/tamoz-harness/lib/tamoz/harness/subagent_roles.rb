# frozen_string_literal: true

module Tamoz
  module Harness
    # The subagent roles the harness ships, and how many of them one turn may start.
    class SubagentRoles
      attr_reader :max_per_turn

      def self.shipped
        @shipped ||= parse(File.read(File.join(PromptPack::DIRECTORY, 'subagent_roles.json'), encoding: Encoding::UTF_8))
      end

      def self.parse(text)
        document = JSON.parse(text, allow_duplicate_key: false)
        raise Error, 'subagent roles must be a JSON object' unless document.is_a?(Hash)

        new(document)
      rescue JSON::ParserError
        raise Error, 'subagent roles are not valid JSON'
      end

      def initialize(document)
        @max_per_turn = document['max_per_turn']
        validate_cap
        @roles = document.except('max_per_turn').to_h do |name, definition|
          [name, SubagentRole.new(name:, definition:)]
        end.freeze
        raise Error, 'subagent roles must define at least one role' if @roles.empty?

        freeze
      end

      def fetch(name) = @roles.fetch(String(name)) { raise Error, "unknown subagent role #{name.inspect}" }

      def names = @roles.keys

      private

      def validate_cap
        return if @max_per_turn.is_a?(Integer) && @max_per_turn.between?(1, 16)

        raise Error, 'max_per_turn must be an integer from 1 to 16'
      end
    end
  end
end
