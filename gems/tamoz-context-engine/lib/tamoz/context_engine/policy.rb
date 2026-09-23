# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # When to prune, compact and hand off, per model route.
    Policy = Data.define(
      :threshold_ratio, :backstop_ratio, :retain_ratio, :max_compactions_per_turn, :summary_max_tokens,
      :overflow_retries, :max_inline_bytes, :prune_threshold_chars, :prune_head_chars, :prune_tail_chars,
      :read_window_lines
    ) do
      def self.default
        new(
          threshold_ratio: 0.8, backstop_ratio: 0.92, retain_ratio: 0.16, max_compactions_per_turn: 1,
          summary_max_tokens: 8192, overflow_retries: 1, max_inline_bytes: 8192,
          prune_threshold_chars: 8192, prune_head_chars: 4096, prune_tail_chars: 1024, read_window_lines: 800
        )
      end

      def self.from_h(overrides)
        unknown = overrides.keys.map(&:to_s) - members.map(&:to_s)
        raise Error, "unknown context policy keys: #{unknown.join(', ')}" unless unknown.empty?

        default.with(**overrides.transform_keys(&:to_sym))
      end

      def initialize(**values)
        ratios = values.values_at(:threshold_ratio, :backstop_ratio, :retain_ratio)
        unless ratios.all? { |ratio| ratio.is_a?(Numeric) && ratio.positive? && ratio < 1 } &&
               values.fetch(:retain_ratio) < values.fetch(:threshold_ratio) &&
               values.fetch(:threshold_ratio) <= values.fetch(:backstop_ratio)
          raise Error, 'context ratios must satisfy 0 < retain < threshold <= backstop < 1'
        end

        super
      end

      def threshold_tokens(window) = (window * threshold_ratio).floor
      def backstop_tokens(window) = (window * backstop_ratio).floor
      def retain_tokens(window) = (window * retain_ratio).floor

      def prune_budget
        Pruner::Budget.new(threshold_chars: prune_threshold_chars, head_chars: prune_head_chars,
                           tail_chars: prune_tail_chars)
      end

      # The work route applies the read window here, at its gate, so the pipeline, the healing
      # preflight and every other read_file caller keep their own behaviour. A read without a
      # range is a window, and the window is policy.
      def window_arguments(name, arguments)
        return arguments unless name == 'read_file'
        return arguments if arguments.key?('offset') || arguments.key?('limit')

        arguments.merge('offset' => 1, 'limit' => read_window_lines)
      end
    end
  end
end
