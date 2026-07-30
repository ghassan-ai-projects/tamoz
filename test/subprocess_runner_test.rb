# frozen_string_literal: true

require_relative "test_helper"
require "digest"

class SubprocessRunnerTest < Minitest::Test
  def test_captures_exact_environment_exit_and_stream_digests
    previous_hidden = ENV["TAMOZ_HIDDEN"]
    ENV["TAMOZ_HIDDEN"] = "ambient-secret"
    runner = build_runner(
      environment: {
        "TAMOZ_VISIBLE" => "present"
      }
    )
    script = <<~'RUBY'
      STDOUT.write("#{ENV.fetch("TAMOZ_VISIBLE")}:#{ENV.key?("TAMOZ_HIDDEN")}")
      STDERR.write("warning")
    RUBY

    result = runner.capture(
      [RbConfig.ruby, "-e", script],
      timeout_ms: 2_000,
      command: "test.environment"
    )

    assert result.success?
    assert_equal 0, result.exit_status
    assert_nil result.term_signal
    refute result.timed_out
    assert_equal "none", result.termination
    assert_equal "present:false", result.stdout.text
    assert_equal "warning", result.stderr.text
    assert_equal digest("present:false"), result.stdout.digest
    assert_equal digest("warning"), result.stderr.digest
    assert_equal result.stdout.bytes, result.stdout.captured_bytes
    refute result.stdout.truncated
    assert_equal "test.environment", result.to_h.fetch("command")
    assert result.frozen?
  ensure
    if previous_hidden
      ENV["TAMOZ_HIDDEN"] = previous_hidden
    else
      ENV.delete("TAMOZ_HIDDEN")
    end
  end

  def test_bounded_capture_drains_stdout_and_stderr_without_deadlock
    runner = build_runner(output_limit_bytes: 1_024)
    script = <<~'RUBY'
      threads = [
        Thread.new { 200.times { STDOUT.write("o" * 1024) } },
        Thread.new { 200.times { STDERR.write("e" * 1024) } }
      ]
      threads.each(&:join)
    RUBY

    result = runner.capture(
      [RbConfig.ruby, "-e", script],
      timeout_ms: 5_000,
      command: "test.output-limit"
    )

    assert result.success?
    assert_equal 204_800, result.stdout.bytes
    assert_equal 204_800, result.stderr.bytes
    assert_equal 1_024, result.stdout.captured_bytes
    assert_equal 1_024, result.stderr.captured_bytes
    assert result.stdout.truncated
    assert result.stderr.truncated
    assert_equal "o" * 1_024, result.stdout.text
    assert_equal "e" * 1_024, result.stderr.text
    assert_equal digest("o" * 204_800), result.stdout.digest
    assert_equal digest("e" * 204_800), result.stderr.digest
  end

  def test_timeout_escalates_to_kill_for_term_resistant_child
    runner = build_runner(termination_grace_ms: 50)
    script = <<~'RUBY'
      trap("TERM") {}
      loop { sleep 1 }
    RUBY

    result = runner.capture(
      [RbConfig.ruby, "-e", script],
      timeout_ms: 50,
      command: "test.timeout"
    )

    refute result.success?
    assert result.timed_out
    assert_equal "kill", result.termination
    assert_nil result.exit_status
    assert_equal "KILL", result.term_signal
    assert_operator result.duration_ms, :<, 2_000
  end

  def test_timeout_stops_cooperative_child_with_term
    runner = build_runner(termination_grace_ms: 200)

    result = runner.capture(
      [RbConfig.ruby, "-e", "sleep 60"],
      timeout_ms: 25,
      command: "test.term-timeout"
    )

    refute result.success?
    assert result.timed_out
    assert_equal "term", result.termination
    assert(result.exit_status || result.term_signal)
    refute_equal 0, result.exit_status
  end

  def test_utf8_replacement_cannot_expand_retained_output_past_limit
    runner = build_runner(output_limit_bytes: 10)
    script = 'STDOUT.binmode; STDOUT.write("\\xFF".b * 100)'

    result = runner.capture(
      [RbConfig.ruby, "-e", script],
      timeout_ms: 2_000,
      command: "test.invalid-utf8"
    )

    assert result.success?
    assert_equal 100, result.stdout.bytes
    assert_equal 10, result.stdout.captured_bytes
    assert result.stdout.truncated
    assert result.stdout.text.valid_encoding?
    assert_operator result.stdout.text.bytesize, :<=, 10
  end

  def test_descendant_that_retains_streams_is_not_reported_as_success
    runner = build_runner(termination_grace_ms: 50)
    script = <<~'RUBY'
      fork { sleep 60 }
      exit! 0
    RUBY

    error = assert_raises(Tamoz::Evals::ExecutionError) do
      runner.capture(
        [RbConfig.ruby, "-e", script],
        timeout_ms: 2_000,
        command: "test.descendant"
      )
    end

    assert_includes error.message, "retained output streams"
  end

  def test_rejects_shell_lookup_nul_and_ambient_environment
    error = assert_raises(Tamoz::Evals::ExecutionError) do
      build_runner.capture(
        ["ruby", "-e", "exit"],
        timeout_ms: 100,
        command: "test.invalid"
      )
    end
    assert_includes error.message, "absolute executable"

    error = assert_raises(Tamoz::Evals::ExecutionError) do
      build_runner(environment: {"BAD\0KEY" => "value"})
    end
    assert_includes error.message, "NUL"

    error = assert_raises(Tamoz::Evals::ExecutionError) do
      build_runner(environment: {"BAD_VALUE" => "\xFF".b})
    end
    assert_includes error.message, "valid UTF-8"

    error = assert_raises(Tamoz::Evals::ExecutionError) do
      build_runner.capture(
        [RbConfig.ruby, "-e", "exit"],
        timeout_ms: 100,
        command: "UPPERCASE"
      )
    end
    assert_includes error.message, "public identifier"
  end

  def test_executable_resolution_ignores_relative_path_entries
    Dir.mktmpdir("tamoz-path") do |directory|
      executable = File.join(directory, "safe-tool")
      File.write(executable, "#!/bin/sh\nexit 0\n", encoding: Encoding::UTF_8)
      File.chmod(0o700, executable)

      resolved = Tamoz::Evals::Harness::SubprocessRunner.resolve_executable(
        "safe-tool",
        path: "relative#{File::PATH_SEPARATOR}#{directory}"
      )
      assert_equal File.realpath(executable), resolved
    end

    error = assert_raises(Tamoz::Evals::ExecutionError) do
      Tamoz::Evals::Harness::SubprocessRunner.resolve_executable(
        "../tool",
        path: "/usr/bin"
      )
    end
    assert_includes error.message, "basename"
  end

  private

  def build_runner(
    environment: {},
    output_limit_bytes: 4_096,
    termination_grace_ms: 200
  )
    Tamoz::Evals::Harness::SubprocessRunner.new(
      root: ROOT,
      environment:,
      output_limit_bytes:,
      termination_grace_ms:
    )
  end

  def digest(value)
    "sha256:#{Digest::SHA256.hexdigest(value)}"
  end
end
