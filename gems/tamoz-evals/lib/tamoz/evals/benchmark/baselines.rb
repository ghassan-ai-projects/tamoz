# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # P7: the preregistered non-LLM baselines from the frozen protocol. Each
      # is a pure predictor over the cell's situation facts — deterministic,
      # seed-pinned where randomness is involved — so a benchmark comparison
      # against them is reproducible offline. The strongest non-LLM baseline
      # is the go rule's opponent; the Go native executor is a separate
      # architecture comparator invoked outside this module (batch.go).
      module Baselines
        module_function

        # Predicts the corpus majority code for every cell.
        def majority_prior(cells, codes)
          majority = majority_for(cells, codes)
          cells.map { |cell| cell.merge("primary_code" => majority, "probabilities" => one_hot_probabilities(majority, codes)) }
        end

        # Uniform random labels, seeded per cell so a re-run is identical.
        def random_label(cells, codes, seed: 1)
          cells.each_with_index.map do |cell, index|
            random = Random.new(seed + index)
            code = codes.sample(random: random)
            cell.merge("primary_code" => code, "probabilities" => one_hot_probabilities(code, codes))
          end
        end

        # Fixed-threshold detector: alarms when the primary metric crosses a
        # frozen threshold, else the majority code.
        def fixed_threshold(cells, codes, metric: "dissolved_oxygen", threshold: 2.0,
                            alarm_code: "low_dissolved_oxygen")
          cells.map do |cell|
            value = metric_value(cell, metric)
            code = value < threshold ? alarm_code : majority_for(cells, codes)
            cell.merge("primary_code" => code, "probabilities" => one_hot_probabilities(code, codes))
          end
        end

        # z-score detector: alarms when the primary metric is more than k
        # standard deviations below the corpus mean.
        def z_score(cells, codes, metric: "dissolved_oxygen", k: 2.0,
                    alarm_code: "low_dissolved_oxygen")
          values = cells.map { |cell| metric_value(cell, metric) }
          mean_value = values.sum / values.length.to_f
          stddev = Math.sqrt(values.sum { |value| (value - mean_value)**2 } / values.length.to_f)
          cells.map do |cell|
            value = metric_value(cell, metric)
            code = (mean_value - value) > k * stddev ? alarm_code : majority_for(cells, codes)
            cell.merge("primary_code" => code, "probabilities" => one_hot_probabilities(code, codes))
          end
        end

        # First-difference detector: alarms when the metric fell by more than
        # the frozen drop between observations.
        def first_difference(cells, codes, metric: "dissolved_oxygen", drop: 1.0,
                             alarm_code: "low_dissolved_oxygen")
          cells.map do |cell|
            series = metric_series(cell, metric)
            dropped = series.each_cons(2).any? { |before, after| before - after > drop }
            code = dropped ? alarm_code : majority_for(cells, codes)
            cell.merge("primary_code" => code, "probabilities" => one_hot_probabilities(code, codes))
          end
        end

        # Moving-median detector: alarms when the metric is below the rolling
        # median by more than k times the median absolute deviation.
        def moving_median(cells, codes, metric: "dissolved_oxygen", window: 5, k: 2.0,
                          alarm_code: "low_dissolved_oxygen")
          cells.map do |cell|
            series = metric_series(cell, metric)
            window_values = series.last(window)
            median = window_values.sort[window_values.length / 2]
            deviations = window_values.map { |value| (value - median).abs }
            mad = deviations.sort[deviations.length / 2]
            value = metric_value(cell, metric)
            code = (median - value) > k * (mad.zero? ? 0.1 : mad) ? alarm_code : majority_for(cells, codes)
            cell.merge("primary_code" => code, "probabilities" => one_hot_probabilities(code, codes))
          end
        end

        # Nearest-symptom classifier: predicts the truth code of the training
        # cell whose metric vector is nearest (euclidean) to this cell's.
        def nearest_symptom(cells, codes, metric: "dissolved_oxygen")
          values = cells.map { |cell| metric_value(cell, metric) }
          cells.each_with_index.map do |cell, index|
            value = metric_value(cell, metric)
            nearest = (0...cells.length).reject { |candidate| candidate == index }
                                        .min_by { |candidate| (values[candidate] - value).abs }
            code = nearest.nil? ? majority_for(cells, codes) : cells.fetch(nearest).fetch("truth_code")
            cell.merge("primary_code" => code, "probabilities" => one_hot_probabilities(code, codes))
          end
        end

        # The strongest simple deterministic detector the corpus supports:
        # the z-score detector (it thresholds adaptively instead of on a fixed
        # absolute level, so it survives domain shifts).
        def deterministic_detector(cells, codes, **kwargs)
          z_score(cells, codes, **kwargs)
        end

        def metric_value(cell, metric)
          facts = cell.fetch("facts", {})
          value = facts.fetch(metric, nil)
          return value.to_f if value

          series = facts.fetch("#{metric}_series", nil)
          series.is_a?(Array) && !series.empty? ? series.last.to_f : 0.0
        end

        def metric_series(cell, metric)
          facts = cell.fetch("facts", {})
          series = facts.fetch("#{metric}_series", nil)
          return Array(series).map(&:to_f) if series.is_a?(Array) && !series.empty?

          [metric_value(cell, metric)]
        end

        def majority_for(cells, codes)
          counts = codes.to_h { |code| [code, cells.count { |cell| cell.fetch("truth_code") == code }] }
          counts.max_by { |_code, count| count }.first
        end

        def one_hot_probabilities(code, codes)
          Metrics.one_hot(code, codes)
        end
      end
    end
  end
end
