# frozen_string_literal: true

module Tamoz
  module Skills
    # Refuses YAML aliases, non-core tags and duplicate keys from the parser's events, before anything is
    # materialized. The callback signatures are Psych::Handler's.
    class FrontmatterScanner < Psych::Handler
      # A mapping being read: its keys so far, and whether the next scalar is a key.
      class MappingFrame
        def initialize
          @keys = []
          @expecting_key = true
        end

        # Returns false when `key` repeats one already seen.
        def accept(key)
          fresh = !(@expecting_key && key && @keys.include?(key))
          @keys << key if @expecting_key && key
          @expecting_key = !@expecting_key
          fresh
        end
      end

      def initialize(text, label)
        super()
        @text = text
        @label = label
        @stack = []
      end

      def call
        Psych::Parser.new(self).parse(@text)
      rescue Psych::SyntaxError => e
        reject!('skill_frontmatter_invalid', "invalid YAML: #{e.problem}")
      end

      def scalar(value, _anchor, tag, _plain, _quoted, _style) # rubocop:disable Metrics/ParameterLists
        check_tag!(tag)
        note(value)
      end

      define_method(:alias) { |_anchor| reject!('skill_frontmatter_alias', 'YAML aliases are not allowed') }

      def start_mapping(_anchor, tag, _implicit, _style)
        push_frame(tag, MappingFrame.new)
      end

      def start_sequence(_anchor, tag, _implicit, _style)
        push_frame(tag, :sequence)
      end

      def end_mapping = @stack.pop
      def end_sequence = @stack.pop

      private

      def push_frame(tag, frame)
        check_tag!(tag)
        note(nil)
        @stack << frame
      end

      def note(key)
        frame = @stack.last
        return unless frame.is_a?(MappingFrame)

        reject!('skill_frontmatter_duplicate_key', 'duplicate key') unless frame.accept(key)
      end

      def check_tag!(tag)
        return unless tag && !tag.start_with?('tag:yaml.org,2002:')

        reject!('skill_frontmatter_tag', 'YAML tags are not allowed')
      end

      def reject!(code, detail) = raise(Rejected.new(code, @label, detail))
    end
  end
end
