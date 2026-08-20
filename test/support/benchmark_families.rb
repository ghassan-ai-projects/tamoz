# frozen_string_literal: true

require "tamoz/core"
require_relative "domain_loader"
require_relative "aquaculture_domain"
require_relative "climate_domain"

# P7: the benchmark's scenario families, driven by the DOMAIN DATA in
# test/fixtures/domains/*.json (domain-knowledge extraction —
# docs/new-design/impl/DOMAIN_DATA_EXTRACTION.md). The truth and gold rules
# are the preregistered facts→label mapping derived from each family's JSON
# config — the SAME rule derives pilot truth and holdout truth, so the
# holdout is learnable by exactly the mechanism the pilot calibrates (never a
# coin flip). ZERO domain knowledge in Ruby code here: this module is the
# data-driven driver only (the only knowledge it holds is which fixture a
# family id names).
module BenchmarkFamilies
  module_function

  def family_for(domain, data)
    # The domain key is the DomainLoader instance itself (its prompt/catalog/
    # fixture_responses methods drive script/benchmark_run). Passing the loader
    # instead of a per-domain Ruby constant keeps this driver fully data-driven,
    # so a new domain JSON — including a hyphenated id like `cold-chain` — is
    # picked up without a matching Ruby module.
    metric = data.fetch("metric")
    {
      "domain" => domain,
      "metric" => metric,
      "alarm_code" => data.fetch("alarm_code"),
      "series" => data.fetch("series"),
      # The facts generator reproduces the exact single-random-rand structure
      # of the preregistered rules (series offsets applied as v + offset,
      # UNROUNDED), so holdout output stays seed-deterministic.
      "facts" => lambda do |index, random|
        value = (data.dig("metric_range", "min") + random.rand * data.dig("metric_range", "width"))
                .round(data.dig("metric_range", "round"))
        facts = data.fetch("base_facts").dup
        facts["#{data.fetch("id_prefix")}_id"] = "#{data.fetch("id_prefix")}-#{index}"
        facts[metric] = value
        facts[data.fetch("series")] = data.fetch("series_offsets").map { |offset| value + offset }
        facts
      end,
      "truth" => threshold_rule(metric, data.fetch("truth")),
      "gold" => gold_rule(metric, data.fetch("gold"))
    }
  end

  def threshold_rule(metric, rule)
    operator = rule.fetch("operator").to_sym
    unless %i[lt gt].include?(operator)
      raise ArgumentError, "unknown truth operator #{operator.inspect} for #{metric}"
    end
    lambda do |facts|
      hit = operator == :lt ? facts.fetch(metric) < rule.fetch("threshold") :
                               facts.fetch(metric) > rule.fetch("threshold")
      hit ? rule.fetch("code") : rule.fetch("fallback")
    end
  end

  def gold_rule(metric, rule)
    operator = rule.fetch("operator").to_sym
    unless %i[lt gt].include?(operator)
      raise ArgumentError, "unknown gold operator #{operator.inspect} for #{metric}"
    end
    lambda do |facts|
      hit = operator == :lt ? facts.fetch(metric) < rule.fetch("threshold") :
                               facts.fetch(metric) > rule.fetch("threshold")
      hit ? rule.fetch("risk_class") : nil
    end
  end

  # Built after the helpers so the module_function methods are defined.
  FAMILIES = DomainLoader.domains.to_h do |domain_name|
    domain = DomainLoader.load(domain_name)
    data = domain.benchmark_family
    [data.fetch("family_id"), family_for(domain, data)]
  end.freeze
end
