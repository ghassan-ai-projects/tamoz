# frozen_string_literal: true

require 'tamoz/core'

module Tamoz
  module Approval
    # The taxonomy callers rescue for POLICY outcomes. Programmer-contract
    # violations (a malformed answer, an evidence symbol outside the injected
    # set) raise ArgumentError deliberately: they are bugs in the caller, not
    # answers to the question "does this need approval".
    class Error < Tamoz::Error; end

    class InvalidPolicyError < Error; end
    class ConflictingResolutionError < Error; end
    class UnknownDecisionError < Error; end
    class InvalidScopeError < Error; end
  end
end
