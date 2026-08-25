# frozen_string_literal: true

module Tamoz
  module Comms
    # The one bounded line each typed context-control answers with, built only
    # from the session layer's projection document — never a raw dump. Both
    # surfaces render through this one vocabulary, so a channel reply and the
    # CLI's text output mean the same thing for the same document.
    module ControlReply
      module_function

      def line(control, document)
        case control
        when 'reset'
          "Episode reset on generation #{document.fetch('generation')}; " \
            "#{document.fetch('truncated_fragments')} transcript fragments left the frame."
        when 'compact'
          "Transcript compacted; #{document.fetch('truncated_fragments')} fragments " \
            'externalized behind pinned digests.'
        when 'usage' then usage_line(document)
        when 'context' then context_line(document)
        when 'think' then "Reasoning depth set to #{document.dig('preferences', 'reasoning_depth')}."
        when 'verbose' then "Answer verbosity set to #{document.dig('preferences', 'answer_verbosity')}."
        end
      end

      def usage_line(document)
        observation = document.fetch('observation_bytes')
        "Usage: requests #{pairs(document.fetch('requests'))}; " \
          "controls #{pairs(document.fetch('controls'))}; " \
          "observation bytes #{observation.fetch('used')}/#{observation.fetch('ceiling')}; " \
          "lifecycle events #{document.fetch('lifecycle_events')}."
      end

      def context_line(document)
        transcript = document.dig('layers', 'transcript')
        "Context: fragments visible #{transcript.fetch('fragments_visible')} of " \
          "#{transcript.fetch('fragments_total')} " \
          "(#{transcript.fetch('truncated_by_control')} truncated by controls); " \
          "observations #{document.dig('layers', 'observations')}; " \
          "preferences #{pairs(document.fetch('preferences'))}; " \
          "earlier summary #{transcript.fetch('earlier_summary_pinned') ? 'pinned' : 'none'}."
      end

      def pairs(values)
        return 'none' if values.empty?

        values.map { |key, value| "#{key}=#{value}" }.join(' ')
      end
    end
  end
end
