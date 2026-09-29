# frozen_string_literal: true

require 'json'

module Tamoz
  module Research
    # A finished run as files: the report, the accepted plan, each child's notes, the sources read and the run
    # record. Rendered here as {relative path => content}; the caller writes them.
    # :reek:DuplicateMethodCall :reek:NestedIterators :reek:TooManyStatements -- file layouts read their values in
    # place.
    module RunFolder
      module_function

      def name(date:, question:, run_id:)
        slug = Text.squash(question).downcase.gsub(/[^\p{L}\p{N}]+/, '-').delete_prefix('-')[0, 60].delete_suffix('-')
        "#{date}-#{slug.empty? ? 'research' : slug}-#{String(run_id)[0, 8]}"
      end

      # `record`: the run record (Research.run_record) that becomes run.json.
      def files(ledger:, report:, record:)
        notes = ledger.children.each_with_index.to_h do |child, index|
          ["notes/#{index + 1}.md", child_notes(ledger.brief, child, index + 1)]
        end
        { 'report.md' => "#{report.markdown}\n", 'brief.md' => brief_notes(ledger.brief, record),
          'sources.jsonl' => sources(ledger), 'run.json' => "#{JSON.pretty_generate(record)}\n" }.merge(notes)
      end

      def brief_notes(brief, record)
        lines = ["# #{brief.question}", '', "Depth: #{brief.depth}", '']
        lines += brief.sub_questions.map do |sub|
          "- #{sub.id} #{sub.text} (#{sub.perspective}): #{record.dig('statuses', sub.id)}"
        end
        lines += ['', "Left out: #{brief.left_out.join('; ')}"] unless brief.left_out.empty?
        (lines + ['', "Stopped: #{record.fetch('stop_reason')}"]).join("\n") << "\n"
      end

      def child_notes(brief, child, number)
        assigned = child.sub_question_ids.map { |id| "#{id} #{brief.fetch(id).text}" }.join('; ')
        lines = ["# Child #{number} (wave #{child.wave})", '', "Sub-questions: #{assigned}",
                 "Searches: #{child.searches}. Page reads: #{child.page_reads}.", '']
        lines += child.sources ? findings_notes(child.sources) : ['No accepted sources.']
        lines.join("\n") << "\n"
      end

      def findings_notes(sources)
        sources.findings.each_with_object([sources.summary]) do |finding, lines|
          lines.push('', "## #{finding.sub_question}: #{finding.status}")
          lines.concat(finding.claims.map { |claim| "- #{claim.text}\n  > #{claim.excerpt}\n  #{claim.url}" })
        end
      end

      def sources(ledger)
        ledger.sources.map { |source| JSON.generate(source.to_h.transform_keys(&:to_s)) }.join("\n") << "\n"
      end
    end
  end
end
