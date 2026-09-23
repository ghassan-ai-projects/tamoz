# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # Deterministic, model-free trimming of old oversized tool results: keep a
    # head and a tail around a marker that carries the locator of the full text.
    module Pruner
      # One trimmed tool result and the entry that shadows the original.
      Replacement = Data.define(:replaced_seq, :text, :entry)

      # Character budgets that guarantee one-pass convergence.
      Budget = Data.define(:threshold_chars, :head_chars, :tail_chars) do
        def self.default = new(threshold_chars: 8192, head_chars: 4096, tail_chars: 1024)

        def initialize(threshold_chars:, head_chars:, tail_chars:)
          values = [threshold_chars, head_chars, tail_chars]
          unless values.all? { |value| value.is_a?(Integer) && value.positive? } &&
                 head_chars + tail_chars + 256 <= threshold_chars
            raise Error, 'prune budgets must satisfy head + tail + 256 <= threshold'
          end

          super
        end
      end

      module_function

      def prune(entries, store:, resolve:, before_seq:, budget: Budget.default)
        seq = Surface.next_seq(entries)
        candidates(entries, resolve, before_seq, budget).map do |entry, text|
          replacement = replacement_for(entry, trimmed(text, entry, budget), seq, store)
          seq += 1
          replacement
        end
      end

      def candidates(entries, resolve, before_seq, budget)
        Surface.visible(entries).filter_map do |entry|
          next unless entry.fetch('kind') == 'tool_result' && Surface.position(entry) < before_seq

          text = Surface.text(entry, resolve)
          [entry, text] if text.length > budget.threshold_chars
        end
      end

      def replacement_for(entry, text, seq, store)
        original = Surface.position(entry)
        replacement = Surface.entry(
          kind: 'tool_result', seq:, text:, store:,
          tool_call_id: entry.fetch('tool_call_id'), name: entry['name'],
          replaces: [original, original], spilled: entry['spilled'] || entry['text_ref'], source: 'prune'
        )
        Replacement.new(replaced_seq: original, text:, entry: replacement)
      end

      def trimmed(text, entry, budget)
        head = budget.head_chars
        tail = budget.tail_chars
        locator = entry['spilled'] || entry['text_ref']
        marker = "\n\n[... tool result middle pruned · #{text.length - head - tail} characters · " \
                 "recall_output {\"locator\": \"artifact:#{locator}\"} ...]\n\n"
        text[0, head] + marker + text[-tail, tail]
      end
      private_class_method :candidates, :replacement_for, :trimmed
    end
  end
end
