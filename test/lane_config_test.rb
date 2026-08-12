# frozen_string_literal: true

require_relative "test_helper"

# T0.5 (PLAN_TAMOZ_STREAM_BUILD §6.3): the declared lane → model-tier map.
# The episode worker selects a lane's model from config — never by inference,
# never via a hidden default.
class LaneConfigTest < Minitest::Test
  def test_declared_map_is_used_verbatim
    config = Tamoz::Agent::LaneConfig.build(
      "fast" => "gemini-2.5-flash", "deep" => "gemini-2.5-pro", "batch" => "gemini-2.5-flash"
    )

    assert_equal "gemini-2.5-flash", config.model_for("fast")
    assert_equal "gemini-2.5-pro", config.model_for("deep")
    assert_equal "gemini-2.5-flash", config.model_for("batch")
    assert_equal %w[fast deep batch], config.lanes
  end

  def test_symbol_keys_are_accepted
    config = Tamoz::Agent::LaneConfig.build(
      fast: "flash", deep: "pro", batch: "flash"
    )
    assert_equal "flash", config.model_for(:fast)
  end

  def test_every_lane_must_be_declared
    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::Agent::LaneConfig.build("fast" => "flash", "deep" => "pro")
    end
  end

  def test_unknown_lanes_are_refused
    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::Agent::LaneConfig.build(
        "fast" => "flash", "deep" => "pro", "batch" => "flash", "ultra" => "x"
      )
    end
  end

  def test_model_identifiers_must_be_non_empty_strings
    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::Agent::LaneConfig.build("fast" => "", "deep" => "pro", "batch" => "flash")
    end
    assert_raises(Tamoz::ConfigurationError) do
      Tamoz::Agent::LaneConfig.build("fast" => nil, "deep" => "pro", "batch" => "flash")
    end
  end

  def test_unknown_lane_lookup_is_refused
    config = Tamoz::Agent::LaneConfig.build(
      "fast" => "flash", "deep" => "pro", "batch" => "flash"
    )
    assert_raises(Tamoz::ConfigurationError) { config.model_for("turbo") }
  end

  def test_the_map_is_frozen
    config = Tamoz::Agent::LaneConfig.build(
      "fast" => "flash", "deep" => "pro", "batch" => "flash"
    )
    assert config.frozen?
    assert_raises(FrozenError) { config.to_h["fast"] = "other" }
  end
end
