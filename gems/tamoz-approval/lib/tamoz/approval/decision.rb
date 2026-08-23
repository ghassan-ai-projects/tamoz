# frozen_string_literal: true

module Tamoz
  module Approval
    Decision = Data.define(
      :id,
      :verdict,
      :reason,
      :rule_id,
      :tier,
      :grant_offer,
      :required_evidence,
      :policy_rev
    )

    GrantOffer = Data.define(:scopes, :key)
  end
end
