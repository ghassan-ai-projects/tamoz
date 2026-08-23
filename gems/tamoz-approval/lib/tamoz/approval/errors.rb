# frozen_string_literal: true

require 'tamoz/core'

module Tamoz
  module Approval
    class Error < Tamoz::Error; end

    class InvalidPolicyError < Error; end
    class ConflictingResolutionError < Error; end
    class UnknownDecisionError < Error; end
    class InvalidScopeError < Error; end
  end
end
