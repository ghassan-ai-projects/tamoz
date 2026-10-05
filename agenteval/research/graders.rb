# frozen_string_literal: true

require "json"

module Agenteval
  module Research
    # Grades a finished research folder (report.md, sources.jsonl, notes/*.md, run.json) against a pre-registered
    # question. Deterministic; the judge-backed citation-support grade lives in Judge.
    module Graders
      Folder = Data.define(:report, :sources, :excerpts, :record)
      CITE = /\[(\d+(?:\s*,\s*\d+)*)\]/
      SOURCE_LINE = /^\[(\d+)\] (.*)$/

      module_function

      def load(dir)
        report = File.read(File.join(dir, "report.md"), encoding: Encoding::UTF_8)
        sources = report.split(/^## Sources\s*$/, 2)[1].to_s.lines.filter_map do |line|
          number, text = line.match(SOURCE_LINE)&.captures
          [Integer(number), text] if number
        end.to_h
        record = JSON.parse(File.read(File.join(dir, "run.json"), encoding: Encoding::UTF_8))
        Folder.new(report:, sources:, excerpts: excerpts(dir), record:)
      end

      # {url => [excerpt, ...]} from the children's notes.
      def excerpts(dir)
        Dir[File.join(dir, "notes", "*.md")].each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |path, found|
          File.read(path, encoding: Encoding::UTF_8).scan(/^\s+> (.+)\n\s+(https?:\S+)$/) { |excerpt, url| found[url] << excerpt }
        end
      end

      # [[sentence, [source numbers]]] for the summary and findings, not the gaps or the sources list.
      def sentences(folder)
        body = folder.report.split(/^## (Gaps and limits|Sources)\s*$/, 2).first
        prose = body.lines.reject { |line| line.start_with?("#") }.map { |line| line.sub(/^\s*[-*]\s+/, "") }.join(" ")
        prose.split(/(?<=[.!?])\s+(?=[A-Z0-9"(])/).map(&:strip).reject(&:empty?).map do |sentence|
          [sentence, sentence.scan(CITE).flat_map { |group| group.first.split(",").map { |number| Integer(number) } }]
        end
      end

      # Every cited number must name a listed source.
      def structure(folder)
        cited = sentences(folder).flat_map(&:last).uniq
        { "cited_sentences" => sentences(folder).count { |_, numbers| numbers.any? },
          "dangling" => cited - folder.sources.keys, "unverified" => folder.report.scan("[unverified]").length }
      end

      # A fact counts only when a sentence that states it also cites a source.
      def recall(folder, question)
        facts = question.fetch("facts")
        return nil if facts.empty?

        cited = sentences(folder).select { |_, numbers| numbers.any? }.map(&:first)
        recalled = facts.select do |fact|
          patterns = fact.fetch("any").map { |pattern| Regexp.new(pattern, Regexp::IGNORECASE) }
          cited.any? { |sentence| patterns.any? { |pattern| pattern.match?(sentence) } }
        end.map { |fact| fact.fetch("id") }
        { "recalled" => recalled, "missed" => facts.map { |fact| fact.fetch("id") } - recalled,
          "score" => recalled.length.fdiv(facts.length).round(3) }
      end

      # The share of cited sources published on or after the question's date.
      def recency(folder, question)
        after = question["after"]
        return nil unless after

        cited = sentences(folder).flat_map(&:last).uniq.filter_map { |number| folder.sources[number] }
        return 0.0 if cited.empty?

        recent = cited.count { |text| (date = text[/Published (\d{4}-\d{2}-\d{2})/, 1]) && date >= after }
        recent.fdiv(cited.length).round(3)
      end

      # What the judge sees for citation support: each cited sentence with the excerpts of the pages it cites.
      def support_items(folder)
        sentences(folder).select { |_, numbers| numbers.any? }.map do |sentence, numbers|
          urls = numbers.filter_map { |number| folder.sources[number]&.[](%r{https?://\S+?(?=\.?\s|\.?$)}) }
          { "sentence" => sentence, "excerpts" => urls.flat_map { |url| folder.excerpts[url] }.uniq }
        end
      end

      def cost(folder)
        record = folder.record
        { "tokens" => record.dig("tokens", "total"), "searches" => record["searches"],
          "page_reads" => record["page_reads"], "children" => record["children"], "waves" => record["waves"],
          "stop_reason" => record["stop_reason"] }
      end
    end
  end
end
