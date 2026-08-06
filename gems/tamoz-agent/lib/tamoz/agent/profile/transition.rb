# frozen_string_literal: true

module Tamoz
  module Agent
    class Profile
      # One operator-recorded candidate profile transition for a thread (§5.4).
      # A candidate is not authority: it only permits the *next turn boundary*
      # of that exact thread to move from `from_digest` to `to_digest`. DR-5 D2:
      # an entry is optionally marked consumed (`consumed_by` request id +
      # `consumed_at`) inside the registry's single flocked critical section; a
      # consumed entry is an audit record and never re-applies.
      #
      # :reek:NilCheck — nil is the domain value here, not an accident: the two
      # consumed fields are absent until the entry is burned, and `consumed?` is
      # the question the whole audit contract turns on.
      Transition = Data.define(
        :thread_id, :profile_id, :from_digest, :to_digest, :reason, :consumed_by, :consumed_at
      ) do
        def initialize(**members)
          members = { consumed_by: nil, consumed_at: nil }.merge(members)
          normalized = members.transform_values do |value|
            value.nil? ? nil : String(value).dup.freeze
          end
          super(**normalized)
        end

        def consumed? = !consumed_by.nil?

        def to_h_document
          document = {
            'profile_id' => profile_id,
            'from_digest' => from_digest,
            'to_digest' => to_digest,
            'reason' => reason
          }
          if consumed?
            document['consumed_by'] = consumed_by
            document['consumed_at'] = consumed_at
          end
          document
        end
      end
    end
  end
end
