# frozen_string_literal: true

module Tamoz
  module Agent
    class CLI
      Operator = Data.define(:out, :err, :events, :prompts, :approvals, :cancellation)
    end
  end
end
