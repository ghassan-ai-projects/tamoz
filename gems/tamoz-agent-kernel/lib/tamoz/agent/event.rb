# frozen_string_literal: true

module Tamoz
  module Agent
    # Two-field telemetry value emitted along the session's lifecycle-event
    # stream. Defined here (not in runtime.rb) so the durable-memory recall
    # trace constructs it without a runtime dependency; the kernel owns it from
    # the P1 extraction on.
    Event = Data.define(:type, :data)
  end
end
