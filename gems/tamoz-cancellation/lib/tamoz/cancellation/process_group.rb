# frozen_string_literal: true

module Tamoz
  module Cancellation
    # Process-group teardown primitives shared by the MCP supervisor and the
    # check runner: group liveness, group signalling, and the TERM → wait →
    # KILL → wait ladder. Per-caller policies (the supervisor's EPERM-as-alive
    # polling cadence, the check runner's denied-group-kill fallback) stay at
    # the call sites.
    class ProcessGroup
      POLL_INTERVAL_SECONDS = 0.05

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

        def terminate(pid, grace:, poll_interval: POLL_INTERVAL_SECONDS)
          signal(pid, "TERM")
          wait_for_exit(pid, grace:, poll_interval:)
          return :exited unless alive?(pid)

          signal(pid, "KILL")
          wait_for_exit(pid, grace:, poll_interval:)
          alive?(pid) ? :survived : :exited
        end

        private

        def wait_for_exit(pid, grace:, poll_interval:)
          deadline = Clock.monotonic.now + grace
          while alive?(pid) && Clock.monotonic.now < deadline
            sleep(poll_interval)
          end
        end
      end
    end
  end
end
