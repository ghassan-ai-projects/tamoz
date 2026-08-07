# frozen_string_literal: true

module Tamoz
  module Tools
    module Skills
      # Refuses unsafe YAML constructs before frontmatter is materialized.
      # :reek:MissingSafeMethod — each bang is a validation boundary that raises
      # the existing `Rejected` error; a predicate twin would duplicate parsing.
      # :reek:TooManyStatements — parser callbacks must update their mapping
      # frame in event order so duplicate keys are rejected before safe_load.
      # :reek:FeatureEnvy — scalar validation necessarily examines parser values.
      # :reek:DataClump — callback signatures are fixed by Psych::Handler.
      # :reek:LongParameterList — callback signatures are fixed by Psych::Handler.
      # :reek:DuplicateMethodCall — frame[2] is read before and flipped after the
      # current event; caching it would not clarify the state transition.
      # :reek:UncommunicativeVariableName — RuboCop requires `e` for rescued errors.
      class FrontmatterScanner < Psych::Handler
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

        # Psych owns this six-argument callback contract.
        def scalar(value, _anchor, tag, _plain, _quoted, _style) # rubocop:disable Metrics/ParameterLists
          check_tag!(tag)
          note_slot(value)
        end

        define_method(:alias) do |_anchor|
          reject!('skill_frontmatter_alias', 'YAML aliases are not allowed')
        end

        def start_mapping(_anchor, tag, _implicit, _style)
          check_tag!(tag)
          note_slot(nil)
          @stack << [:mapping, [], true]
        end

        def end_mapping = @stack.pop

        def start_sequence(_anchor, tag, _implicit, _style)
          check_tag!(tag)
          note_slot(nil)
          @stack << [:sequence]
        end

        def end_sequence = @stack.pop

        private

        def note_slot(key)
          frame = @stack.last
          return unless frame && frame[0] == :mapping

          note_mapping_key!(frame, key) if frame[2]
          frame[2] = !frame[2]
        end

        def note_mapping_key!(frame, key)
          keys = frame[1]
          reject!('skill_frontmatter_duplicate_key', 'duplicate key') if key && keys.include?(key)
          keys << key if key
        end

        def check_tag!(tag)
          return unless tag && !tag.start_with?('tag:yaml.org,2002:')

          reject!('skill_frontmatter_tag', 'YAML tags are not allowed')
        end

        def reject!(code, detail)
          raise Rejected.new(code, @label, detail)
        end
      end
    end
  end
end
