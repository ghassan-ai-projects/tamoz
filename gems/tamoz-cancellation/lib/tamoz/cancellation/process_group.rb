# frozen_string_literal: true

module Tamoz
  module Cancellation
    # Process-group primitives shared by the MCP supervisor and the check
    # runner: group liveness and group signalling. Per-caller policies (the
    # supervisor's EPERM-as-alive polling cadence, the check runner's
    # denied-group-kill fallback) stay at the call sites.
    class ProcessGroup
      class << self
        def alive?(pid)
          Process.kill(0, -pid)
          true
        rescue Errno::ESRCH, Errno::ECHILD
          false
        rescue Errno::EPERM
          true
        end

        # True when delivered, false when the group was already gone. A denied
        # kill propagates so the call site can apply its own policy.
        def signal(pid, name)
          Process.kill(name, -pid)
          true
        rescue Errno::ESRCH, Errno::ECHILD
          false
        end
      end
    end
  end
end
