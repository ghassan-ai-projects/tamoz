# frozen_string_literal: true

module Tamoz
  module Harness
    # The report_findings document: every finding and proposal cites probe calls this turn made and got answers from.
    class FindingsReport
      CONFIDENCES = %w[low medium high].freeze
      MAX_TEXT = 2000

      attr_reader :document

      # gathered: {tool_call_id => probe name} for the probe calls of this turn that succeeded.
      def self.parse(arguments, gathered:)
        raise ReportError, 'the report must be an object' unless arguments.is_a?(Hash)

        new({ 'summary' => text!(arguments['summary'], 'summary'),
              'hypothesis' => text!(arguments['hypothesis'], 'hypothesis'),
              'confidence' => confidence!(arguments['confidence']),
              'findings' => entries!(arguments['findings'], 'findings', 1..20, %w[statement evidence], gathered),
              'gaps' => entries!(arguments['gaps'], 'gaps', 0..20, %w[datum why], gathered),
              'proposals' => entries!(arguments['proposals'], 'proposals', 0..10, %w[action rationale evidence],
                                      gathered) }, gathered)
      end

      def self.text!(value, name)
        raise ReportError, "#{name} must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?
        raise ReportError, "#{name} exceeds #{MAX_TEXT} characters" if value.length > MAX_TEXT

        value.strip
      end

      def self.confidence!(value)
        return value if CONFIDENCES.include?(value)

        raise ReportError, "confidence must be one of #{CONFIDENCES.join(', ')}"
      end

      def self.entries!(value, name, count, fields, gathered)
        unless value.is_a?(Array) && count.cover?(value.length)
          raise ReportError, "#{name} must be a list of #{count.min}..#{count.max} entries"
        end

        value.map { |entry| entry!(entry, name, fields, gathered) }
      end

      def self.entry!(entry, name, fields, gathered)
        raise ReportError, "each of #{name} must be an object with #{fields.join(', ')}" unless
          entry.is_a?(Hash) && (entry.keys - fields).empty?

        fields.to_h do |field|
          field == 'evidence' ? [field, evidence!(entry[field], name, gathered)] : [field, text!(entry[field], field)]
        end
      end

      def self.evidence!(value, name, gathered)
        raise ReportError, "#{name} evidence must cite at least one probe call id" unless
          value.is_a?(Array) && !value.empty?

        ungathered = value.reject { |id| gathered.key?(id) }
        return value.uniq if ungathered.empty?
        raise ReportError, 'no probe call has answered in this turn, so there is nothing to cite' if gathered.empty?

        raise ReportError, "#{name} cites #{ungathered.first.inspect}, which is not a probe call that answered " \
                           "in this turn; cite only: #{gathered.keys.join(', ')}"
      end
      private_class_method :text!, :confidence!, :entries!, :entry!, :evidence!

      def initialize(document, gathered)
        @document = Tamoz::Core.deep_freeze(document)
        @gathered = gathered
        freeze
      end

      def render
        lines = ["#{label('summary')}: #{@document.fetch('summary')}",
                 "#{label('hypothesis', confidence: @document.fetch('confidence'))}: #{@document.fetch('hypothesis')}",
                 "#{label('findings')}:"]
        @document.fetch('findings').each_with_index do |finding, index|
          lines << "#{index + 1}. #{finding.fetch('statement')} [#{sources(finding)}]"
        end
        lines.concat(gap_lines).concat(proposal_lines).join("\n")
      end

      private

      def label(key, **values) = format(PromptPack.report_labels.fetch(key), **values)

      def sources(entry)
        label('source', probes: entry.fetch('evidence').map { |id| @gathered.fetch(id) }.uniq.join(', '))
      end

      def gap_lines
        gaps = @document.fetch('gaps')
        return [] if gaps.empty?

        ["#{label('gaps')}:"] + gaps.map { |gap| "- #{gap.fetch('datum')}: #{gap.fetch('why')}" }
      end

      def proposal_lines
        proposals = @document.fetch('proposals')
        return [] if proposals.empty?

        ["#{label('proposals')}:"] + proposals.each_with_index.map do |proposal, index|
          "#{index + 1}. #{proposal.fetch('action')}: #{proposal.fetch('rationale')} [#{sources(proposal)}]"
        end
      end
    end
  end
end
