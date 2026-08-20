# frozen_string_literal: true

require_relative "test_helper"

# EU-002: the versioned ScheduleStore contract must be the single source of
# truth for every operation and keyword its callers use. Previously the SQLite
# adapter and worker/CLI depended on current_grant/include_provenance and an
# enable_schedule lifecycle method the contract did not declare, so an
# alternate conforming adapter could not be substituted. This pins that the
# SQLite adapter and a minimal conforming fake both match the declared surface.
class SchedulerContractTest < Minitest::Test
  Contract = Tamoz::Scheduler::ScheduleStore

  # A minimal conforming fake: implements exactly the contract, nothing more.
  class FakeScheduleStore
    include Tamoz::Scheduler::ScheduleStore

    def put_schedule(schedule, expected_revision:) = schedule
    def disable_schedule(id, expected_revision:, reason:) = nil
    def enable_schedule(id, expected_revision:) = nil

    def materialize_due(now:, owner:, lease_for:, limit:, request_template:,
                        current_grant:, include_provenance: true)
      []
    end

    def renew_occurrence_lease(id, fence:, lease_for:) = nil
    def complete_occurrence(id, execution_id:, status:, evidence:) = nil
    def list_occurrences(schedule_id:, cursor: nil, limit: 100) = []
  end

  IMPLEMENTATIONS = [Tamoz::SQLite::ScheduleStore, FakeScheduleStore].freeze

  def test_the_contract_version_reflects_the_current_shape
    assert_equal 2, Contract::CONTRACT_VERSION
  end

  def test_the_contract_declares_the_lifecycle_and_policy_surface_its_callers_use
    surface = Contract.instance_methods(false)

    assert_includes surface, :enable_schedule, "enable_schedule must be part of the contract"
    assert_includes surface, :disable_schedule

    materialize = Contract.instance_method(:materialize_due).parameters
    assert_includes materialize, %i[keyreq current_grant],
                    "materialize_due must declare current_grant (invariant 40 policy input)"
    assert_includes materialize, %i[key include_provenance]
  end

  def test_every_declared_operation_matches_the_keyword_shape_on_each_adapter
    IMPLEMENTATIONS.each do |impl|
      Contract.instance_methods(false).each do |name|
        expected = keyword_names(Contract.instance_method(name))
        actual = keyword_names(impl.instance_method(name))
        assert_equal expected, actual,
                     "#{impl} must accept the ScheduleStore contract keywords for #{name}"
      end
    end
  end

  private

  # The set of keyword parameter names (required or optional) a method accepts.
  # Interchangeability is about which keywords a caller may pass, so required vs
  # defaulted is not the axis under test — a missing or extra keyword is.
  def keyword_names(method)
    method.parameters.select { |kind, _| %i[keyreq key].include?(kind) }
          .map { |_, name| name }.sort
  end
end
