# frozen_string_literal: true

require_relative "test_helper"

class AgentSessionRecordsTest < Minitest::Test
  Records = Tamoz::Agent::SessionRecords

  def test_every_built_record_carries_its_kind_and_format_version
    record = Records.build(
      "plan",
      plan_id: "action.0.1",
      phase: "action",
      attempt: 1,
      plan: {"goal" => "g", "done_when" => ["d"], "steps" => []},
      plan_digest: "a" * 64
    )

    assert_equal "plan", record.fetch("record")
    assert_equal 1, record.fetch("record_version")
    assert record.frozen?
  end

  def test_unknown_record_kind_is_rejected
    assert_raises(Tamoz::Agent::ProtocolError) { Records.build("not_a_kind") }
    assert_raises(Tamoz::CheckpointCorruptionError) do
      Records.load!({"record" => "not_a_kind", "record_version" => 1})
    end
  end

  def test_unknown_field_is_rejected_at_build_and_at_load
    assert_raises(Tamoz::Agent::ProtocolError) do
      Records.build("terminal", reason: "done", satisfied: true, surprise: 1)
    end
    assert_raises(Tamoz::CheckpointCorruptionError) do
      Records.load!(
        {
          "record" => "terminal",
          "record_version" => 1,
          "reason" => "done",
          "satisfied" => true,
          "surprise" => 1
        }
      )
    end
  end

  # Invariant 18: a newer unsupported version fails BEFORE partial load. The record
  # below is unsupported *and* structurally invalid (unknown key, missing key, wrong
  # type). Only the version error may surface, which proves no field was inspected.
  def test_newer_version_fails_before_any_field_is_read
    error = assert_raises(Tamoz::CheckpointVersionError) do
      Records.load!(
        {
          "record" => "terminal",
          "record_version" => 2,
          "reason" => 12_345,
          "unknown_future_field" => {"nested" => true}
        }
      )
    end

    assert_match(/version 2 exceeds supported version 1/, error.message)
  end

  # At RECORD_VERSION 1 there is no older shipped version, so the migration branch is
  # unreachable by construction. This test pins that fact rather than pretending to
  # exercise a migration that does not exist; when RECORD_VERSION rises, it must be
  # replaced by real fixture round-trips for every supported prior version.
  def test_no_older_version_exists_to_migrate_from_at_version_one
    assert_equal 1, Records::RECORD_VERSION
    assert_empty Records::MIGRATIONS
    assert_raises(Tamoz::CheckpointCorruptionError) do
      Records.load!({"record" => "terminal", "record_version" => 0})
    end
  end

  def test_version_zero_is_not_a_usable_version
    assert_raises(Tamoz::CheckpointCorruptionError) do
      Records.load!({"record" => "terminal", "record_version" => 0})
    end
  end

  def test_migration_registry_is_empty_at_the_first_shipped_version
    assert_empty Records::MIGRATIONS
    assert_equal 1, Records::RECORD_VERSION
  end

  def test_missing_required_field_is_rejected
    error = assert_raises(Tamoz::CheckpointCorruptionError) do
      Records.load!({"record" => "terminal", "record_version" => 1, "reason" => "done"})
    end

    assert_match(/missing "satisfied"/, error.message)
  end

  def test_wrong_field_type_is_rejected
    assert_raises(Tamoz::CheckpointCorruptionError) do
      Records.load!(
        {
          "record" => "terminal",
          "record_version" => 1,
          "reason" => "done",
          "satisfied" => "yes"
        }
      )
    end
  end

  def test_sensitive_values_are_rejected_at_every_depth
    %w[top nested array].each do |shape|
      value =
        case shape
        when "top" then Tamoz::Secret.new("k")
        when "nested" then {"a" => {"b" => Tamoz::Secret.new("k")}}
        else {"a" => [1, [Tamoz::Secret.new("k")]]}
        end

      assert_raises(Tamoz::SensitiveValueError, shape) { Records.reject_sensitive!(value) }
    end
  end

  def test_load_state_names_the_offending_channel
    error = assert_raises(Tamoz::CheckpointVersionError) do
      Records.load_state!(
        {plan_versions: [{"record" => "plan", "record_version" => 9}]}
      )
    end

    assert_match(/session channel :plan_versions/, error.message)
  end

  def test_digest_is_stable_and_order_independent
    left = Records.digest({"b" => 1, "a" => [1, 2]})
    right = Records.digest({"a" => [1, 2], "b" => 1})

    assert_equal left, right
    refute_equal left, Records.digest({"a" => [2, 1], "b" => 1})
  end

  def test_load_state_ignores_plain_channels
    state = {step_cursor: 3, task: "hello", observations: []}

    assert_equal state, Records.load_state!(state)
  end
end
