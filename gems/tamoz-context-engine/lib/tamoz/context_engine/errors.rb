# frozen_string_literal: true

module Tamoz
  module ContextEngine
    # Base error for the context engine.
    class Error < Tamoz::Error; end

    # A compaction summary failed validation and must not replace history.
    class InvalidSummaryError < Error; end
  end
end
