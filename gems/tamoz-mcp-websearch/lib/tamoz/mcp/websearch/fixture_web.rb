# frozen_string_literal: true

require 'json'

module Tamoz
  module Mcp
    module Websearch
      # A frozen web for tests and offline evals: pages with text, found by the words of a query. No socket.
      # :reek:FeatureEnvy :reek:TooManyStatements :reek:UtilityFunction -- pages are plain hashes from the file.
      class FixtureWeb
        SNIPPET_CHARACTERS = 200

        def self.load(path) = new(JSON.parse(File.read(path, encoding: Encoding::UTF_8)))

        # `document`: {"pages" => [{"url", "title", "published", "text", "keywords" => [...]}]}
        def initialize(document)
          @pages = Array(document.fetch('pages')).map do |page|
            page.slice('url', 'title', 'published', 'text', 'keywords')
          end
          @by_url = @pages.to_h { |page| [page.fetch('url'), page] }
          freeze
        end

        # The pages sharing the most words with the query, best first; ties keep the file's order.
        def search(query, count)
          words = terms(query)
          scored = @pages.each_with_index.filter_map do |page, index|
            score = (words & terms(searchable(page))).length
            [-score, index, page] if score.positive?
          end
          scored.sort.first(count).map { |_, _, page| hit(page) }
        end

        def read(url)
          page = @by_url.fetch(url) { raise EgressPolicyError, "the fixture web has no page #{url}" }
          { 'url' => url, 'title' => page['title'].to_s, 'published' => page['published'].to_s,
            'text' => page.fetch('text'), 'truncated' => false }
        end

        private

        def searchable(page) = [page['title'], *Array(page['keywords']), page['text']].join(' ')

        def terms(text) = text.to_s.downcase.scan(/[\p{L}\p{N}]+/).reject { |word| word.length < 3 }.uniq

        def hit(page)
          { 'title' => page['title'].to_s, 'url' => page.fetch('url'),
            'snippet' => page.fetch('text')[0, SNIPPET_CHARACTERS], 'age' => page['published'].to_s }
        end
      end
    end
  end
end
