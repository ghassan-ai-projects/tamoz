# frozen_string_literal: true

require 'cgi'

module Tamoz
  module Telegram
    # The Markdown a model writes, as Telegram HTML: every character is escaped
    # first and only balanced, non-overlapping tags are emitted, so the result always parses.
    module Markup
      FENCE = /^(`{3,})[^\n]*\n(.*?)(?:^\1`*[ \t]*$|\z)/m
      INLINE_CODE = /`([^`\n]+)`/
      HEADING = /^\#{1,6}[ \t]+(.+)$/
      LINK = %r{\[([^\]\n<]+)\]\((https?://[^)\s*<\u0000]+)\)}
      BOLD = /\*\*(?=\S)([^<>\n]+?)(?<=\S)\*\*/
      HELD = /\u0000(\d+)\u0000/

      module_function

      # Code is held out as placeholders so emphasis can wrap it (`**`x`**`) but never reach inside.
      def html(text)
        held = []
        masked = text.delete("\u0000")
                     .gsub(FENCE) { hold(held, 'pre', Regexp.last_match(2).chomp) }
                     .gsub(INLINE_CODE) { hold(held, 'code', Regexp.last_match(1)) }
        emphasis(CGI.escapeHTML(masked)).gsub(HELD) { held.fetch(Regexp.last_match(1).to_i) }
      end

      def hold(held, tag, code)
        held << "<#{tag}>#{CGI.escapeHTML(code)}</#{tag}>"
        "\u0000#{held.length - 1}\u0000"
      end

      def emphasis(escaped)
        escaped.gsub(HEADING) { "<b>#{Regexp.last_match(1).gsub('**', '')}</b>" }
               .gsub(LINK, '<a href="\2">\1</a>')
               .gsub(BOLD, '<b>\1</b>')
      end
    end
  end
end
