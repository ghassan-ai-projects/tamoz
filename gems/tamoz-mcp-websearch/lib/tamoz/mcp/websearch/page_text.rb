# frozen_string_literal: true

require 'json'
require 'nokogiri'

module Tamoz
  module Mcp
    module Websearch
      # The readable text of an HTML page: its main content as plain markdown, its title, and its published date
      # when the page states one. Link targets are not kept, so a page cannot hand the reader a URL to follow.
      # :reek:DuplicateMethodCall :reek:NestedIterators :reek:TooManyConstants :reek:TooManyStatements :reek:UtilityFunction
      module PageText
        # A page's title, stated publication date ('' when none) and readable text.
        Extracted = Data.define(:title, :published, :text)

        NEVER_TEXT = 'script, style, noscript, svg, iframe, template, button, nav, aside, select'
        CANDIDATES = ['article', 'main', '[role=main]'].freeze
        OUTSIDE_MAIN = 'header, footer'
        BLOCKS = %w[p div li h1 h2 h3 h4 h5 h6 pre blockquote td th dt dd figcaption section article main].freeze
        MARKERS = { 'h1' => '# ', 'h2' => '## ', 'h3' => '### ', 'h4' => '#### ', 'li' => '- ' }.freeze
        DATE_META = %w[article:published_time datePublished date dc.date pubdate].freeze
        MAX_TITLE = 300
        # A candidate must hold at least this share of the body's text, or it is a teaser, not the article.
        MAIN_SHARE = 0.3

        module_function

        def extract(html)
          document = Nokogiri::HTML(html)
          published = published_date(document)
          document.css(NEVER_TEXT).remove
          main = main_node(document)
          main.css(OUTSIDE_MAIN).remove if main.name == 'body'
          Extracted.new(title: title(document), published:, text: markdown(main))
        end

        # The largest article-like node, when it carries a real share of the page; the body otherwise.
        def main_node(document)
          body = document.at_css('body') || document.root
          total = words(body).length
          best = CANDIDATES.flat_map { |selector| document.css(selector).to_a }.max_by { |node| words(node).length }
          best && words(best).length >= total * MAIN_SHARE ? best : body
        end

        # Every text node joins the innermost block that holds it, so text in divs is kept and nested blocks keep
        # their spacing; each block becomes one paragraph.
        def markdown(node)
          grouped(node).filter_map { |block, content| paragraph(block, content) }.join("\n\n")
        end

        # [[block element, its text]] in document order, one entry per run of text in the same block.
        def grouped(node)
          node.xpath('.//text()').each_with_object([]) do |text, blocks|
            piece = text.text.gsub(/[[:space:]]+/, ' ')
            next if piece.strip.empty?

            block = text.ancestors.find { |parent| BLOCKS.include?(parent.name) } || node
            blocks << [block, +''] unless blocks.last&.first.equal?(block)
            blocks.last.last << piece
          end
        end

        def paragraph(block, content)
          text = content.strip.squeeze(' ')
          "#{MARKERS.fetch(block.name, '')}#{text}" unless text.empty?
        end

        def words(node) = node.text.gsub(/[[:space:]]+/, ' ').strip

        def title(document)
          meta = document.at_css('meta[property="og:title"]')&.[]('content')
          (meta || document.at_css('title')&.text).to_s.gsub(/[[:space:]]+/, ' ').strip[0, MAX_TITLE]
        end

        def published_date(document)
          meta = DATE_META.lazy.filter_map do |name|
            document.at_css(%(meta[property="#{name}"], meta[name="#{name}"], meta[itemprop="#{name}"]))&.[]('content')
          end.first
          (meta || document.at_css('time[datetime]')&.[]('datetime') || json_ld_date(document)).to_s.strip[0, 40]
        end

        def json_ld_date(document)
          document.css('script[type="application/ld+json"]').lazy.filter_map do |script|
            data = JSON.parse(script.text)
            items = data.is_a?(Hash) ? [data, *Array(data['@graph'])] : Array(data)
            items.find { |item| item.is_a?(Hash) && item['datePublished'] }&.fetch('datePublished')
          rescue JSON::ParserError
            nil
          end.first
        end
      end
    end
  end
end
