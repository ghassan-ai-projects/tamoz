# frozen_string_literal: true

module ThreadReadiness
  private

  def wait_until(timeout: 1.0)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        flunk "condition was not reached within #{timeout}s"
      end

      Thread.pass
    end
  end
end
