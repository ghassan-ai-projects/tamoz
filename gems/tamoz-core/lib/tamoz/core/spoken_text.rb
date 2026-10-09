# frozen_string_literal: true

module Tamoz
  module Core
    # The words a delivered message is spoken as, and the word comparison the worker's echo guard uses.
    module SpokenText
      SPOKEN_KINDS = %w[answer approval_request failed stopped blocked].freeze
      MAX_CHARACTERS = 400
      APPROVAL = "I need your approval for a change. It's on your screen."
      CODE = 'The code is on screen.'
      TABLE = 'The table is on screen.'
      REST = 'The rest is on screen.'
      FILE = 'a file name'
      LINK = 'a link'
      ECHO_MIN_WORDS = 8
      ECHO_OVERLAP = 0.85

      module_function

      def project(text, kind:, more: false)
        return nil unless SPOKEN_KINDS.include?(kind)
        return APPROVAL if kind == 'approval_request'

        spoken = speakable(text.to_s)
        return nil if spoken.empty?

        cut(spoken, more:)
      end

      def words(text)
        text.to_s.unicode_normalize(:nfkc).downcase.scan(/[[:alnum:]]+(?:[.:][[:digit:]]+)*/)
      end

      # Most of what was heard occurs, in order, in what was last spoken.
      def echo?(heard, spoken)
        heard_words = words(heard)
        return false if heard_words.length < ECHO_MIN_WORDS

        remaining = words(spoken)
        matched = heard_words.count do |word|
          index = remaining.index(word)
          remaining = remaining.drop(index + 1) if index
          index
        end
        matched >= heard_words.length * ECHO_OVERLAP
      end

      def speakable(text)
        lines = without_code(text).lines.map(&:rstrip)
        prose = collapse_tables(lines).map { |line| inline(line) }.reject(&:empty?)
        prose.join(' ').gsub(/\s+/, ' ').gsub(/(#{Regexp.escape(CODE)} )+/o, "#{CODE} ").strip
      end

      def without_code(text)
        text.gsub(/^\s*(```|~~~).*?^\s*\1[^\n]*$/m, "\n#{CODE}\n").gsub(/^\s*(```|~~~).*\z/m, "\n#{CODE}\n")
      end

      def collapse_tables(lines)
        lines.each_with_object([]) do |line, out|
          if line.lstrip.start_with?('|')
            out << TABLE unless out.last == TABLE
          else
            out << line
          end
        end
      end

      def inline(line)
        line = line.sub(/\A\s*(?:#+|>+|[-*+]|\d+[.)])\s+/, '')
        line = line.gsub(/!?\[([^\]]*)\]\([^)]*\)/, '\1')
        line = line.gsub(%r{\bhttps?://\S+}, LINK)
        line = line.gsub(/`([^`]*)`/) { path?(::Regexp.last_match(1)) ? FILE : ::Regexp.last_match(1) }
        line = line.gsub(/(\bat\s+)?\b\d{4}-\d{2}-\d{2}T(\d{2}:\d{2})(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})?\b/,
                         'at \2')
        line = line.gsub(/\b(?:sha256:)?\h{12,}\b|\br\h{10}\b/, '')
        line = line.gsub(%r{(?<![\w/])(?:\.{0,2}/)?(?:[\w.-]+/)+[\w.-]*[\w-]}, FILE)
        line = line.gsub(/(?<![\w.])[\w-]{2,}(?:\.[\w-]+)*\.[a-z][a-z0-9]{0,5}\b(?!\.\w)/i, FILE)
        line.gsub(/(\*\*|__|\*|_|~~)(?=\S)(.+?)(?<=\S)\1/, '\2').strip
      end

      def path?(text) = text.include?('/') || text.match?(/\A[\w-]{2,}(?:\.[\w-]+)*\.[a-z][a-z0-9]{0,5}\z/i)

      def cut(text, more:)
        return more ? "#{text} #{REST}" : text if text.length <= MAX_CHARACTERS

        window = text[0, MAX_CHARACTERS]
        stop = window.rindex(/[.!?](?=\s|\z)/)
        head = stop ? window[0..stop] : window[0, window.rindex(' ') || MAX_CHARACTERS]
        "#{head.strip} #{REST}"
      end
    end
  end
end
