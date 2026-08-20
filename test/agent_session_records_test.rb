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
    assert_equal 2, record.fetch("record_version")
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
          "record_version" => 2,
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
          "record_version" => 3,
          "reason" => 12_345,
          "unknown_future_field" => {"nested" => true}
        }
      )
    end

    assert_match(/version 3 exceeds supported version 2/, error.message)
  end

  # Version 2 is intentionally incompatible with version 1 session records: the
  # current effect receipt contract requires identities that old checkpoints lack.
  def test_no_compatibility_migration_exists_for_version_one
    assert_equal 2, Records::RECORD_VERSION
    assert_empty Records::MIGRATIONS
    assert_raises(Tamoz::CheckpointVersionError) do
      Records.load!({"record" => "terminal", "record_version" => 1})
    end
  end

  def test_version_zero_is_not_a_usable_version
    assert_raises(Tamoz::CheckpointCorruptionError) do
      Records.load!({"record" => "terminal", "record_version" => 0})
    end
  end

  def test_migration_registry_is_empty_at_the_first_shipped_version
    assert_empty Records::MIGRATIONS
    assert_equal 2, Records::RECORD_VERSION
  end

  def test_missing_required_field_is_rejected
    error = assert_raises(Tamoz::CheckpointCorruptionError) do
      Records.load!({"record" => "terminal", "record_version" => 2, "reason" => "done"})
    end

    assert_match(/missing "satisfied"/, error.message)
  end

  def test_wrong_field_type_is_rejected
    assert_raises(Tamoz::CheckpointCorruptionError) do
      Records.load!(
        {
          "record" => "terminal",
          "record_version" => 2,
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

  def test_version_one_session_record_is_rejected_without_compatibility_migration
    assert_raises(Tamoz::CheckpointVersionError) do
      Records.load!(
      {
        "record" => "session",
        "record_version" => 1,
        "session_id" => "s1",
        "task" => "t",
        "task_digest" => "a" * 64,
        "root" => "/tmp",
        "graph_version" => "1",
        "behavior_version" => "tamoz.agent.session/1",
        "tool_catalog_digest" => "sha256:#{"b" * 64}",
        "created_at_ms" => 0
      }
      )
    end
  end

  def test_session_record_accepts_explicit_profile_identity
    record = Records.build(
      "session",
      session_id: "s1",
      task: "t",
      task_digest: "a" * 64,
      root: "/tmp",
      graph_version: "1",
      behavior_version: "tamoz.agent.session/1",
      tool_catalog_digest: "sha256:#{"b" * 64}",
      created_at_ms: 0,
      profile_id: "work",
      profile_digest: "sha256:#{"c" * 64}"
    )

    assert_equal "work", record.fetch("profile_id")
    assert_equal "sha256:#{"c" * 64}", record.fetch("profile_digest")
  end
end
