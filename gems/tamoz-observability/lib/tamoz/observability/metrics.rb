# frozen_string_literal: true

require 'json'

module Tamoz
  module Observability
    class Metrics
      LOW_CARDINALITY_RE = /\A[a-zA-Z0-9_.:-]{1,128}\z/
      IDENTIFIER_LABELS = SignalCatalog::CORRELATION_IDENTIFIERS
      DEFAULT_MAX_SERIES = 4_096
      DEFAULT_MAX_HISTOGRAM_SAMPLES = 10_000

      DURATION_METRICS = {
        'tamoz.model.call' => { name: 'tamoz.model.call.duration_ms', label_keys: %w[provider model] },
        'tamoz.tool.call' => { name: 'tamoz.tool.call.duration_ms', label_keys: %w[tool source] }
      }.freeze

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
        record(name, labels:) { |key| @counters[key] += validate_non_negative!(value) }
      rescue StandardError
        count_violation(name)
        :rejected
      end

      def observe(name, value, labels: {})
        record(name, labels:) do |key|
          values = @histograms[key]
          raise ValidationError, "#{name}: histogram sample limit reached" if values.length >= @max_histogram_samples

          values << validate_non_negative!(value)
        end
        value
      rescue StandardError
        count_violation(name)
        :rejected
      end

      def set(name, value, labels: {})
        record(name, labels:) { |key| @gauges[key] = validate_finite!(value) }
      rescue StandardError
        count_violation(name)
        :rejected
      end

      def add_signal(signal)
        return add_document(signal) if signal.is_a?(Hash)
        return :ignored unless signal.is_a?(Signal)

        add_document(document_from_signal(signal))
      rescue StandardError
        @violations[signal.name] += 1
        :rejected
      end

      def add_document(document)
        metric = duration_metric_for(document)
        record_duration(document, metric) if metric
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
          'histograms' => serialize_histograms,
          'violations' => @violations.dup
        }
      end

      def prometheus
        terminate_lines(counter_lines + gauge_lines + histogram_lines)
      end

      def health
        {'violations' => @violations.dup, 'series' => @counters.length + @gauges.length + @histograms.length}
      end

      private

      def record(name, labels:)
        entry = definition(name)
        validate_labels!(entry, labels)
        key = series_key(entry.name, labels)
        register_series!(key, entry.name)
        yield key
      end

      def definition(name)
        entry = @catalog.fetch(name)
        raise ValidationError, "#{name}: not a measurement" unless entry.kind == :measurement

        entry
      end

      def validate_labels!(entry, labels)
        labels = normalize_labels(labels)
        validate_label_set!(entry, labels)
        labels.each { |key, value| validate_label_value!(key, value) }
      end

      def normalize_labels(labels)
        labels.to_h.transform_keys(&:to_sym)
      end

      def validate_label_set!(entry, labels)
        expected = entry.optional.keys.map(&:to_sym)
        missing = expected - labels.keys
        extra = labels.keys - expected
        return if missing.empty? && extra.empty?

        raise ValidationError, "#{entry.name}: labels must be #{expected.inspect}"
      end

      def validate_label_value!(key, value)
        raise ValidationError, "#{key}: correlation identifiers cannot be labels" if IDENTIFIER_LABELS.include?(key)

        string = String(value)
        return if string.match?(LOW_CARDINALITY_RE)

        raise ValidationError, "#{key}: value is not low cardinality"
      end

      def document_from_signal(signal)
        document = signal.to_h
        document['attributes'] = stringified_attributes(signal.attributes)
        document['outcome'] ||= 'unknown'
        document
      end

      def stringified_attributes(attributes)
        attributes.to_h { |key, value| [key.to_s, value] }
      end

      def duration_metric_for(document)
        DURATION_METRICS[document.fetch('name')]
      end

      def record_duration(document, metric)
        duration = document.fetch('attributes', {})['duration_ms']
        return unless duration

        observe(metric[:name], duration, labels: duration_labels(document, metric[:label_keys]))
      end

      def duration_labels(document, label_keys)
        attributes = document.fetch('attributes', {})
        label_keys.to_h do |key|
          [key, attributes.fetch(key, 'unknown')]
        end.merge('outcome' => document.fetch('outcome', 'ok'))
      end

      def validate_non_negative!(value)
        value = Float(value)
        raise ValidationError, 'metric value must be finite and non-negative' unless value.finite? && value >= 0

        value
      end

      def validate_finite!(value)
        value = Float(value)
        raise ValidationError, 'gauge value must be finite' unless value.finite?

        value
      end

      def count_violation(name)
        @violations[name.to_s] += 1
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

      def serialize_histograms
        @histograms.map do |(name, labels), values|
          histogram_summary(values).merge('name' => name, 'labels' => labels)
        end
      end

      def histogram_summary(values)
        {
          'count' => values.length,
          'sum' => values.sum,
          'max' => values.max,
          'p99' => percentile(values, 0.99)
        }
      end

      def counter_lines
        @counters.map { |key, value| render_series(key, value) }
      end

      def gauge_lines
        @gauges.map { |key, value| render_series(key, value) }
      end

      def histogram_lines
        @histograms.flat_map do |key, values|
          [render_series(key, values.length, suffix: '_count'), render_series(key, values.sum, suffix: '_sum')]
        end
      end

      def terminate_lines(lines)
        lines.join("\n") + (lines.empty? ? '' : "\n")
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
