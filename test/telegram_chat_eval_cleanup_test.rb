# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'support/process_group_probe'
require_relative 'support/thread_readiness'
require_relative 'support/telegram_chat_eval'

class TelegramChatEvalCleanupTest < Minitest::Test
  include ProcessGroupProbe
  include ThreadReadiness

  STUBBORN_START = <<~RUBY
    trap('TERM') {}
    worker = Process.spawn(RbConfig.ruby, '-e', "trap('TERM') {}; sleep")
    File.write("\#{ARGV[0]}.tmp", worker.to_s)
    File.rename("\#{ARGV[0]}.tmp", ARGV[0])
    sleep
  RUBY

  class ProcessOnlyEval < TelegramChatEval
    attr_reader :root, :start_pid, :worker_pid

    def start
      pid_file = File.join(@root, 'worker.pid')
      @start_pid = spawn_child(:start, ['-e', STUBBORN_START, pid_file])
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      Thread.pass until File.exist?(pid_file) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      @worker_pid = File.read(pid_file).to_i
    end

    private

    def provision = nil
  end

  class UnprovisionableEval < TelegramChatEval
    class << self
      attr_accessor :root
    end

    private

    def provision
      self.class.root = @root
      raise 'setup failed'
    end
  end

  def setup
    @reports = Dir.mktmpdir('tamoz-telegram-eval-reports')
  end

  def teardown
    FileUtils.rm_rf(@reports)
    Process.kill('KILL', -@evaluation.start_pid) if @evaluation&.start_pid
  rescue Errno::ESRCH
    nil
  end

  def test_a_finished_run_leaves_no_process_and_no_directory
    @evaluation = ProcessOnlyEval.run(report_to: @reports, stop_grace: 0, &:start)

    assert_left_nothing(@evaluation)
  end

  def test_a_run_whose_scenario_raises_leaves_no_process_and_no_directory
    assert_raises(RuntimeError) do
      ProcessOnlyEval.run(report_to: @reports, stop_grace: 0) do |run|
        @evaluation = run
        run.start
        raise 'scenario raised'
      end
    end

    assert_left_nothing(@evaluation)
    assert_path_exists File.join(@reports, 'report.md')
  end

  def test_a_run_that_cannot_provision_removes_its_directory
    assert_raises(RuntimeError) { UnprovisionableEval.run(report_to: @reports) { flunk 'the run must not start' } }

    refute_path_exists UnprovisionableEval.root
  end

  private

  def assert_left_nothing(evaluation)
    assert_operator evaluation.worker_pid, :positive?
    assert_raises(Errno::ECHILD) { Process.wait(evaluation.start_pid, Process::WNOHANG) }
    wait_until(timeout: 5) { !group_alive?(evaluation.start_pid) }

    refute_path_exists evaluation.root
  end
end
