# frozen_string_literal: true

module Tamoz
  module Observability
    # A blameless postmortem of a window, assembled from a diagnosis, a timeline and an optional analysis.
    module Postmortem
      FORMAT_VERSION = 1
      ANALYSIS_FIELDS = %w[summary hypothesis confidence findings].freeze

      module_function

      def build(title:, report:, timeline:, until_ms:, analysis: nil)
        Diagnosis.redact({
                           'format_version' => FORMAT_VERSION, 'title' => title,
                           'window' => { 'since_ms' => report.fetch('since_ms'), 'until_ms' => until_ms },
                           'generated_at_ms' => report.fetch('generated_at_ms'),
                           'impact' => impact(report, timeline),
                           'timeline' => timeline,
                           'findings' => report.fetch('findings'),
                           'unknowns' => report.fetch('degraded_reasons'),
                           'proposed_actions' => report.fetch('findings').map do |finding|
                             finding.fetch('action')
                           end.uniq,
                           'analysis' => analysis && validated_analysis(analysis),
                           'diagnosis' => report.slice('rules_digest', 'sources', 'journal', 'summary')
                         })
      end

      def impact(report, timeline)
        {
          'failed_turns' => report.dig('summary', 'requests').fetch('failed', 0),
          'threads_with_failures' => timeline.fetch('threads_with_failures'),
          'findings_by_severity' => report.fetch('findings').map { |finding| finding.fetch('severity') }.tally
        }
      end

      def validated_analysis(document)
        report = document.is_a?(Hash) ? document['report'] || document : nil
        raise ValidationError, 'the analysis is not a findings report' unless findings_report?(report)

        report.slice(*ANALYSIS_FIELDS, 'gaps', 'proposals').merge('thread_id' => document['thread_id']).compact
      end

      def findings_report?(report)
        report.is_a?(Hash) && ANALYSIS_FIELDS.all? { |field| report.key?(field) } &&
          report['findings'].is_a?(Array) &&
          report['findings'].all? { |finding| finding.is_a?(Hash) && finding['statement'].is_a?(String) }
      end

      def to_markdown(postmortem)
        sections = [
          heading(postmortem), impact_lines(postmortem), analysis_lines(postmortem['analysis']),
          timeline_lines(postmortem['timeline']), Diagnosis::Markdown.findings('findings' => postmortem['findings']),
          list('Unknowns', postmortem['unknowns']),
          list('Proposed actions (not executed)', postmortem['proposed_actions'])
        ]
        sections.flatten.join("\n")
      end

      def heading(postmortem)
        window = postmortem['window']
        ["# Postmortem: #{postmortem['title']}", '',
         "Window: #{time(window['since_ms'])} → #{time(window['until_ms'])} · " \
         "generated #{time(postmortem['generated_at_ms'])}",
         '', 'Blameless; assembled read-only from the durable record. Proposed actions are never executed.', '']
      end

      def impact_lines(postmortem)
        impact = postmortem['impact']
        ['## Impact', '', "- Failed turns: #{impact['failed_turns']}",
         "- Threads with failures: #{impact['threads_with_failures'].join(', ').then do |text|
           text.empty? ? 'none' : text
         end}",
         "- Findings by severity: #{impact['findings_by_severity'].map do |key, count|
           "#{key} #{count}"
         end.join(', ')}", '']
      end

      def analysis_lines(analysis)
        return ['## Analysis', '', 'No model analysis attached (`--analysis`).', ''] unless analysis

        ['## Analysis (the attached findings report; this command does not verify it)', '',
         "**Summary:** #{analysis['summary']}", '',
         "**Hypothesis (#{analysis['confidence']}):** #{analysis['hypothesis']}", '',
         analysis['findings'].map do |finding|
           "- #{finding['statement']} [#{Array(finding['evidence']).join(', ')}]"
         end, '']
      end

      def timeline_lines(timeline)
        events = timeline['events']
        ['## Timeline', '', events.empty? ? 'No events in the window.' : nil,
         events.map { |event| timeline_line(event) },
         timeline['truncated'] ? "_Only the last #{Timeline::MAX_EVENTS} events are shown._" : nil, ''].compact
      end

      def timeline_line(event)
        failure = event['failure'] && [event.dig('failure', 'class'), event.dig('failure', 'code')].compact.join('/')
        suffix = failure ? " — #{failure}" : ''
        "- #{time(event['at_ms'])} `#{event['source']}` #{event['what']}#{suffix} (`#{event['key']}`)"
      end

      def list(title, items)
        ["## #{title}", '', items.empty? ? 'None.' : items.map { |item| "- #{item}" }, '']
      end

      def time(milliseconds) = Diagnosis::Markdown.time(milliseconds)
    end
  end
end
