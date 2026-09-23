# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # Provider usage with disjoint input counts: cached reads are subtracted
    # from the prompt total, because DeepSeek and OpenAI both include them in it.
    Usage = Data.define(:prompt_tokens, :cache_read_tokens, :output_tokens) do
      def self.from_provider(raw)
        return nil unless raw.is_a?(Hash)

        prompt = raw['prompt_tokens']
        output = raw['completion_tokens']
        return nil unless count?(prompt) && count?(output)

        cached = raw['prompt_cache_hit_tokens'] || raw.dig('prompt_tokens_details', 'cached_tokens') || 0
        cached = 0 unless count?(cached)
        new(prompt_tokens: prompt, cache_read_tokens: [cached, prompt].min, output_tokens: output)
      end

      def self.count?(value) = value.is_a?(Integer) && value >= 0

      def self.from_h(value)
        return nil unless value

        new(prompt_tokens: value.fetch('prompt_tokens'), cache_read_tokens: value.fetch('cache_read_tokens'),
            output_tokens: value.fetch('output_tokens'))
      end

      def uncached_input_tokens = prompt_tokens - cache_read_tokens

      def cache_hit_ratio = prompt_tokens.zero? ? 0.0 : cache_read_tokens.fdiv(prompt_tokens)

      def to_h
        {
          'prompt_tokens' => prompt_tokens,
          'cache_read_tokens' => cache_read_tokens,
          'uncached_input_tokens' => uncached_input_tokens,
          'output_tokens' => output_tokens
        }
      end
    end
  end
end
