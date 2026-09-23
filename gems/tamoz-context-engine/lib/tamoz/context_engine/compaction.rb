# frozen_string_literal: true

require 'json'

module Tamoz
  module ContextEngine
    # Replaces the oldest balanced run of unpinned history with a summary; the summariser request is a prefix extension.
    module Compaction
      SECTIONS = [
        'Primary Request and Intent', 'Plan State', 'Files and Code', 'Errors and Fixes', 'Decisions',
        'Ruled Out', 'Exact Strings', 'Offloaded Artifacts', 'Pending Work', 'Current Work', 'Next Step'
      ].freeze

      # The span a compaction replaces, as surface positions.
      Selection = Data.define(:first_seq, :last_seq, :entries) do
        def to_h = { 'first_seq' => first_seq, 'last_seq' => last_seq, 'count' => entries.length }

        def source_bytes(resolve)
          entries.sum { |entry| Tamoz::Core.jcs(Surface.message(entry, resolve)).bytesize }
        end
      end

      module_function

      def select(entries, retain_tokens:, resolve:)
        visible = Surface.visible(entries)
        start = visible.index { |entry| entry['pinned'] != true } || visible.length
        cut = [retained_cut(visible, start, retain_tokens, resolve), next_pinned(visible, start)].min
        cut -= 1 while cut > start && !Surface.balanced_cut?(visible, cut)
        return nil if cut <= start

        span = visible[start...cut]
        Selection.new(first_seq: Surface.position(span.first), last_seq: Surface.reach(span.last), entries: span)
      end

      # Paths passed to the named tools inside the span; a summary must keep them verbatim.
      def required_strings(selection, tools:, resolve:)
        calls = selection.entries.flat_map { |entry| Surface.tool_calls(entry, resolve) }
        calls.filter_map { |call| path_argument(call) if tools.include?(call.fetch('name')) }.uniq
      end

      def summary_messages(entries, header:, selection:, resolve:)
        visible = Surface.visible(entries)
        through = visible.index(selection.entries.last)
        raise Error, 'selection is not on the current surface' unless through

        [header.system_message] +
          visible.first(through + 1).map { |entry| Surface.message(entry, resolve) } +
          [{ 'role' => 'user', 'content' => Prompts.fetch('compaction_instruction') }]
      end

      def checkpoint_text(summary)
        "#{Prompts.fetch('checkpoint_preamble')}\n\n<compacted-summary>\n#{summary.strip}\n</compacted-summary>"
      end

      def checkpoint_entry(summary, selection:, entries:, store:)
        Surface.entry(
          kind: 'checkpoint', seq: Surface.next_seq(entries), text: checkpoint_text(summary), store:,
          replaces: [selection.first_seq, selection.last_seq], source: 'compaction'
        )
      end

      def validate!(summary, source_bytes:, required_strings: [])
        unless summary.is_a?(String) && !summary.strip.empty?
          raise InvalidSummaryError,
                'summary must be a non-empty String'
        end
        raise InvalidSummaryError, 'summary is not smaller than its source' unless summary.bytesize < source_bytes

        refuse_missing!('sections', SECTIONS.reject { |section| section?(summary, section) })
        refuse_missing!('exact strings', required_strings.uniq.reject { |value| summary.include?(value) })
        summary
      end

      def section?(summary, section) = summary.match?(/^##\s+#{Regexp.escape(section)}\s*$/i)

      def refuse_missing!(label, missing)
        raise InvalidSummaryError, "summary is missing #{label}: #{missing.join(', ')}" unless missing.empty?
      end

      def next_pinned(visible, start)
        visible.each_index.find { |index| index > start && visible[index]['pinned'] } || visible.length
      end

      def path_argument(call)
        path = JSON.parse(call.fetch('arguments'))['path']
        path if path.is_a?(String) && !path.empty?
      rescue JSON::ParserError
        nil
      end

      def retained_cut(visible, start, retain_tokens, resolve)
        kept = 0
        index = visible.length
        while index > start
          kept += TokenMeter.heuristic(Surface.message(visible[index - 1], resolve))
          break if kept > retain_tokens

          index -= 1
        end
        [index, visible.length - 1].min
      end
      private_class_method :section?, :refuse_missing!, :path_argument, :retained_cut, :next_pinned
    end
  end
end
