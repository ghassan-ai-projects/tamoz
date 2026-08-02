# frozen_string_literal: true

module Tamoz
  module Agent
    class Error < Tamoz::Error; end
    class ProtocolError < Error; end
    class PlanRejectedError < Error; end
    class ApprovalDeniedError < Error; end
    class ToolError < Error; end

    # P9: a resumed session cannot bind the exact skill trees it was planned
    # against. This is a stop, not a recoverable tool result: continuing would run
    # an accepted plan under instructions that have since changed (invariant 41).
    class SkillSnapshotUnavailableError < Error; end
  end
end
