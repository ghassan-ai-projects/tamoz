# frozen_string_literal: true

module Tamoz
  module Harness
    # One subagent role as data: its prompt, tools and loop budget. A role can only narrow the parent's authority, so a
    # definition naming a tool able to change anything, start another agent or touch memory is refused.
    # :reek:FeatureEnvy :reek:TooManyInstanceVariables
    # A role is a checked view of its JSON definition, so every check reads that definition.
    class SubagentRole
      FORBIDDEN_TOOLS = %w[apply_patch create_file run_check delegate update_plan remember forget recall_memory].freeze
      NAME = /\A[a-z][a-z_]*\z/
      TOOL_PATTERN = /\A[a-z0-9_]*\*\z|\A[a-z][a-z0-9_]*\z/
      KEYS = %w[loop_policy prompt summary tools].freeze
      # A reviewer is handed the paths its parent changed this turn, and refused when there are none.
      OPTIONAL = %w[reviews_changes].freeze

      attr_reader :name, :summary, :prompt, :tools, :loop_policy

      # `tools` are exact names or prefixes ending in `*`; `prompt` is a file in the prompt pack.
      def self.match?(pattern, tool) = pattern.end_with?('*') ? tool.start_with?(pattern.chomp('*')) : pattern == tool

      def self.tool_list?(patterns)
        patterns.is_a?(Array) && !patterns.empty? && patterns.all? { |pattern| pattern.to_s.match?(TOOL_PATTERN) }
      end

      def initialize(name:, definition:)
        @name = name
        @definition = definition
        validate_shape
        @summary, @prompt, @tools, @loop_policy = fields
        freeze
      end

      def reviews_changes? = @definition['reviews_changes'] == true

      private

      def refuse(message) = raise(Error, "subagent role #{@name.inspect}: #{message}")

      def validate_shape
        refuse('the name must be lowercase letters and underscores') unless @name.match?(NAME)
        valid = @definition.is_a?(Hash) && (@definition.keys - OPTIONAL).sort == KEYS &&
                [nil, true, false].include?(@definition['reviews_changes'])
        refuse("it needs #{KEYS.join(', ')} and optionally reviews_changes (true or false)") unless valid
      end

      def fields = [summary_text, prompt_file, tool_patterns, LoopPolicy.from_h(@definition.fetch('loop_policy'))]

      def summary_text
        text = @definition.fetch('summary')
        return text if text.is_a?(String) && !text.strip.empty?

        refuse('the summary must be a non-empty string')
      end

      def prompt_file
        file = @definition.fetch('prompt')
        return file if file.is_a?(String) && file.end_with?('.md') && File.file?(File.join(PromptPack::DIRECTORY, file))

        refuse("the prompt is not a file in the prompt pack: #{file.inspect}")
      end

      def tool_patterns
        patterns = @definition.fetch('tools')
        refuse('tools must be names or prefixes ending in *') unless self.class.tool_list?(patterns)
        refuse_forbidden(patterns)
        patterns.uniq.freeze
      end

      def refuse_forbidden(patterns)
        pattern, tool = patterns.product(FORBIDDEN_TOOLS).find { |candidate, hit| self.class.match?(candidate, hit) }
        refuse("the tool #{pattern.inspect} matches #{tool}, which a subagent never has") if pattern
      end
    end
  end
end
