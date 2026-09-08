# frozen_string_literal: true

require_relative 'test_helper'
require 'support/thermal_lab_domain'

# Real-world sensor WP-T1: sensor-quality and actuator-capability are first-class
# facts the supervisor reasons over (research platform improvements #1 and #4).
# They are DATA in the domain snapshot, carried opaquely by ReceivedSnapshot — no
# new stream machinery. This suite pins the data contract; the BEHAVIOURAL proof
# (degraded quality diverges from the baseline) lives in the decision tournament
# (WP-T2/T3), where the episode path exists.
class ThermalLabFactsTest < Minitest::Test
  QUALITY_ENUM = %w[
    valid missing stale out_of_range warming_up
    calibration_required disconnected suspect conflicting
  ].freeze

  def facts = @facts ||= ThermalLabDomain.snapshot.fetch('facts')

  def test_each_sensor_reading_has_a_paired_quality_fact
    assert_equal 'valid', facts.fetch('box_temp_quality')
    assert_equal 'valid', facts.fetch('ambient_temp_quality')
  end

  def test_degraded_quality_is_overridable_per_trial
    %w[warming_up disconnected stale conflicting].each do |quality|
      snapshot = ThermalLabDomain.snapshot(box_temp_quality: quality)

      assert_equal quality, snapshot.fetch('facts').fetch('box_temp_quality'),
                   "trial fixture for #{quality} must flow into the snapshot"
    end
  end

  def test_an_override_outside_the_enum_is_still_carried_opaquely
    # Quality is data the model reasons over and the scorer checks by behaviour;
    # the snapshot does not schema-gate it (simple over complex). The adversarial
    # suite (WP-T4) relies on a forged value flowing through unchanged.
    snapshot = ThermalLabDomain.snapshot(box_temp_quality: 'not_a_real_state')

    assert_equal 'not_a_real_state', snapshot.fetch('facts').fetch('box_temp_quality')
  end

  def test_the_quality_enum_is_the_documented_vocabulary
    QUALITY_ENUM.each { |state| assert_includes ThermalLabDomain::PROMPT, state }
  end

  def test_capabilities_are_a_declarative_actuator_registry
    fan = facts.fetch('fan_01_capability')

    assert_equal 'request_bounded_cooling', fan.fetch('operation')
    assert_equal 5000, fan.fetch('max_lease_ms'), 'a bounded cooling lease is capped'
    assert_equal({ 'operation' => 'set_indicator' }, facts.fetch('led_01_capability'))
  end

  def test_a_capability_can_be_withdrawn_for_a_trial
    # WP-T4 / research #4: a mode whose capability is not registered is not
    # proposable. The trial withdraws the fan capability by overriding it empty.
    snapshot = ThermalLabDomain.snapshot(fan_01_capability: {})

    assert_empty snapshot.fetch('facts').fetch('fan_01_capability')
  end

  def test_the_prompt_binds_capability_gating
    assert_includes ThermalLabDomain::PROMPT, 'fan_01_capability'
    assert_includes ThermalLabDomain::PROMPT, 'request_evidence'
    assert_includes ThermalLabDomain::PROMPT, 'For set_indicator, the action-specific field is state'
    refute_includes ThermalLabDomain::PROMPT, '\"parameters\": {\"hypothesis\": \"<value>\"}'
  end

  def test_led_intent_uses_the_agentic_selector_field
    entry = ThermalLabDomain::INTENT_CATALOG.find { |candidate| candidate.fetch('type') == 'set_indicator' }
    assert_equal ['state'], entry.fetch('model_writable_fields')
    assert_equal ['state'], entry.fetch('parameter_schema').fetch('required')
    assert_equal %w[off watch alert], entry.fetch('parameter_schema').fetch('properties').fetch('state').fetch('enum')

    document = ThermalLabDomain.document(
      selected: 'already_corrected', hypothesis: 'watch the indicator',
      intent: { type: 'set_indicator', hypothesis: 'alert' }
    )
    assert_equal({ 'state' => 'alert' }, document.fetch('recommended_intents').fetch(0).fetch('parameters'))
  end
end
