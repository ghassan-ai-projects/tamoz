# frozen_string_literal: true

module Tamoz
  module Harness
    # The subagent roles the harness ships, how many children one turn and one fan-out may start, and when the work loop
    # suggests delegating (after `nudge_reads` distinct reads, or at `nudge_window` of the compaction threshold).
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:TooManyInstanceVariables
    # Each limit is one validated field of the same document.
    class SubagentRoles
      LIMITS = { 'max_per_turn' => 1..16, 'max_fanout' => 2..8, 'nudge_reads' => 1..500,
                 'nudge_window' => 0.05..0.95 }.freeze

      attr_reader :max_per_turn, :max_fanout, :nudge_reads, :nudge_window

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
        @max_per_turn, @max_fanout, @nudge_reads, @nudge_window =
          LIMITS.map { |key, range| limit(document, key, range) }
        @roles = document.except(*LIMITS.keys).to_h do |name, definition|
          [name, SubagentRole.new(name:, definition:)]
        end.freeze
        raise Error, 'subagent roles must define at least one role' if @roles.empty?

        freeze
      end

      def fetch(name) = @roles.fetch(String(name)) { raise Error, "unknown subagent role #{name.inspect}" }

      def names = @roles.keys

      private

      def limit(document, key, range)
        value = document[key]
        return value if value.is_a?(range.first.class) && range.cover?(value)

        raise Error, "#{key} must be a #{range.first.class.name.downcase} from #{range.first} to #{range.last}"
      end
    end
  end
end
