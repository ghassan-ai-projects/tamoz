# frozen_string_literal: true

require 'rbconfig'

module Tamoz
  module Agent
    # The processes `tamoz start` runs: each spawned with its own environment and log, and supervised together.
    module CLIChildProcesses
      EXE = File.expand_path('../../../exe/tamoz', __dir__)

      private

      def env_with_file(env_file) = @env.to_h.merge(env_file ? read_env_file(env_file) : {})

      def env_file_problem(env_file)
        return unless env_file
        return "cannot read --env-file #{env_file}" unless File.readable?(env_file)

        return unless File.stat(env_file).mode.anybits?(0o077)

        "#{env_file} holds secrets and others can read it; run chmod 600 on it"
      end

      def read_env_file(path)
        File.readlines(path, chomp: true).filter_map do |line|
          line = line.delete_suffix("\r").sub(/\Aexport\s+/, '')
          next if line.strip.empty? || line.lstrip.start_with?('#') || !line.include?('=')

          name, value = line.split('=', 2).map(&:strip)
          [name, unquote(value)]
        end.to_h
      end

      def unquote(value)
        return value[1..-2] if value.length >= 2 && value.start_with?(value[-1]) && ['"', "'"].include?(value[0])

        value
      end

      def child_runtime_env
        { 'RUBYLIB' => $LOAD_PATH.join(File::PATH_SEPARATOR), 'GEM_HOME' => Gem.dir,
          'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR), 'LANG' => 'en_US.UTF-8', 'LC_ALL' => 'en_US.UTF-8' }
      end

      def spawn_child(name, env, args, logs)
        log = File.join(logs, "#{name}.log")
        Process.spawn(env, RbConfig.ruby, EXE, *args,
                      out: [log, 'a', 0o600], err: [log, 'a', 0o600], unsetenv_others: true)
      end

      # Every child runs until Ctrl-C; if one dies the others are stopped and its log tail is shown.
      def supervise(children, logs)
        stopping = false
        stop = ->(_reason) { stopping = true }
        Cancellation::Trap.install(int: stop, term: stop) do
          sleep 0.5 until stopping || (exited = exited_child(children))
          report_exit(exited, logs) if exited
        end
        stop_children(children)
        stopping ? 0 : 1
      end

      def exited_child(children)
        name, = children.find { |_name, pid| Process.wait(pid, Process::WNOHANG) }
        children.delete(name) && name
      end

      def report_exit(name, logs)
        log = File.join(logs, "#{name}.log")
        @err.puts "tamoz: the #{name} stopped; last lines of #{log}:\n#{File.readlines(log).last(8).join}\n" \
                  'Check the keys in your .env, or run `tamoz comms doctor`.'
      end

      def stop_children(children)
        @out.puts 'Stopping...'
        children.each_value { |pid| stop_child(pid) }
        @out.puts 'Stopped.'
      end

      # TERM, then KILL after a bounded wait: a wedged child must not make Ctrl-C unkillable.
      def stop_child(pid, grace: 8)
        Process.kill('TERM', pid)
        return if exited_within?(pid, grace)

        Process.kill('KILL', pid)
        reap(pid)
      rescue Errno::ESRCH
        nil
      end

      def reap(pid)
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end

      def exited_within?(pid, seconds)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          return true if Process.wait(pid, Process::WNOHANG)
          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.2
        end
      rescue Errno::ECHILD
        true
      end
    end
  end
end
