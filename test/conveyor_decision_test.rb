# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/domain_episode_fixture'
require 'tamoz/agent'
require 'tamoz/sqlite'
require 'support/local_model_endpoint'
require 'support/conveyor_domain'
require 'support/episode_composition'

# Plumbing only: each conveyor spec step runs the real episode graph with a fixture document. Nothing calls a model.
class ConveyorDecisionTest < Minitest::Test
  include DomainEpisodeFixture

  Domain = ConveyorDomain
  ALLOWED = Domain::INTENT_TYPES.keys.freeze
  STEPS = [
    { phase: 'degrading', code: 'drive_degrading', type: 'reduce_feed', risk: 'R1', parameters: { 'level' => 'limp' } },
    { phase: 'shedding', code: 'drive_degrading', type: 'stop_feed', risk: 'R2', parameters: { 'level' => 'empty' } },
    { phase: 'cause_bearing', code: 'bearing', type: 'isolate_drive', risk: 'R2',
      parameters: { 'mode' => 'planned_stop' } },
    { phase: 'cause_gearbox', code: 'gearbox_seizing', type: 'stop_belt', risk: 'R2',
      parameters: { 'mode' => 'planned_stop' } },
    { phase: 'overload', code: 'drive_tripped', type: 'reduce_feed', risk: 'R1', parameters: { 'level' => 'limp' } }
  ].freeze

  def setup
    @dir = Dir.mktmpdir('tamoz-conveyor')
    @endpoints = []
    @compositions = []
  end

  def teardown
    @compositions.each { |c| c.fetch(:adapter).close }
    @endpoints.each(&:stop)
    FileUtils.remove_entry(@dir) if @dir
  end

  def test_each_spec_step_is_decided_with_its_diagnosis_at_the_catalog_risk
    observed = STEPS.map { |step| observed_step(step) }

    assert_equal STEPS.map { |step| expected_step(step) }, observed, 'decision per phase'
  end

  def test_a_step_with_an_unknown_cause_is_refused_where_drive_degrading_carries_it
    terminal, = run_step(STEPS.first, code: 'unknown')

    assert_equal :TERMINAL_STATUS_FAILED, terminal.status
  end

  def test_a_diagnosis_with_no_step_falls_back_to_the_watch
    terminal, decision = run_episode(
      episode_id: 'conveyor-shared-rise',
      document: Domain.document(selected: 'transient_none', hypothesis: 'every drive rose with a feed surge'),
      snapshot: Domain.snapshot.merge('phase' => 'watch'), allowed: ALLOWED, risk_ceiling: :RISK_CLASS_R2
    )

    assert_equal :TERMINAL_STATUS_PRODUCED, terminal.status
    assert_equal 'transient_none', decision.fetch('diagnosis_code')
    assert_equal(['install_watch_condition'], decision.fetch('intents').map { |intent| intent.fetch('type') })
  end

  def test_every_code_but_unknown_and_the_shared_rise_is_a_step_diagnosis
    codes = Domain::CATALOG.map { |entry| entry.fetch('code') }

    assert_equal (codes - %w[unknown transient_none]).sort, STEPS.map { |step| step.fetch(:code) }.uniq.sort
    refute_includes codes, 'vfd_trip'
  end

  private

  def expected_step(step)
    [step.fetch(:phase), :TERMINAL_STATUS_PRODUCED, *step.values_at(:code, :type, :risk, :parameters)]
  end

  def observed_step(step)
    terminal, decision = run_step(step, code: step.fetch(:code))
    [step.fetch(:phase), terminal.status, *observed_decision(decision, step)]
  end

  def observed_decision(decision, step)
    return [] unless decision

    intent = decision.fetch('intents').fetch(0)
    [decision.fetch('diagnosis_code'), *intent.values_at('type', 'risk_class'),
     intent.fetch('parameters').slice(*step.fetch(:parameters).keys)]
  end

  def run_step(step, code:)
    intent = { type: step.fetch(:type), **step.fetch(:parameters).transform_keys(&:to_sym) }
    run_episode(
      episode_id: "conveyor-#{step.fetch(:phase)}-#{code}",
      document: Domain.document(selected: code, hypothesis: "#{code} in phase #{step.fetch(:phase)}", intent:),
      snapshot: Domain.snapshot.merge('phase' => step.fetch(:phase)), allowed: ALLOWED, risk_ceiling: :RISK_CLASS_R2
    )
  end
end
