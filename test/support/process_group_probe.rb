# frozen_string_literal: true

module ProcessGroupProbe
  private

  def group_alive?(pid)
    Process.kill(0, -pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end
end
