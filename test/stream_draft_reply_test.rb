# frozen_string_literal: true

require_relative 'test_helper'
require 'tamoz/stream/draft_reply'

class StreamDraftReplyTest < Minitest::Test
  V1 = Agenticstream::Runtime::V1
  KEY = V1::DraftKey.new(diagnosis_code: 'code_a', kind_digest: 'sha256:k', intent: 'act', preset: 'p1')
  USAGE = V1::Usage.new(input_tokens: 10, output_tokens: 2)

  def test_a_proposal_answers_the_requests_key_with_the_parsed_condition
    event = Tamoz::Stream::DraftReply.event(
      { 'proposal' => { 'when' => 'features.a > 1', 'cited_episode_ids' => %w[ep-1 ep-2], 'rationale' => 'r' } },
      key: KEY, usage: USAGE
    )

    assert_equal V1::PlaybookProposal.new(diagnosis_code: 'code_a', intent: 'act', preset: 'p1',
                                          when: 'features.a > 1', cited_episode_ids: %w[ep-1 ep-2],
                                          rationale: 'r'), event.proposal
    assert_equal USAGE, event.usage
  end

  def test_a_declined_draft_carries_its_reason
    event = Tamoz::Stream::DraftReply.event({ 'no_proposal' => { 'reason' => 'too_few_cases' } }, key: KEY,
                                                                                                  usage: USAGE)

    assert_equal :no_proposal, event.event
    assert_equal 'too_few_cases', event.no_proposal.reason
  end
end
