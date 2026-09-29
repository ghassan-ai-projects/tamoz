# frozen_string_literal: true

module Tamoz
  module Research
    # The final report, assembled from the lead's write_report call and the ledger. The lead cites claim ids ([C3]);
    # the report numbers sources itself and generates the sources list, so no source can appear that no child read.
    # :reek:FeatureEnvy :reek:NestedIterators :reek:TooManyInstanceVariables :reek:TooManyStatements
    # :reek:LongParameterList -- one assembled document and the steps that build it.
    class Report
      CITE = /\[\s*(C\d+(?:\s*[,;]\s*C\d+)*)\s*\]/i
      BRACKETED_ID = /\[[^\]\n]*\bC\d+\b[^\]\n]*\]/i
      STOPPED = {
        'coverage' => 'Every sub-question was covered.',
        'saturation' => 'Research stopped when a further round of searching added nothing new.',
        'budget' => 'Research stopped at its budget.'
      }.freeze
      GAPS = {
        'contested' => 'sources disagree (see Where sources disagree)',
        'unanswerable' => 'no source was found',
        'open' => 'not established within the budget'
      }.freeze

      attr_reader :markdown, :summary, :gaps, :cited

      def self.ids_in(text) = text.scan(CITE).flat_map { |group| group.first.upcase.split(/\s*[,;]\s*/) }.uniq

      # Each cited sentence with the claim ids it cites, for the support check.
      def self.citations(body)
        String(body).split(/(?<=[.!?])\s+|\n+/).filter_map do |sentence|
          ids = ids_in(sentence)
          [Text.squash(sentence), ids] unless ids.empty?
        end
      end

      # `unsupported`: claim ids the support check found not backed by their excerpt.
      def self.parse(arguments, ledger:, stop_reason:, unsupported: [])
        raise Error, 'write_report takes an object' unless arguments.is_a?(Hash)

        summary = Text.bounded(arguments['summary'], 'summary', max: 1500)
        body = arguments['body']
        raise Error, 'body must be the report text, citing claims as [C1]' unless body.is_a?(String) &&
                                                                                  !body.strip.empty?

        new(ledger:, summary:, body:, stop_reason:, unsupported:)
      end

      def initialize(ledger:, summary:, body:, stop_reason:, unsupported:)
        @ledger = ledger
        @unsupported = unsupported
        @cited = cited_ids("#{summary}\n#{body}")
        @numbers = source_numbers
        @summary = numbered(summary)
        @gaps = gap_lines(stop_reason)
        @markdown = assemble(numbered(body)).freeze
        freeze
      end

      # How many sub-questions the report leaves open, contested or unanswered.
      def gap_count = @ledger.statuses.count { |_, status| GAPS.key?(status) }

      # The short message on the surface; the full report is the file at `path`.
      def reply(path)
        gaps = @gaps.length > 1 ? " Gaps: #{@gaps.drop(1).join('; ')}." : ''
        "#{@summary}\n\n#{@gaps.first}#{gaps}\n\nThe full report is saved at #{path}"
      end

      private

      def cited_ids(text)
        refuse_loose(text)
        ids = self.class.ids_in(text)
        unknown = ids.reject { |id| @ledger.claim(id) }
        raise Error, "the report cites claims that do not exist: #{unknown.join(', ')}" unless unknown.empty?
        raise Error, 'the report cites no claim; cite each finding as [C1]' if ids.empty? && !@ledger.claims.empty?

        ids.freeze
      end

      def refuse_loose(text)
        loose = text.scan(BRACKETED_ID).grep_v(/\A#{CITE}\z/o)
        raise Error, "cite claims as [C1] or [C1, C2], not #{loose.first}" unless loose.empty?
      end

      # Sources are numbered in order of first citation, counting only confirmed claims and then the claims the
      # disagreement section quotes.
      def source_numbers
        confirmed = (@cited - @unsupported) + disputed.map(&:id)
        confirmed.map { |id| @ledger.claim(id).source.url }.uniq.each_with_index.to_h { |url, index| [url, index + 1] }
      end

      def disputed
        contested = @ledger.statuses.select { |_, status| status == 'contested' }.keys
        @ledger.claims.select { |entry| contested.include?(entry.sub_question) }
      end

      def numbered(text)
        text.gsub(CITE) do
          ids = Regexp.last_match(1).upcase.split(/\s*[,;]\s*/)
          marks = ids.map do |id|
            @unsupported.include?(id) ? 'unverified' : @numbers.fetch(@ledger.claim(id).source.url)
          end
          "[#{marks.uniq.join(', ')}]"
        end
      end

      def assemble(body)
        sections = ["# #{@ledger.brief.question}", '## Summary', @summary, '## Findings', body]
        sections += ['## Where sources disagree', disagreements] unless disputed.empty?
        (sections + ['## Gaps and limits', @gaps.map { |line| "- #{line}" }.join("\n"), '## Sources',
                     sources_list]).join("\n\n")
      end

      def disagreements
        disputed.group_by(&:sub_question).map do |id, entries|
          sides = entries.map { |entry| "#{entry.text} [#{@numbers.fetch(entry.source.url)}]" }
          "- #{@ledger.brief.fetch(id).text}: #{sides.join('; ')}"
        end.join("\n")
      end

      def gap_lines(stop_reason)
        stopped = STOPPED.fetch(stop_reason) { raise Error, "unknown stop reason #{stop_reason.inspect}" }
        gaps = @ledger.statuses.filter_map do |id, status|
          "#{@ledger.brief.fetch(id).text}: #{GAPS.fetch(status)}" if GAPS.key?(status)
        end
        unconfirmed = (@cited & @unsupported).length
        gaps << "#{unconfirmed} cited claim(s) could not be confirmed against their source" if unconfirmed.positive?
        [stopped, *gaps].freeze
      end

      def sources_list
        return 'No source was cited.' if @numbers.empty?

        by_url = @ledger.sources.to_h { |source| [source.url, source] }
        @numbers.map do |url, number|
          source = by_url.fetch(url)
          date = source.published
          title = source.title
          "[#{number}] #{title.empty? ? url : title}. #{url}.#{" Published #{date}." unless date.empty?}"
        end.join("\n")
      end
    end
  end
end
