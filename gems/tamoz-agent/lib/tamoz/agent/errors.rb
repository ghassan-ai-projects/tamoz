# frozen_string_literal: true

module Tamoz
  module Agent
    class Error < Tamoz::Error; end
    class ProtocolError < Error; end
    class PlanRejectedError < Error; end
    class ApprovalDeniedError < Error; end
    class ToolError < Error; end
  end
end
