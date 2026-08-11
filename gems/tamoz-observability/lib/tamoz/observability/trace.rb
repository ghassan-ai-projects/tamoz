# frozen_string_literal: true

module Tamoz
  module Observability
    class Trace
      Span = Data.define(
        :span_id, :trace_id, :name, :parent_span_id, :timing,
        :started_at_ms, :ended_at_ms, :observed_at_ms, :attributes, :outcome
      ) do
        def duration_ms
          return nil unless timing == :interval
          return nil unless started_at_ms && ended_at_ms

          ended_at_ms - started_at_ms
        end

        def to_h
          {
            'span_id' => span_id,
            'trace_id' => trace_id,
            'name' => name,
            'parent_span_id' => parent_span_id,
            'timing' => timing.to_s,
            'started_at_ms' => started_at_ms,
            'ended_at_ms' => ended_at_ms,
            'observed_at_ms' => observed_at_ms,
            'duration_ms' => duration_ms,
            'attributes' => attributes,
            'outcome' => outcome.to_s
          }.compact
        end
      end

      attr_reader :trace_id, :spans, :divergence

      def initialize(trace_id:, spans:, divergence: [])
        @trace_id = trace_id
        @spans = spans.freeze
        @divergence = divergence.freeze
        freeze
      end

      def self.from_signals(signals, thread_id: nil, execution_id: nil)
        selected = signals.select do |signal|
          correlation = signal.respond_to?(:correlation) ? signal.correlation : signal.fetch('correlation', {})
          (!thread_id || correlation.fetch(:thread_id, correlation['thread_id']) == thread_id) &&
            (!execution_id || correlation.fetch(:execution_id, correlation['execution_id']) == execution_id)
        end
        correlation = selected.lazy.map { |signal| signal.respond_to?(:correlation) ? signal.correlation : signal.fetch('correlation') }.find(&:any?) || {}
        trace_id = if (correlation[:thread_id] || correlation['thread_id']) &&
                     (correlation[:execution_id] || correlation['execution_id'])
                     Correlation.trace_id(
                       thread_id: correlation[:thread_id] || correlation['thread_id'],
                       execution_id: correlation[:execution_id] || correlation['execution_id']
                     )
                   end
        spans = selected.map { |signal| span_from(signal, trace_id:) }.compact
        new(trace_id: trace_id, spans: spans, divergence: [])
      end

      def self.from_documents(documents, thread_id: nil, execution_id: nil)
        selected = documents.select do |document|
          correlation = document.fetch('correlation', {})
          (!thread_id || correlation['thread_id'] == thread_id) &&
            (!execution_id || correlation['execution_id'] == execution_id)
        end
        correlation = selected.map { |document| document.fetch('correlation', {}) }.find do |candidate|
          candidate['thread_id'] && candidate['execution_id']
        end || {}
        trace_id = if correlation['thread_id'] && correlation['execution_id']
                     Correlation.trace_id(thread_id: correlation['thread_id'], execution_id: correlation['execution_id'])
                   end
        spans = selected.map { |document| span_from(document, trace_id:) }.compact
        new(trace_id: trace_id, spans: spans, divergence: [])
      end

      def to_h
        {'trace_id' => trace_id, 'spans' => spans.map(&:to_h), 'divergence' => divergence}
      end

      def to_json(*args)
        JSON.generate(to_h, *args)
      end

      class << self
        private

        def span_from(signal, trace_id:)
          document = signal.respond_to?(:to_h) ? signal.to_h : signal
          return unless trace_id

          attributes = document.fetch('attributes', {})
          anchor = attributes['span_anchor'] || document.dig('correlation', 'effect_key') || document['observed_at_ms']
          name = document.fetch('name')
          span_id = Correlation.span_id(trace_id:, kind: name, anchor:)
          Span.new(
            span_id:,
            trace_id:,
            name:,
            parent_span_id: attributes['parent_span_id'],
            timing: document.fetch('timing').to_sym,
            started_at_ms: document['started_at_ms'],
            ended_at_ms: document['ended_at_ms'],
            observed_at_ms: document['observed_at_ms'],
            attributes: attributes,
            outcome: document.fetch('outcome', 'ok').to_sym
          )
        end
      end
    end
  end
end
