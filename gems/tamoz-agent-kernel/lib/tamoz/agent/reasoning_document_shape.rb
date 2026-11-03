# frozen_string_literal: true

require 'tamoz/agent/reasoning_document'

module Tamoz
  module Agent
    # The tamoz.episode-diagnosis/v2 shape as the model must write it, rendered from
    # ReasoningDocument's own key lists so the instructions and the parser cannot disagree.
    module ReasoningDocumentShape
      PLACEHOLDERS = {
        'protocol' => %("#{ReasoningDocument::PROTOCOL}"),
        'primary_hypothesis' => '"<the cause you conclude, in one or two sentences>"',
        'diagnosis_code' => '"<code>"',
        'probability' => '<number in [0,1]>',
        'evidence_refs' => '["<id of an entry given in the user message>"]',
        'type' => '"<an intent type listed under INTENTS>"',
        'parameters' => '{"<a field listed for that type>":<its value>}',
        'name' => '"<tool>"',
        'arguments' => '{}',
        'purpose' => '"<the missing datum, and why it decides the diagnosis>"',
        'datum' => '"<what is missing>"',
        'why' => '"<why it matters>"'
      }.freeze
      UNWRITTEN_INTENT_KEYS = %w[parameter_preset].freeze
      TERMINAL_TURN_KEYS = ['protocol', *ReasoningDocument::TERMINAL_KEYS].freeze
      TOOL_TURN_KEYS = ['protocol', *ReasoningDocument::TOOL_KEYS].freeze

      module_function

      def output_lines
        [
          'OUTPUT: one JSON object and nothing else (no prose, no code fence). A terminal answer is:',
          terminal_example,
          "Write exactly these keys: #{TERMINAL_TURN_KEYS.join(', ')}. Any other key is rejected. There is no " \
          'separate diagnosis field: the selected diagnosis is the code with the highest probability.',
          "diagnosis_probabilities is an array with one #{object(ReasoningDocument::PROBABILITY_KEYS)} object per " \
          'diagnosis code, never an object keyed by code.',
          'evidence_refs, recommended_intents and evidence_gaps may be empty arrays.',
          "Each recommended intent is #{intent_entry}; parameters holds only the fields listed for its type " \
          "(leave parameters out when the type lists none) and #{UNWRITTEN_INTENT_KEYS.join(', ')} stays out: " \
          'the catalog fills every parameter you do not write.'
        ]
      end

      def repair_directive(rejection)
        "#{rejection}. Rewrite the whole answer as one JSON object with only the keys " \
          "#{TERMINAL_TURN_KEYS.join(', ')}: #{terminal_example} (a tool turn, when tools are offered, " \
          "carries only #{TOOL_TURN_KEYS.join(', ')})."
      end

      def terminal_example = object(TERMINAL_TURN_KEYS)

      def tool_example = object(TOOL_TURN_KEYS)

      def object(keys)
        "{#{keys.map { |key| %("#{key}":#{value(key)}) }.join(',')}}"
      end

      def value(key)
        case key
        when 'diagnosis_probabilities' then "[#{object(ReasoningDocument::PROBABILITY_KEYS)}, ...]"
        when 'recommended_intents' then "[#{intent_entry}]"
        when 'evidence_gaps' then "[#{object(ReasoningDocument::EVIDENCE_GAP_KEYS)}]"
        when 'tool_requests' then "[#{object(ReasoningDocument::TOOL_REQUEST_KEYS)}]"
        else PLACEHOLDERS.fetch(key)
        end
      end

      def intent_entry = object(ReasoningDocument::INTENT_KEYS - UNWRITTEN_INTENT_KEYS)
    end
  end
end
