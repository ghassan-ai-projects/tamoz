# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # One record per model request: what the request looked like and what the
    # provider reported for it.
    Trace = Data.define(:series, :header_digest, :message_count, :estimated_tokens, :window, :usage, :replacements) do
      def to_h
        {
          'series_starts' => series.starts,
          'series_reason' => series.reason,
          'header_digest' => header_digest,
          'message_count' => message_count,
          'estimated_tokens' => estimated_tokens,
          'window' => window,
          'usage' => usage&.to_h,
          'replacements' => replacements
        }
      end

      # Totals over request records (`to_h` shape): the cache hit rate and cache-adjusted input.
      def self.summarize(records)
        usages = records.filter_map { |record| record['usage'] }
        prompt = usages.sum { |usage| usage.fetch('prompt_tokens') }
        cached = usages.sum { |usage| usage.fetch('cache_read_tokens') }
        { 'requests' => records.length, 'with_usage' => usages.length, 'prompt_tokens' => prompt,
          'cache_read_tokens' => cached, 'uncached_input_tokens' => prompt - cached,
          'cache_hit_ratio' => prompt.zero? ? 0.0 : (cached.to_f / prompt).round(4),
          'series_starts' => records.count { |record| record['series_starts'] },
          'undeclared_header_changes' => undeclared_changes(records).length }
      end

      # Requests whose header bytes moved without a declared trigger: a broken prefix, never a design choice.
      def self.undeclared_changes(records) = records.select { |record| record['series_reason'] == 'change' }
    end
  end
end
