# frozen_string_literal: true

module Tamoz
  module Agent
    class CLI
      # The person at the terminal during one durable command: where output goes,
      # how they are asked and where their approvals are recorded, and the stop
      # (Ctrl-C) they can send.
      Operator = Data.define(:out, :err, :events, :prompts, :approvals, :cancellation)
    end
  end
end
