# frozen_string_literal: true

module Tamoz
  module Skills
    # The per-skill authoring bar (QUALITY_BAR Q1–Q5). Returns one line per issue; empty means the skill meets it.
    # :reek:UtilityFunction — each rule is a pure question about one compiled record.
    module Lint
      TRIGGER = /\bUse (?:this )?(?:when|for)\b/i
      MAX_BODY_LINES = 500
      AREA_PATH = %r{\b(?:references|assets|scripts)/[A-Za-z0-9._/-]*[A-Za-z0-9_-]}
      LINK = /\]\(([^)\s#]+)\)/

      module_function

      def call(record)
        [description(record), body_length(record), *dangling(record), *orphans(record), risk(record)].compact
      end

      def description(record)
        text = record.description
        return "Q1: the description is #{text.bytesize} bytes; the catalog shows #{MAX_CATALOG_DESCRIPTION_BYTES}" if
          text.bytesize > MAX_CATALOG_DESCRIPTION_BYTES
        return nil if TRIGGER.match?(text)

        'Q1: the description does not say when to use the skill ("Use when ...")'
      end

      def body_length(record)
        lines = record.body.lines.length
        "Q2: the body is #{lines} lines; keep it under #{MAX_BODY_LINES}" if lines > MAX_BODY_LINES
      end

      def dangling(record)
        (mentioned(record) - record.resource_index.keys).map do |path|
          "Q3: the body mentions #{path}, which the skill does not ship"
        end
      end

      def orphans(record)
        shipped = record.resource_index.keys.grep(%r{\A(?:references|assets|scripts)/})
        (shipped - mentioned(record)).map { |path| "Q4: #{path} is never mentioned by the body" }
      end

      def risk(record)
        'Q5: metadata tamoz.risk is not declared' unless record.metadata.key?('tamoz.risk')
      end

      def mentioned(record)
        body = record.body
        links = body.scan(LINK).flatten.reject { |target| target.include?('://') }
        (links + body.scan(AREA_PATH)).uniq
      end
    end
  end
end
