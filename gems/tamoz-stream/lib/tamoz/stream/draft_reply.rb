# frozen_string_literal: true

require 'tamoz/stream/gen'

Tamoz::Stream::Gen.load!

module Tamoz
  module Stream
    # The terminal DraftEvent for a parsed draft, answering the request's key.
    module DraftReply
      V1 = Agenticstream::Runtime::V1

      module_function

      def event(answer, key:, usage:)
        if answer.key?('proposal')
          V1::DraftEvent.new(proposal: proposal(answer.fetch('proposal'), key), usage:)
        else
          V1::DraftEvent.new(no_proposal: V1::NoProposal.new(reason: answer.fetch('no_proposal').fetch('reason')),
                             usage:)
        end
      end

      def proposal(draft, key)
        V1::PlaybookProposal.new(
          diagnosis_code: key.diagnosis_code, intent: key.intent, preset: key.preset,
          when: draft.fetch('when'), cited_episode_ids: draft.fetch('cited_episode_ids'),
          rationale: draft.fetch('rationale')
        )
      end
    end
  end
end
