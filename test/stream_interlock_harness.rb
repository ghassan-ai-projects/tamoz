# frozen_string_literal: true

# P14-P/C6 — the MUTABLE interlock harness. Lives in the TEST tree ONLY; a
# dependency-direction test proves production tamoz-stream cannot reference it
# or any write API. The harness can trip/arm the interlock to exercise the
# production read-only reader's fail-closed behavior.
class MutableInterlockHarness
  include Tamoz::Stream::InterlockReader

  def initialize(initial: true)
    @states = Hash.new(initial)
  end

  def ready?(interlock_id)
    @states[interlock_id]
  end

  def state(interlock_id)
    @states[interlock_id] ? :ready : :tripped
  end

  # MUTABLE — the write API production code must never see.
  def trip!(interlock_id)
    @states[interlock_id] = false
  end

  def arm!(interlock_id)
    @states[interlock_id] = true
  end
end
