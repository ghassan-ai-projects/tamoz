# frozen_string_literal: true

require_relative 'authority_evidence'

module Tamoz
  module Comms
    # ADR-049 INV-C/INV-D: the trusted policy that maps a pinned effect to the
    # evidence an approver must present. The v1 body returns the
    # `filesystem_operator` constant unconditionally — every effect is
    # operator-gated, so Telegram is deny-only in practice. The signature still
    # takes the effect facts so a future per-effect ADR (ADR-049 §4) changes
    # only the body, and a model-supplied descriptor is provably ignored
    # (INV-C locks the input away).
    class ApprovalPolicy
      def self.required_evidence(_effect)
        AuthorityEvidence.filesystem_operator
      end
    end
  end
end
