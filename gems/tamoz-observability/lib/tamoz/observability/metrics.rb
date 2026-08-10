# frozen_string_literal: true

require 'json'

module Tamoz
  module Observability
    class Metrics
      LOW_CARDINALITY_RE = /\A[a-zA-Z0-9_.:-]{1,128}\z/
      IDENTIFIER_LABELS = SignalCatalog::CORRELATION_IDENTIFIERS
      DEFAULT_MAX_SERIES = 4_096
      DEFAULT_MAX_HISTOGRAM_SAMPLES = 10_000

      attr_reader :violations

      def initialize(catalog: Catalog, max_series: DEFAULT_MAX_SERIES,
                     max_histogram_samples: DEFAULT_MAX_HISTOGRAM_SAMPLES)
        @catalog = catalog
        @max_series = positive_integer(max_series, :max_series)
        @max_histogram_samples = positive_integer(max_histogram_samples, :max_histogram_samples)
        @counters = Hash.new(0)
        @gauges = {}
        @histograms = Hash.new { |hash, key| hash[key] = [] }
        @violations = Hash.new(0)
      end

      def increment(name, value: 1, labels: {})
        entry = definition(name)
        validate_labels!(entry, labels)
        value = Float(value)
        raise ValidationError, 'metric value must be finite and non-negative' unless value.finite? && value >= 0

        key = series_key(entry.name, labels)
        register_series!(key, entry.name)
        @counters[key] += value
        value
      rescue StandardError
        @violations[name.to_s] += 1
        :rejected
      end

      def observe(name, value, labels: {})
        entry = definition(name)
        validate_labels!(entry, labels)
        value = Float(value)
        raise ValidationError, 'histogram value must be finite and non-negative' unless value.finite? && value >= 0

        key = series_key(entry.name, labels)
        register_series!(key, entry.name)
        values = @histograms[key]
        raise ValidationError, "#{entry.name}: histogram sample limit reached" if values.length >= @max_histogram_samples

        values << value
        value
      rescue StandardError
        @violations[name.to_s] += 1
        :rejected
      end

      def set(name, value, labels: {})
        entry = definition(name)
        validate_labels!(entry, labels)
        value = Float(value)
        raise ValidationError, 'gauge value must be finite' unless value.finite?

        key = series_key(entry.name, labels)
        register_series!(key, entry.name)
        @gauges[key] = value
        value
      rescue StandardError
        @violations[name.to_s] += 1
        :rejected
      end

      def add_signal(signal)
        return add_document(signal) if signal.is_a?(Hash)
        return :ignored unless signal.is_a?(Signal)

        case signal.name
        when 'tamoz.model.call'
          duration = signal.attributes['duration_ms'] || signal.attributes[:duration_ms]
          observe('tamoz.model.call.duration_ms', duration, labels: labels(signal, %i[provider model outcome])) if duration
        when 'tamoz.tool.call'
          duration = signal.attributes['duration_ms'] || signal.attributes[:duration_ms]
          observe('tamoz.tool.call.duration_ms', duration, labels: labels(signal, %i[tool source outcome])) if duration
        end
        :recorded
      rescue StandardError
        @violations[signal.name] += 1
        :rejected
      end

      def add_document(document)
        name = document.fetch('name')
        attributes = document.fetch('attributes', {})
        case name
        when 'tamoz.model.call'
          duration = attributes['duration_ms']
          observe('tamoz.model.call.duration_ms', duration,
                  labels: attributes.slice('provider', 'model').merge('outcome' => document.fetch('outcome', 'ok'))) if duration
        when 'tamoz.tool.call'
          duration = attributes['duration_ms']
          observe('tamoz.tool.call.duration_ms', duration,
                  labels: attributes.slice('tool', 'source').merge('outcome' => document.fetch('outcome', 'ok'))) if duration
        end
        :recorded
      rescue StandardError
        @violations[document.fetch('name', 'unknown')] += 1
        :rejected
      end

      def self.from_signals(signals, catalog: Catalog)
        metrics = new(catalog:)
        signals.each { |signal| metrics.add_signal(signal) }
        metrics
      end

      def self.from_documents(documents, catalog: Catalog)
        metrics = new(catalog:)
        documents.each { |document| metrics.add_document(document) }
        metrics
      end

      def to_h
        {
          'counters' => serialize_series(@counters),
          'gauges' => serialize_series(@gauges),
          'histograms' => @histograms.map do |(name, labels), values|
            {'name' => name, 'labels' => labels, 'count' => values.length, 'sum' => values.sum,
             'max' => values.max, 'p99' => percentile(values, 0.99)}
          end,
          'violations' => @violations.dup
        }
      end

      def prometheus
        lines = []
        @counters.each { |key, value| lines << render_series(key, value) }
        @gauges.each { |key, value| lines << render_series(key, value) }
        @histograms.each do |key, values|
          lines << render_series(key, values.length, suffix: '_count')
          lines << render_series(key, values.sum, suffix: '_sum')
        end
        lines.join("\n") + (lines.empty? ? '' : "\n")
      end

      def health
        {'violations' => @violations.dup, 'series' => @counters.length + @gauges.length + @histograms.length}
      end

      private

      def definition(name)
        entry = @catalog.fetch(name)
        raise ValidationError, "#{name}: not a measurement" unless entry.kind == :measurement

        entry
      end

      def validate_labels!(entry, labels)
        labels = labels.to_h.transform_keys(&:to_sym)
        expected = entry.optional.keys.map(&:to_sym)
        missing = expected - labels.keys
        extra = labels.keys - expected
        raise ValidationError, "#{entry.name}: labels must be #{expected.inspect}" unless missing.empty? && extra.empty?

        labels.each do |key, value|
          raise ValidationError, "#{key}: correlation identifiers cannot be labels" if IDENTIFIER_LABELS.include?(key)
          string = String(value)
          raise ValidationError, "#{key}: value is not low cardinality" unless string.match?(LOW_CARDINALITY_RE)
        end
      end

      def labels(signal, keys)
        keys.to_h { |key| [key, signal.attributes.fetch(key, signal.attributes.fetch(key.to_s, 'unknown'))] }
      end

      def series_key(name, labels)
        labels = labels.to_h.transform_keys(&:to_s).sort.to_h
        [name.to_s, labels]
      end

      def register_series!(key, name)
        return if @counters.key?(key) || @gauges.key?(key) || @histograms.key?(key)
        return if @counters.length + @gauges.length + @histograms.length < @max_series

        raise ValidationError, "#{name}: metric series limit reached"
      end

      def positive_integer(value, name)
        return value if value.is_a?(Integer) && value.positive?

        raise ValidationError, "#{name} must be positive"
      end

      def serialize_series(series)
        series.map do |(name, labels), value|
          {'name' => name, 'labels' => labels, 'value' => value}
        end
      end

      def render_series(key, value, suffix: '')
        name, labels = key
        label_text = labels.map { |label, label_value| "#{label}=\"#{escape(label_value)}\"" }.join(',')
        "#{prometheus_name(name)}#{suffix}#{label_text.empty? ? '' : "{#{label_text}}"} #{value}"
      end

      def prometheus_name(name)
        name.tr('.', '_')
      end

      def escape(value)
        String(value).gsub(/["\\\n]/) { |character| {'"' => '\\"', '\\' => '\\\\', "\n" => '\\n'}.fetch(character) }
      end

      def percentile(values, rank)
        return nil if values.empty?

        values.sort[(values.length * rank).ceil - 1]
      end
    end
  end
end
