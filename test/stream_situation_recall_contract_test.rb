# frozen_string_literal: true

require_relative "test_helper"

class StreamSituationRecallContractTest < Minitest::Test
  DIGEST = "sha256:#{"a" * 64}"

  def test_result_freezes_safe_projection_and_preserves_ordered_digests
    projection = Tamoz::Stream::SituationRecall::Projection.new(
      statement: "pressure increased",
      scopes: {
        tenant: "acme", situation_type: "machine", entity_type: "pump", entity_id: "pump-2"
      },
      provenance: {
        episode_id: "episode-1", decision_id: "decision-1", command_id: "command-1", outcome_id: "outcome-1"
      },
      digest: DIGEST
    )
    result = Tamoz::Stream::SituationRecall::Result.new(
      records: [projection], record_digests: [DIGEST]
    )

    assert result.records.frozen?
    assert result.projections.frozen?
    assert_equal [DIGEST], result.record_digests
  end

  def test_result_rejects_digest_order_that_does_not_match_projections
    projection = Tamoz::Stream::SituationRecall::Projection.new(
      statement: "pressure increased",
      scopes: {tenant: "acme", situation_type: "machine", entity_type: "pump", entity_id: "pump-2"},
      provenance: {episode_id: "e", decision_id: "d", command_id: "c", outcome_id: "o"},
      digest: DIGEST
    )

    assert_raises(ArgumentError) do
      Tamoz::Stream::SituationRecall::Result.new(
        records: [projection], record_digests: ["sha256:#{"b" * 64}"]
      )
    end
  end
end
