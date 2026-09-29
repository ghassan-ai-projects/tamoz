# frozen_string_literal: true

module Tamoz
  module Mcp
    module Websearch
      # Reads one public web page through a reader-mode egress client and returns its readable text. Sites that
      # serve markdown to agents (Accept: text/markdown) are taken as they are; HTML goes through PageText.
      # :reek:TooManyStatements :reek:UtilityFunction
      class PageReader
        ACCEPT = 'text/markdown, text/html;q=0.9, text/plain;q=0.8'
        USER_AGENT = 'Tamoz-research/0.1 (+https://github.com/ghassan-ai-projects/tamoz)'
        MAX_TEXT_BYTES = 32 * 1024
        HTML = %w[text/html application/xhtml+xml].freeze
        PLAIN = %w[text/markdown text/plain].freeze

        def initialize(client:)
          @client = client
          freeze
        end

        # {"url", "title", "published", "text", "truncated"}; raises EgressPolicyError when the page cannot be read.
        def read(url)
          result = @client.fetch(url, headers: { 'Accept' => ACCEPT, 'User-Agent' => USER_AGENT })
          status = result.status
          raise EgressPolicyError, "the page answered HTTP #{status}" unless (200..299).cover?(status)

          extracted = extract(content_type(result.headers), result.body)
          text, cut = bounded(Websearch.sanitize_result(extracted.text))
          raise EgressPolicyError, 'the page has no readable text' if text.strip.empty?

          { 'url' => url, 'title' => Websearch.sanitize_result(extracted.title), 'published' => extracted.published,
            'text' => text, 'truncated' => cut || result.truncated }
        end

        private

        def content_type(headers) = headers.fetch('content-type', '').split(';').first.to_s.strip.downcase

        def extract(type, body)
          return PageText.extract(body) if HTML.include?(type)
          return PageText::Extracted.new(title: '', published: '', text: body) if PLAIN.include?(type)

          raise EgressPolicyError, "the page is #{type.empty? ? 'of no stated type' : type}, not text"
        end

        def bounded(text)
          return [text, false] if text.bytesize <= MAX_TEXT_BYTES

          [text.byteslice(0, MAX_TEXT_BYTES).scrub(''), true]
        end
      end
    end
  end
end
