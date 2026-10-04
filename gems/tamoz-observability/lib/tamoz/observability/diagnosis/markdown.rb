# frozen_string_literal: true

require 'time'

module Tamoz
  module Observability
    module Diagnosis
      # Renders a diagnosis report document as Markdown for an operator.
      module Markdown
        module_function

        def render(report)
          [header(report), degraded(report), findings(report), operations(report)].flatten.join("\n")
        end

        def header(report)
          [
            '# Tamoz self-diagnosis', '',
            "Window: #{time(report['since_ms'])} → #{time(report['generated_at_ms'])}  ",
            "Rules: `#{report['rules_digest']}`  ",
            "Requests: #{counts(report.dig('summary', 'requests'))} · " \
            "Effects: #{counts(report.dig('summary', 'effects'))}",
            ''
          ]
        end

        def degraded(report)
          return [] unless report['degraded']

          ['**Degraded — the evidence below is incomplete:**', '',
           report['degraded_reasons'].map { |reason| "- #{reason}" }, '']
        end

        def findings(report)
          list = report['findings']
          return ['## Findings', '', 'No rule fired.', ''] if list.empty?

          ['## Findings', '', list.map { |finding| finding_section(finding) }]
        end

        def finding_section(finding)
          [
            "### [#{finding['severity']}] #{finding['title']} (#{finding['count']})", '',
            "Rule `#{finding['rule_id']}` · category `#{finding['category']}` · finding `#{finding['id']}`  ",
            "Seen #{time(finding['first_seen_ms'])} → #{time(finding['last_seen_ms'])}", '',
            "**Action:** #{finding['action']}", '',
            finding['evidence'].map { |entry| "- `#{entry['kind']}` `#{entry['key']}`#{evidence_note(entry)}" }, ''
          ]
        end

        def evidence_note(entry)
          parts = [entry['operation'], entry['status'] || entry['state'] || entry['verdict'] || entry['name'],
                   entry.dig('failure', 'class'), entry.dig('failure', 'code')].compact
          parts.empty? ? '' : " — #{parts.join(' · ')}"
        end

        def operations(report)
          lines = report.dig('summary', 'operations')
          return [] if lines.empty?

          ['## Operations in the window', '', '| Operation | Attempts | Failed | p50 ms | p95 ms |',
           '|---|---|---|---|---|', lines.map { |line| operation_row(line) }, '']
        end

        def operation_row(line)
          cells = [
            "`#{line['operation']}`", line['attempts'], line['failed'], line['p50_ms'], line['p95_ms']
          ]
          "| #{cells.join(' | ')} |"
        end

        def counts(hash)
          hash.empty? ? 'none' : hash.map { |status, count| "#{status} #{count}" }.join(', ')
        end

        def time(milliseconds)
          milliseconds ? Time.at(milliseconds / 1000.0).utc.iso8601 : '—'
        end
      end
    end
  end
end
