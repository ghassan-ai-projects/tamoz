# frozen_string_literal: true

require "json"

module Tamoz
  module Evals
    module Benchmark
      # P7: the holdout truth-leak scan. The model-visible bytes of a holdout
      # case must not contain the truth: a forbidden-token scan over the
      # visible document catches a generator that embedded the answer, and the
      # opaque-id binding catches a manifest/truth swap. Pure and
      # deterministic — the same cases scan identically anywhere.
      class LeakScan
        FORBIDDEN_TOKENS = %w[answer truth label gold expected groundtruth oracle correct].freeze

        def initialize(cases)
          @cases = cases
        end

        def call
          violations = []
          @cases.each do |entry|
            visible = JSON.generate(entry.fetch("model_visible", entry)).downcase
            matches = visible.scan(/\b(#{FORBIDDEN_TOKENS.join("|")})\b/).flatten.uniq
            next if matches.empty?

            id = entry.dig("model_visible", "id") || entry["id"]
            violations << "forbidden_token:#{matches.join(",")}:#{id}"
          end
          {"violations" => violations, "scanned_cases" => @cases.length}
        end
      end
    end
  end
end
