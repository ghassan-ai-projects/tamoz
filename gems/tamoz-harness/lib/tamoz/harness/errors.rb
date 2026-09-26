# frozen_string_literal: true

module Tamoz
  module Harness
    # Base error for the harness protocol.
    class Error < Tamoz::Error; end

    # An update_plan call the harness refuses; the message goes back to the model.
    class PlanError < Error; end

    # A report_findings call the harness refuses; the message goes back to the model.
    class ReportError < Error; end
  end
end
