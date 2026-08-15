# frozen_string_literal: true

require "tamoz/core"
require "tamoz/agent"
require_relative "aquaculture_domain"
require_relative "climate_domain"

# P7: the benchmark's scenario families, shared by the pilot harness
# (script/benchmark_run) and the holdout generator (script/benchmark_holdout).
# The truth and gold rules are the preregistered facts→label mapping — the
# SAME rule derives pilot truth and holdout truth, so the holdout is learnable
# by exactly the mechanism the pilot calibrates (never a coin flip). The
# metric/alarm pair names the detector baselines' fact key and alarm code per
# family (the protocol freeze carries the same pair), so the "strongest
# non-LLM baseline" actually sees every family's signal.
module BenchmarkFamilies
  FAMILIES = {
    "do-crash" => {
      "domain" => AquacultureDomain,
      "metric" => "dissolved_oxygen",
      "alarm_code" => "low_dissolved_oxygen",
      "series" => "dissolved_oxygen_series",
      # The facts must use the DOMAIN's native vocabulary (the climate fixture
      # cites fact:zone_temperature; the aquaculture fixture cites
      # fact:dissolved_oxygen) or the grounding gate fails every cell.
      "facts" => lambda do |index, random|
        dissolved_oxygen = (0.5 + random.rand * 5.0).round(2)
        {
          "pond_id" => "pond-#{index}",
          "dissolved_oxygen" => dissolved_oxygen,
          "aerator_current" => 0.0,
          "water_temperature" => 26.5,
          "stocking_density" => 42.0,
          "hours_since_last_feeding" => 3.0,
          "surface_wind" => 2.0,
          "dissolved_oxygen_series" => [dissolved_oxygen + 1.0, dissolved_oxygen + 0.4, dissolved_oxygen]
        }
      end,
      "truth" => ->(facts) { facts.fetch("dissolved_oxygen") < 2.0 ? "low_dissolved_oxygen" : "unknown" },
      # R2 gold: the crash is a catastrophe-averting dispatch, so the utility
      # metric's missed-catastrophe path is actually exercised.
      "gold" => ->(facts) { facts.fetch("dissolved_oxygen") < 2.0 ? "R2" : nil }
    },
    "climate-deviation" => {
      "domain" => ClimateDomain,
      "metric" => "zone_temperature",
      "alarm_code" => "overheated",
      "series" => "zone_temperature_series",
      "facts" => lambda do |index, random|
        temperature = (24.0 + random.rand * 10.0).round(2)
        {
          "zone_id" => "zone-#{index}",
          "zone_temperature" => temperature,
          "zone_humidity" => 70.0,
          "zone_co2" => 400.0,
          "vent_open_fraction" => 0.0,
          "fan_current" => 0.0,
          "zone_temperature_series" => [temperature - 1.0, temperature - 0.3, temperature]
        }
      end,
      "truth" => ->(facts) { facts.fetch("zone_temperature") > 31.0 ? "overheated" : "unknown" },
      "gold" => ->(facts) { facts.fetch("zone_temperature") > 31.0 ? "R2" : nil }
    }
  }.freeze
end
