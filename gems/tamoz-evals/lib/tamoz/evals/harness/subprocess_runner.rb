# frozen_string_literal: true

require "digest"
require "pathname"

module Tamoz
  module Evals
    module Harness
      class SubprocessRunner
        DEFAULT_OUTPUT_LIMIT_BYTES = 1024 * 1024
        DEFAULT_TERMINATION_GRACE_MS = 1_000
        MAX_ARGUMENTS = 256
        MAX_ARGUMENT_BYTES = 64 * 1024
        MAX_COMMAND_BYTES = 256 * 1024
        MAX_ENVIRONMENT_ENTRIES = 128
        MAX_ENVIRONMENT_BYTES = 256 * 1024
        MAX_OUTPUT_LIMIT_BYTES = 16 * 1024 * 1024
        MAX_TIMEOUT_MS = 3_600_000
        MAX_TERMINATION_GRACE_MS = 10_000
        INTERVENTION_KILL = "kill"
        READ_CHUNK_BYTES = 16 * 1024

        Stream = Data.define(
          :text,
          :bytes,
          :captured_bytes,
          :truncated,
          :digest
        ) do
          def to_h
            {
              "bytes" => bytes,
              "captured_bytes" => captured_bytes,
              "truncated" => truncated,
              "digest" => digest
            }.freeze
          end
        end

        Result = Data.define(
          :command,
          :exit_status,
          :term_signal,
          :timed_out,
          :termination,
          :termination_reason,
          :duration_ms,
          :stdout,
          :stderr
        ) do
          def success?
            !timed_out &&
              termination == "none" &&
              termination_reason == "none" &&
              exit_status == 0
          end

          def to_h
            {
              "command" => command,
              "exit_status" => exit_status,
              "term_signal" => term_signal,
              "timed_out" => timed_out,
              "termination" => termination,
              "termination_reason" => termination_reason,
              "duration_ms" => duration_ms,
              "stdout" => stdout.to_h,
              "stderr" => stderr.to_h
            }.freeze
          end
        end

        def self.resolve_executable(name, path:)
          unless name.is_a?(String)
            raise ExecutionError, "executable name must be a basename"
          end
          normalized_name = name.encode(Encoding::UTF_8)
          unless normalized_name.match?(/\A[A-Za-z0-9][A-Za-z0-9._+-]*\z/)
            raise ExecutionError, "executable name must be a basename"
          end
          unless path.is_a?(String)
            raise ExecutionError, "executable search path is invalid"
          end
          normalized_path = path.encode(Encoding::UTF_8)
          if normalized_path.b.include?("\0".b) ||
             normalized_path.bytesize > MAX_ENVIRONMENT_BYTES
            raise ExecutionError, "executable search path is invalid"
          end

          normalized_path.split(File::PATH_SEPARATOR).each do |entry|
            next unless Pathname.new(entry).absolute?

            candidate = File.join(entry, normalized_name)
            next unless File.file?(candidate) && File.executable?(candidate)

            return File.realpath(candidate).freeze
          end

          raise ExecutionError,
                "executable #{normalized_name.inspect} was not found in absolute PATH entries"
        rescue EncodingError, SystemCallError => error
          raise ExecutionError.new(
            "cannot resolve executable #{name.inspect}: #{error.message}"
          ), cause: error
        end

        def initialize(
          root:,
          environment:,
          output_limit_bytes: DEFAULT_OUTPUT_LIMIT_BYTES,
          termination_grace_ms: DEFAULT_TERMINATION_GRACE_MS
        )
          @root = normalize_root(root)
          @environment = normalize_environment(environment)
          @output_limit_bytes = bounded_integer(
            output_limit_bytes,
            name: "output_limit_bytes",
            minimum: 0,
            maximum: MAX_OUTPUT_LIMIT_BYTES
          )
          @termination_grace_ms = bounded_integer(
            termination_grace_ms,
            name: "termination_grace_ms",
            minimum: 1,
            maximum: MAX_TERMINATION_GRACE_MS
          )
          freeze
        end

        def capture(argv, timeout_ms:, command:, intervention: nil, poller: nil)
          arguments = normalize_arguments(argv)
          command_label = normalize_label(command, name: "command")
          intervention_object = normalize_intervention(intervention)
          poller_object = normalize_poller(poller)
          timeout = bounded_integer(
            timeout_ms,
            name: "timeout_ms",
            minimum: 1,
            maximum: MAX_TIMEOUT_MS
          )

          execute(
            arguments,
            timeout_ms: timeout,
            command: command_label,
            intervention: intervention_object,
            poller: poller_object
          )
        end

        private

        def execute(arguments, timeout_ms:, command:, intervention:, poller:)
          pid = nil
          reaped = false
          stdout_reader, stdout_writer = IO.pipe
          stderr_reader, stderr_writer = IO.pipe
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          pid = spawn_child(
            arguments,
            stdout_writer:,
            stderr_writer:
          )
          stdout_writer.close
          stderr_writer.close

          stdout_thread = capture_thread(stdout_reader)
          stderr_thread = capture_thread(stderr_reader)
          status, timed_out, termination, termination_reason = wait_for_child(
            pid,
            timeout_ms,
            intervention,
            poller
          )
          reaped = true
          drain_readers!(
            pid,
            [stdout_reader, stderr_reader],
            [stdout_thread, stderr_thread]
          )
          duration_ms = elapsed_ms(started)

          Result.new(
            command: command,
            exit_status: status.exited? ? status.exitstatus : nil,
            term_signal: status.signaled? ? Signal.signame(status.termsig) : nil,
            timed_out: timed_out,
            termination: termination,
            termination_reason: termination_reason,
            duration_ms: duration_ms,
            stdout: stdout_thread.value,
            stderr: stderr_thread.value
          ).freeze
        rescue ExecutionError
          raise
        rescue SystemCallError, IOError, ThreadError, ArgumentError => error
          raise ExecutionError.new(
            "cannot execute #{command.inspect}: #{error.class}: #{error.message}"
          ), cause: error
        ensure
          terminate_and_reap(pid) if pid && !reaped
          stdout_writer&.close unless stdout_writer&.closed?
          stderr_writer&.close unless stderr_writer&.closed?
          stdout_reader&.close unless stdout_reader&.closed?
          stderr_reader&.close unless stderr_reader&.closed?
          stdout_thread&.join(@termination_grace_ms.fdiv(1_000))
          stderr_thread&.join(@termination_grace_ms.fdiv(1_000))
        end

        def spawn_child(arguments, stdout_writer:, stderr_writer:)
          Process.spawn(
            @environment,
            *arguments,
            chdir: @root,
            in: File::NULL,
            out: stdout_writer,
            err: stderr_writer,
            pgroup: true,
            unsetenv_others: true,
            close_others: true
          )
        end

        def capture_thread(reader)
          limit = @output_limit_bytes
          Thread.new do
            digest = Digest::SHA256.new
            bytes = 0
            captured = +"".b

            begin
              loop do
                chunk = reader.readpartial(READ_CHUNK_BYTES)
                digest.update(chunk)
                bytes += chunk.bytesize
                remaining = limit - captured.bytesize
                captured << chunk.byteslice(0, remaining) if remaining.positive?
              end
            rescue EOFError
              nil
            rescue IOError
              raise unless reader.closed?
            ensure
              reader.close unless reader.closed?
            end

            text = bounded_utf8(captured, limit)
            Stream.new(
              text:,
              bytes:,
              captured_bytes: captured.bytesize,
              truncated: bytes > captured.bytesize,
              digest: "sha256:#{digest.hexdigest}".freeze
            ).freeze
          end
        end

        def wait_for_child(pid, timeout_ms, intervention, poller)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                     timeout_ms.fdiv(1_000)
          stop_signal = nil

          loop do
            _, observed = Process.waitpid2(
              pid,
              Process::WNOHANG | Process::WUNTRACED
            )
            if observed&.stopped?
              stop_signal = Signal.signame(observed.stopsig)
            elsif observed
              return [observed, false, "none", "none"]
            end

            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            break if remaining <= 0

            if poller
              decision = poll_running_child(
                poller,
                pid,
                [(remaining * 1_000).floor, 0].max
              )
              if decision == INTERVENTION_KILL
                signal_group("KILL", pid)
                status = wait_for_exit(pid, @termination_grace_ms)
                unless status&.signaled? && Signal.signame(status.termsig) == "KILL"
                  raise ExecutionError,
                        "poller did not produce SIGKILL process status"
                end

                return [status, false, "kill", "poller"]
              end
            end

            if stop_signal && intervention
              decision = poll_intervention(
                intervention,
                stop_signal,
                [(remaining * 1_000).floor, 0].max
              )
              unless decision.nil? ||
                     (decision.instance_of?(String) && decision == INTERVENTION_KILL)
                raise ExecutionError,
                      "intervention must return nil or #{INTERVENTION_KILL.inspect}"
              end
              break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

              if decision == INTERVENTION_KILL
                signal_group("KILL", pid)
                status = wait_for_exit(pid, @termination_grace_ms)
                unless status&.signaled? &&
                       Signal.signame(status.termsig) == "KILL"
                  raise ExecutionError,
                        "intervention did not produce SIGKILL process status"
                end

                return [status, false, "kill", "intervention"]
              end
            end

            sleep([remaining, 0.01].min)
          end

          term_sent = signal_group("TERM", pid, allow_missing: true)
          status = wait_for_exit(pid, @termination_grace_ms)
          if status
            return [
              status,
              term_sent,
              term_sent ? "term" : "none",
              term_sent ? "timeout" : "none"
            ]
          end

          kill_sent = signal_group("KILL", pid, allow_missing: true)
          status = wait_for_exit(pid, @termination_grace_ms)
          unless status
            raise ExecutionError,
                  "child process group did not exit after SIGKILL"
          end

          if kill_sent
            unless status.signaled? && Signal.signame(status.termsig) == "KILL"
              raise ExecutionError,
                    "timeout SIGKILL did not produce SIGKILL process status"
            end
            [status, true, "kill", "timeout"]
          elsif term_sent
            [status, true, "term", "timeout"]
          else
            [status, false, "none", "none"]
          end
        end

        def poll_running_child(poller, pid, remaining_ms)
          decision = poller.poll(pid:, remaining_ms:)
          unless decision.nil? ||
                 (decision.instance_of?(String) && decision == INTERVENTION_KILL)
            raise ExecutionError,
                  "poller must return nil or #{INTERVENTION_KILL.inspect}"
          end

          decision
        rescue ExecutionError
          raise
        rescue StandardError => error
          raise ExecutionError.new(
            "poller failed: #{error.class}"
          ), cause: error
        end

        def poll_intervention(intervention, stop_signal, remaining_ms)
          intervention.poll(stop_signal:, remaining_ms:)
        rescue StandardError => error
          raise ExecutionError.new(
            "intervention poll failed: #{error.class}"
          ), cause: error
        end

        def wait_for_exit(pid, timeout_ms)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                     timeout_ms.fdiv(1_000)
          loop do
            _, status = Process.waitpid2(pid, Process::WNOHANG)
            return status if status
            return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep(0.005)
          end
        end

        def drain_readers!(pid, readers, threads)
          return if readers_finished?(threads)

          signal_group("TERM", pid, allow_missing: true)
          unless readers_finished?(threads)
            signal_group("KILL", pid, allow_missing: true)
            readers.each { |reader| reader.close unless reader.closed? }
            readers_finished?(threads)
          end
          raise ExecutionError,
                "child descendants retained output streams after process exit"
        end

        def signal_group(signal, pid, allow_missing: false)
          Process.kill(signal, -pid)
          true
        rescue Errno::ESRCH
          raise unless allow_missing

          false
        rescue Errno::EPERM => error
          raise ExecutionError.new(
            "cannot signal child process group: #{error.message}"
          ), cause: error
        end

        def terminate_and_reap(pid)
          signal_group("KILL", pid, allow_missing: true)
          status = wait_for_exit(pid, @termination_grace_ms)
          return if status

          raise ExecutionError,
                "child process cleanup exceeded its termination budget"
        rescue Errno::ECHILD
          nil
        end

        def readers_finished?(threads)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) +
                     @termination_grace_ms.fdiv(1_000)
          threads.each do |thread|
            remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            thread.join([remaining, 0].max)
          end
          threads.none?(&:alive?)
        end

        def normalize_root(root)
          raw = File.path(root)
          raise ExecutionError, "root contains a NUL byte" if raw.include?("\0")

          real = File.realpath(raw)
          raise ExecutionError, "root is not a directory: #{raw}" unless File.directory?(real)

          real.freeze
        rescue TypeError, ArgumentError, SystemCallError => error
          raise ExecutionError.new("invalid subprocess root: #{error.message}"), cause: error
        end

        def bounded_utf8(bytes, maximum_bytes)
          text = bytes.encode(
            Encoding::UTF_8,
            invalid: :replace,
            undef: :replace,
            replace: "\uFFFD"
          )
          if text.bytesize > maximum_bytes
            text = text.byteslice(0, maximum_bytes)
            text = text.force_encoding(Encoding::UTF_8).scrub("")
          end
          text.freeze
        end

        def normalize_arguments(argv)
          unless argv.is_a?(Array) && argv.length.between?(1, MAX_ARGUMENTS)
            raise ExecutionError,
                  "argv must contain between 1 and #{MAX_ARGUMENTS} arguments"
          end

          total = 0
          normalized = argv.map.with_index do |argument, index|
            value = normalize_text(
              argument,
              name: "argv[#{index}]",
              maximum_bytes: MAX_ARGUMENT_BYTES
            )
            total += value.bytesize
            value
          end
          if total > MAX_COMMAND_BYTES
            raise ExecutionError, "argv exceeds #{MAX_COMMAND_BYTES} bytes"
          end

          executable = normalized.first
          unless Pathname.new(executable).absolute? && File.file?(executable) &&
                 File.executable?(executable)
            raise ExecutionError,
                  "argv[0] must be an absolute executable file"
          end

          normalized.freeze
        end

        def normalize_environment(environment)
          unless environment.is_a?(Hash) &&
                 environment.length <= MAX_ENVIRONMENT_ENTRIES
            raise ExecutionError,
                  "environment must contain at most #{MAX_ENVIRONMENT_ENTRIES} entries"
          end

          total = 0
          normalized = environment.each_with_object({}) do |(key, value), result|
            name = normalize_text(key, name: "environment key", maximum_bytes: 128)
            unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
              raise ExecutionError, "invalid environment key #{name.inspect}"
            end
            if result.key?(name)
              raise ExecutionError, "duplicate environment key #{name.inspect}"
            end

            entry = normalize_text(
              value,
              name: "environment value for #{name}",
              maximum_bytes: MAX_ARGUMENT_BYTES,
              allow_empty: true
            )
            total += name.bytesize + entry.bytesize
            result[name.freeze] = entry
          end
          if total > MAX_ENVIRONMENT_BYTES
            raise ExecutionError,
                  "environment exceeds #{MAX_ENVIRONMENT_BYTES} bytes"
          end

          normalized.freeze
        end

        def normalize_label(value, name:)
          text = normalize_text(value, name:, maximum_bytes: 128)
          unless text.match?(/\A[a-z0-9][a-z0-9._-]*\z/)
            raise ExecutionError, "#{name} must be a bounded public identifier"
          end

          text
        end

        def normalize_intervention(intervention)
          return nil if intervention.nil?
          return intervention if intervention.respond_to?(:poll)

          raise ExecutionError, "intervention must respond to poll"
        end

        def normalize_poller(poller)
          return nil if poller.nil?
          return poller if poller.respond_to?(:poll)

          raise ExecutionError, "poller must respond to poll"
        end

        def normalize_text(value, name:, maximum_bytes:, allow_empty: false)
          unless value.is_a?(String)
            raise ExecutionError, "#{name} must be a String"
          end
          text = value.encode(Encoding::UTF_8)
          if text.b.include?("\0".b)
            raise ExecutionError, "#{name} contains a NUL byte"
          end
          if !allow_empty && text.empty?
            raise ExecutionError, "#{name} must not be empty"
          end
          if text.bytesize > maximum_bytes
            raise ExecutionError, "#{name} exceeds #{maximum_bytes} bytes"
          end

          text.freeze
        rescue EncodingError => error
          raise ExecutionError.new(
            "#{name} is not valid UTF-8: #{error.message}"
          ), cause: error
        end

        def bounded_integer(value, name:, minimum:, maximum:)
          unless value.is_a?(Integer) && value.between?(minimum, maximum)
            raise ExecutionError,
                  "#{name} must be an Integer between #{minimum} and #{maximum}"
          end

          value
        end

        def elapsed_ms(started)
          (
            (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1_000
          ).round
        end

        private_constant :READ_CHUNK_BYTES
      end
    end
  end
end
