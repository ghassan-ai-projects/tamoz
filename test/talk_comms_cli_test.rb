# frozen_string_literal: true

require_relative 'test_helper'
require 'socket'
require 'tmpdir'

# The talk channel under `tamoz comms serve` and `comms doctor`: a taken port is named, not a crash.
class TalkCommsCliTest < Minitest::Test
  def tamoz(runtime, *argv, env: {})
    out = StringIO.new
    err = StringIO.new
    status = Tamoz::Agent::CLI.run(['--runtime-dir', runtime, *argv], out:, err:, input: StringIO.new, env:)
    [status, out.string, err.string]
  end

  def free_port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }

  def with_talk_runtime
    Dir.mktmpdir('tamoz-talk-comms') do |root|
      FileUtils.mkdir_p(workspace = File.join(root, 'workspace'))
      runtime = File.join(root, 'runtime')
      port = free_port
      tamoz(runtime, 'setup', '--workspace', workspace)
      tamoz(runtime, 'channel', 'add', 'talk', '--port', port.to_s)
      yield runtime, port
    end
  end

  def test_serve_names_a_taken_port
    with_talk_runtime do |runtime, port|
      TCPServer.open('127.0.0.1', port) do
        status, _out, err = tamoz(runtime, 'comms', 'serve', '--surface', 'talk',
                                  env: { 'TAMOZ_TALK_TOKEN' => 'a' * 43 })

        assert_equal 1, status
        assert_includes err, 'the talk page could not listen (EADDRINUSE)'
      end
    end
  end

  def test_doctor_names_a_taken_port
    with_talk_runtime do |runtime, port|
      TCPServer.open('127.0.0.1', port) do
        status, out, = tamoz(runtime, 'comms', 'doctor', env: { 'TAMOZ_TALK_TOKEN' => 'a' * 43 })

        assert_equal 1, status
        assert_includes out, "the talk page cannot listen on 127.0.0.1:#{port}"
      end
    end
  end
end
