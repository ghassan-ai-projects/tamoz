# frozen_string_literal: true

require "mcp"

module Tamoz
  module Mcp
    # Owns the child process for one MCP server (P10 §8). Spawning reuses the
    # official SDK's stdio transport framing — this class subclasses
    # `MCP::Client::Stdio` so the JSON-RPC wire logic stays in the SDK — but
    # replaces process lifecycle: exact argv with no shell, `cwd` from the
    # config, a process-group spawn so teardown kills the whole tree, an
    # environment restricted to the allowlist plus explicitly resolved
    # credential refs, and a bounded stderr capture.
    #
    # Credential VALUES are read from the operator environment at spawn time,
    # handed to the child, and never interpolated into any message or log.
    class Supervisor < MCP::Client::Stdio
      # Grace period between SIGTERM and SIGKILL on teardown (plan §8).
      TERM_GRACE_SECONDS = 2.0
      # Wait for a clean exit after stdin closes before escalating to signals.
      EXIT_GRACE_SECONDS = 2.0
      # Poll interval while waiting for the process group to die.
      REAP_POLL_SECONDS = 0.05

      attr_reader :config

      def initialize(config, environ: ENV)
        unless config.is_a?(ServerConfig)
          raise ValidationError, "config must be a Tamoz::Mcp::ServerConfig"
        end

        @config = config
        @environ = environ
        @working_directory = config.working_directory
        @pid = nil
        @stderr_buffer = +""
        @stderr_mutex = Mutex.new
        super(
          command: config.command,
          args: config.arguments,
          read_timeout: config.budgets.request_timeout
        )
      end

      # Health state from the plan's lifecycle: starting → ready → retired.
      # (degraded/open arrive with the circuit slice; v1 catalog use only
      # exercises these three.)
      def state
        return :retired unless @started

        connected? ? :ready : :starting
      end

      def pid
        @pid
      end

      # Bounded, scrubbed tail of the child's stderr. Untrusted server content:
      # surfaced only as typed error metadata by callers, never into prompts.
      def stderr_tail
        text = @stderr_mutex.synchronize { @stderr_buffer.dup }
        text.force_encoding(Encoding::UTF_8)
        text = text.scrub("?") unless text.valid_encoding?
        text.gsub(CONTROL_CHARACTER_PATTERN, " ").strip.freeze
      end

      # Spawns the child in its own process group with the restricted
      # environment. Overrides the SDK's Open3 spawn so `pgroup: true`,
      # `chdir:`, and `unsetenv_others: true` are guaranteed.
      def start
        raise ProtocolError, "MCP supervisor already started" if @started

        child_env = child_environment
        stdin_r, stdin_w = IO.pipe
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe
        begin
          @pid = Process.spawn(
            child_env,
            @command, *@args,
            unsetenv_others: true,
            pgroup: true,
            chdir: @working_directory,
            in: stdin_r, out: stdout_w, err: stderr_w
          )
        rescue SystemCallError
          raise ProtocolError, "The MCP server process could not be spawned."
        ensure
          stdin_r.close
          stdout_w.close
          stderr_w.close
        end

        @stdin = stdin_w
        @stdout = stdout_r
        @stderr = stderr_r
        @stdout.set_encoding("UTF-8")
        @stdin.set_encoding("UTF-8")
        @wait_thread = Process.detach(@pid)
        start_stderr_capture
        @started = true
        nil
      end

      # Reliable teardown: close the pipes, wait for a clean exit, then
      # SIGTERM → grace → SIGKILL addressed to the whole process group so no
      # child or grandchild survives (plan §8 teardown contract).
      def close
        return unless @started

        [@stdin, @stdout].each do |io|
          io.close unless io.closed?
        rescue IOError
          nil
        end

        wait_for_group_exit(EXIT_GRACE_SECONDS)
        if process_group_alive?
          signal_process_group("TERM")
          wait_for_group_exit(TERM_GRACE_SECONDS)
        end
        if process_group_alive?
          signal_process_group("KILL")
          wait_for_group_exit(TERM_GRACE_SECONDS)
        end

        begin
          @stderr.close unless @stderr.closed?
        rescue IOError
          nil
        end
        @stderr_thread&.join(TERM_GRACE_SECONDS)
        @started = false
        @initialized = false
        @server_info = nil
        nil
      end
      alias_method :teardown, :close

      private

      # Environment handed to the child: allowlisted names inherited from the
      # operator environment plus credential refs resolved from it. Values are
      # never logged; a missing credential ref fails closed naming the
      # variable only.
      def child_environment
        env = {}
        @config.env_allowlist.each do |name|
          value = @environ[name]
          env[name] = value unless value.nil?
        end
        @config.credential_refs.each do |name|
          value = @environ[name]
          if value.nil?
            raise ValidationError,
                  "credential ref #{name} is not set in the operator environment"
          end
          env[name] = value
        end
        env
      end

      def start_stderr_capture
        limit = @config.budgets.stderr_bytes
        @stderr_thread = Thread.new do
          Thread.current.report_on_exception = false
          loop do
            chunk = @stderr.readpartial(STDERR_READ_SIZE)
            @stderr_mutex.synchronize do
              @stderr_buffer << chunk.b
              if @stderr_buffer.bytesize > limit
                @stderr_buffer = @stderr_buffer.byteslice(-limit, limit) || +""
              end
            end
          end
        rescue IOError, Errno::EBADF, EOFError
          nil
        end
      end

      def process_group_alive?
        return false unless @pid

        Process.kill(0, -@pid)
        true
      rescue Errno::ESRCH, Errno::ECHILD
        false
      rescue Errno::EPERM
        true
      end

      def signal_process_group(signal)
        Process.kill(signal, -@pid)
      rescue Errno::ESRCH, Errno::EPERM, Errno::ECHILD
        nil
      end

      def wait_for_group_exit(timeout)
        deadline = monotonic_now + timeout
        while process_group_alive? && monotonic_now < deadline
          sleep(REAP_POLL_SECONDS)
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
