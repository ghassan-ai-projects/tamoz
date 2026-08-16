# frozen_string_literal: true

module Tamoz
  module Evals
    module Benchmark
      # P7: the paired comparison + cluster bootstrap scaffold. The go rule
      # needs a 95% paired interval that beats the strongest non-LLM baseline
      # by the frozen minimum practical effect; this module computes exactly
      # that number from the frozen cells.
      #
      # The bootstrap is a true CLUSTER bootstrap: each resample draws
      # clusters (scenario families) WITH replacement and keeps ALL cells of
      # each sampled cluster, so within-family correlation is preserved and
      # the resampled statistic is the same mean over cells the point
      # estimate is. Seeded — the same cells re-bootstrapped yield the same
      # interval.
      class Comparison
        # Computes the paired comparison of `candidate` vs `baseline` on the
        # per-cell metric. Returns the mean difference, its cluster-bootstrap
        # 95% interval, and whether the frozen minimum practical effect is met.
        # The seed is the protocol statistics' bootstrap_seed — never a default.
        def paired(candidate:, baseline:, cells:, metric:, minimum_effect:, seed:,
                   resamples: 2000, confidence: 0.95)
          clusters = cluster_ids(cells)
          differences = per_cell_differences(candidate, baseline, metric)
          resampled = (1..resamples).map do |resample|
            random = Random.new(seed + resample)
            # True cluster bootstrap: draw clusters WITH replacement and keep
            # ALL cells of each sampled cluster (within-family correlation is
            # preserved, and the resampled statistic is the same mean-over-cells
            # the point estimate is).
            sample_cells = clusters.length.times.map do
              cluster = clusters.sample(random: random)
              cluster.fetch("cells")
            end.flatten
            sample_differences = per_cell_differences(
              candidate.select { |cell| sample_cells.include?(cell.fetch("cell_id")) },
              baseline.select { |cell| sample_cells.include?(cell.fetch("cell_id")) },
              metric
            )
            mean(sample_differences)
          end.sort
          low_index = ((1 - confidence) / 2 * resamples).floor
          high_index = ((1 + confidence) / 2 * resamples).floor
          low = resampled[low_index]
          high = resampled[high_index]
          {
            "mean_difference" => mean(differences),
            "ci_low" => low,
            "ci_high" => high,
            "confidence" => confidence,
            "minimum_practical_effect" => minimum_effect,
            "meets_minimum_effect" => low > minimum_effect,
            "resamples" => resamples,
            "clusters" => clusters.length
          }
        end

        private

        def per_cell_differences(candidate, baseline, metric)
          candidate.map do |candidate_cell|
            baseline_cell = baseline.find { |cell| cell.fetch("cell_id") == candidate_cell.fetch("cell_id") }
            next 0.0 unless baseline_cell

            metric.call(candidate_cell) - metric.call(baseline_cell)
          end
        end

        def cluster_ids(cells)
          cells.group_by { |cell| cell.fetch("scenario_family", "default") }
               .map { |_family, members| {"cells" => members.map { |cell| cell.fetch("cell_id") }} }
        end

        def mean(values)
          values.empty? ? 0.0 : values.sum / values.length.to_f
        end
      end
    end
  end
end
