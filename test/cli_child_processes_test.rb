# frozen_string_literal: true

require_relative 'test_helper'
require 'timeout'
require 'tmpdir'

# The children `tamoz start` runs are stopped even when they ignore TERM.
class CliChildProcessesTest < Minitest::Test
  def test_a_child_that_ignores_term_is_killed
    Dir.mktmpdir('tamoz-stop-child') do |directory|
      ready = File.join(directory, 'ready')
      pid = Process.spawn(RbConfig.ruby, '-e', "Signal.trap('TERM', 'IGNORE'); File.write(ARGV[0], 'ready'); sleep 30",
                          ready)
      Timeout.timeout(10) { sleep 0.01 until File.file?(ready) }
      began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})
                       .send(:stop_child, pid, grace: 0.5)

      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - began, :<, 5
    end
  end

  def test_an_env_file_reads_exports_quotes_and_comments
    Dir.mktmpdir('tamoz-env-file') do |directory|
      path = File.join(directory, '.env')
      File.write(path, "# keys\nexport ZAI_API_KEY='zai'\nOPENROUTER_API_KEY=\"or\"\r\nEMPTY=\n")
      cli = Tamoz::Agent::CLI.new(out: StringIO.new, err: StringIO.new, input: StringIO.new, env: {})

      assert_equal({ 'ZAI_API_KEY' => 'zai', 'OPENROUTER_API_KEY' => 'or', 'EMPTY' => '' },
                   cli.send(:read_env_file, path))
    end
  end
end
