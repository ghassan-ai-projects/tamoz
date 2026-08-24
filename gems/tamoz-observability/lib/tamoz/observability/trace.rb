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
        selected = select_matching_signals(signals, thread_id:, execution_id:)
        correlation = first_populated_correlation(selected)
        build_trace(selected, trace_id_from(correlation))
      end

      def self.from_documents(documents, thread_id: nil, execution_id: nil)
        selected = select_matching_documents(documents, thread_id:, execution_id:)
        correlation = first_complete_document_correlation(selected)
        build_trace(selected, trace_id_from_document_correlation(correlation))
      end

      def to_h
        {'trace_id' => trace_id, 'spans' => spans.map(&:to_h), 'divergence' => divergence}
      end

      def to_json(*args)
        JSON.generate(to_h, *args)
      end

      class << self
        private

        def select_matching_signals(signals, thread_id:, execution_id:)
          signals.select do |signal|
            correlation_matches?(signal_correlation(signal), thread_id:, execution_id:)
          end
        end

        def select_matching_documents(documents, thread_id:, execution_id:)
          documents.select do |document|
            document_correlation_matches?(document_correlation(document), thread_id:, execution_id:)
          end
        end

        def build_trace(selected, trace_id)
          spans = selected.map { |item| span_from(item, trace_id:) }.compact
          new(trace_id: trace_id, spans: spans, divergence: [])
        end

        def signal_correlation(signal)
          signal.respond_to?(:correlation) ? signal.correlation : signal.fetch('correlation', {})
        end

        def document_correlation(document)
          document.fetch('correlation', {})
        end

        def correlation_matches?(correlation, thread_id:, execution_id:)
          thread_matches?(correlation, thread_id) && execution_matches?(correlation, execution_id)
        end

        def document_correlation_matches?(correlation, thread_id:, execution_id:)
          (!thread_id || correlation['thread_id'] == thread_id) &&
            (!execution_id || correlation['execution_id'] == execution_id)
        end

        def thread_matches?(correlation, thread_id)
          return true unless thread_id

          correlation.fetch(:thread_id, correlation['thread_id']) == thread_id
        end

        def execution_matches?(correlation, execution_id)
          return true unless execution_id

          correlation.fetch(:execution_id, correlation['execution_id']) == execution_id
        end

        def first_populated_correlation(signals)
          signals.lazy
                 .map { |signal| signal.respond_to?(:correlation) ? signal.correlation : signal.fetch('correlation') }
                 .find(&:any?) || {}
        end

        def first_complete_document_correlation(documents)
          documents.map { |document| document_correlation(document) }
                   .find { |correlation| correlation['thread_id'] && correlation['execution_id'] } || {}
        end

        def trace_id_from(correlation)
          thread_id = correlation[:thread_id] || correlation['thread_id']
          execution_id = correlation[:execution_id] || correlation['execution_id']
          return unless thread_id && execution_id

          Correlation.trace_id(thread_id:, execution_id:)
        end

        def trace_id_from_document_correlation(correlation)
          return unless correlation['thread_id'] && correlation['execution_id']

          Correlation.trace_id(thread_id: correlation['thread_id'], execution_id: correlation['execution_id'])
        end

        def span_from(signal, trace_id:)
          document = document_from(signal)
          return unless trace_id

          attributes = span_attributes(document)
          anchor = span_anchor(document, attributes)
          name = document.fetch('name')
          span_id = Correlation.span_id(trace_id:, kind: name, anchor:)
          build_span(trace_id:, name:, document:, attributes:, span_id:)
        end

        def document_from(signal)
          signal.respond_to?(:to_h) ? signal.to_h : signal
        end

        def span_attributes(document)
          document.fetch('attributes', {})
        end

        def span_anchor(document, attributes)
          attributes['span_anchor'] ||
            document.dig('correlation', 'effect_key') ||
            document['observed_at_ms']
        end

        def build_span(trace_id:, name:, document:, attributes:, span_id:)
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
