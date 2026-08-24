# frozen_string_literal: true

require 'open3'
require 'timeout'

module Tamoz
  module Tools
    # Runs one configured argv with bounded output and a credential-free environment.
    # :reek:DuplicateMethodCall :reek:FeatureEnvy :reek:TooManyStatements
    # :reek:UncommunicativeVariableName :reek:UtilityFunction
    # rubocop:disable Layout/LineLength, Metrics/AbcSize
    class CheckRunner
      ENV_PATTERN = /(?:\A|_)(?:API_?KEYS?|ACCESS_?KEYS?|SECRET_?KEYS?|PRIVATE_?KEYS?|SESSION_?KEYS?|TOKENS?|SECRETS?|PASSWORD|PASSWD|CREDENTIALS?|PASSPHRASE)(?:\z|_)/
      ENV_NAMES = %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN ANTHROPIC_API_KEY
                     DEEPSEEK_API_KEY GEMINI_API_KEY MISTRAL_API_KEY OLLAMA_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY PERPLEXITY_API_KEY XAI_API_KEY].freeze

      def self.credential_free_env(env = ENV)
        env.keys.each_with_object({}) { |name, delta| delta[name] = nil if credential_env?(name) }
      end

      def self.credential_env?(name)
        value = String(name).upcase
        ENV_NAMES.include?(value) || ENV_PATTERN.match?(value)
      end

      def self.shell_display(value)
        return value if value.match?(%r{\A[a-zA-Z0-9_.,:/@%+=-]+\z})

        "'#{value.gsub("'", %q('"'"'))}'"
      end

      def initialize(toolbox)
        @toolbox = toolbox
        freeze
      end

      def run(arguments)
        name = arguments.fetch('name')
        argv = toolbox.checks.fetch(name)
        stdout_text, stderr_text, status, timed_out = execute(argv)
        outcome = if timed_out
                    'timed_out'
                  elsif status.signaled?
                    "signal_#{status.termsig}"
                  else
                    "exit_#{status.exitstatus}"
                  end
        CheckReceipt.new(name:, outcome:, stdout: stdout_text, stderr: stderr_text)
      rescue SystemCallError => e
        raise ToolError, "check #{name.inspect} could not start: #{e.class}"
      end

      private

      attr_reader :toolbox

      def execute(argv)
        stdout_text = stderr_text = status = nil
        timed_out = false
        Open3.popen3(self.class.credential_free_env, *argv, chdir: toolbox.root.to_s,
                                                            pgroup: true) do |stdin, stdout, stderr, wait_thread|
          stdin.close
          limit = Toolbox::MAX_CHECK_OUTPUT_BYTES / 2
          stdout_reader = Thread.new { read_bounded(stdout, limit:) }
          stderr_reader = Thread.new { read_bounded(stderr, limit:) }
          begin
            status = Timeout.timeout(toolbox.check_timeout) { wait_thread.value }
          rescue Timeout::Error
            timed_out = true
            terminate_group(wait_thread.pid, wait_thread)
          ensure
            stdout_text = stdout_reader.value
            stderr_text = stderr_reader.value
          end
        end
        [stdout_text, stderr_text, status, timed_out]
      end

      def read_bounded(io, limit:)
        output = +''
        truncated = false
        loop do
          chunk = io.readpartial(8 * 1024)
          remaining = limit - output.bytesize
          if remaining.positive?
            output << chunk.byteslice(0, remaining)
            truncated ||= chunk.bytesize > remaining
          else
            truncated = true
          end
        end
      rescue EOFError
        output << "\n... output truncated" if truncated
        output.force_encoding(Encoding::UTF_8).scrub
      end

      def terminate_group(pid, wait_thread)
        Cancellation::ProcessGroup.signal(pid, 'TERM')
        wait_thread.join(1)
        Cancellation::ProcessGroup.signal(pid, 'KILL')
        wait_thread.join
      rescue Errno::ESRCH
        wait_thread.join
      rescue Errno::ECHILD
        nil
      rescue SystemCallError
        # The group-kill itself was denied (e.g. the check re-exec'd under
        # different privileges) rather than the process being gone. Fall back
        # to a direct kill so the check isn't left running unsupervised, and
        # never let this escape to be mistaken for a spawn failure upstream.
        terminate_pid(pid, wait_thread)
      end

      def terminate_pid(pid, wait_thread)
        Process.kill('KILL', pid)
        wait_thread.join
      rescue SystemCallError
        nil
      end
    end
    # rubocop:enable Layout/LineLength, Metrics/AbcSize
  end
end
