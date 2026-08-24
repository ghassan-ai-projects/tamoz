# frozen_string_literal: true

require "digest"

require "mcp"

module Tamoz
  module Mcp
    # In-memory circuit state behind the Supervisor's `CircuitStore` seam
    # (DR-2). The threshold is evaluated INSIDE every read-modify-write, so a
    # crash between increment and open can never lose the open state — a durable
    # caller-owned store is expected to do the same inside its transaction.
    #
    # Duck-typed `CircuitStore` contract (caller-injected; tamoz-mcp stays
    # tamoz-sqlite-free, plan §3 — a durable implementation is owned by the
    # caller, exactly like the EffectDispatcher journal pattern):
    #   record_failure(kind:, context:) -> :degraded | :open
    #   record_success -> :closed | :open     # never closes an open circuit
    #   open? -> bool
    #   failures -> Integer                   # consecutive transport failures
    #   reset(evidence:) -> :closed           # records the evidence
    #   reset_evidence -> Hash | nil
    #   last_failure_kind -> Symbol | nil
    #   last_failure_context -> Hash | nil
    #   conditions_digest(server_id) -> String
    class MemoryCircuitStore
      CONDITIONS_DOMAIN = "tamoz.mcp.circuit.conditions.v1\n"

      def initialize(threshold:)
        unless threshold.is_a?(Integer) && threshold >= 1
          raise ValidationError, "circuit threshold must be an integer >= 1"
        end

        @threshold = threshold
        @failures = 0
        @state = :closed
        @last_failure_kind = nil
        @last_failure_context = nil
        @reset_evidence = nil
        @mutex = Mutex.new
      end

      # Single atomic read-modify-write: counter += 1, then evaluate the
      # threshold inside the write so the open state is never lost between a
      # durable increment and a separate open decision.
      def record_failure(kind: :transport, context: nil)
        @mutex.synchronize do
          @failures += 1
          @last_failure_kind = kind.to_sym
          @last_failure_context = context.nil? ? nil : context.to_h.freeze
          @state = @failures >= @threshold ? :open : :degraded
          @state
        end
      end

      def record_success
        @mutex.synchronize do
          unless @state == :open
            @failures = 0
            @state = :closed
          end
          @state
        end
      end

      def open?
        @mutex.synchronize { @state == :open }
      end

      def failures
        @mutex.synchronize { @failures }
      end

      def reset(evidence: nil)
        @mutex.synchronize do
          @failures = 0
          @state = :closed
          @reset_evidence = evidence
          @state
        end
      end

      def reset_evidence
        @mutex.synchronize { @reset_evidence }
      end

      def last_failure_kind
        @mutex.synchronize { @last_failure_kind }
      end

      def last_failure_context
        @mutex.synchronize { @last_failure_context }
      end

      # Typed digest of the failure state a :server-scoped reset clears — the
      # "conditions met" evidence. Deterministic given the same failure state, so
      # a durable re-home can correlate a reset with the failures that preceded
      # it.
      def conditions_digest(server_id)
        payload = CONDITIONS_DOMAIN + CanonicalJSON.dump(
          "server_id" => server_id.to_s,
          "failure_kind" => last_failure_kind&.to_s,
          "context" => last_failure_context || {}
        )
        "sha256:#{Digest::SHA256.hexdigest(payload)}"
      end
    end

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
      include CircuitSupervision

      # Grace period between SIGTERM and SIGKILL on teardown (plan §8).
      TERM_GRACE_SECONDS = 2.0
      # Wait for a clean exit after stdin closes before escalating to signals.
      EXIT_GRACE_SECONDS = 2.0
      # Poll interval while waiting for the process group to die.
      REAP_POLL_SECONDS = 0.05

      attr_reader :config, :circuit_threshold, :retry_budget

      def self.build(config, **)
        return HttpSupervisor.new(config, **) if config.transport == :http

        new(config, **)
      end

      DEFAULT_CIRCUIT_THRESHOLD = CircuitSupervision::DEFAULT_CIRCUIT_THRESHOLD
      DEFAULT_RETRY_BUDGET = CircuitSupervision::DEFAULT_RETRY_BUDGET
      DEFAULT_BASE_BACKOFF = CircuitSupervision::DEFAULT_BASE_BACKOFF
      DEFAULT_MAX_BACKOFF = CircuitSupervision::DEFAULT_MAX_BACKOFF

      def initialize(
        config,
        environ: ENV,
        circuit_threshold: DEFAULT_CIRCUIT_THRESHOLD,
        retry_budget: DEFAULT_RETRY_BUDGET,
        base_backoff: DEFAULT_BASE_BACKOFF,
        max_backoff: DEFAULT_MAX_BACKOFF,
        random: Random.new,
        circuit_store: nil
      )
        unless config.is_a?(ServerConfig)
          raise ValidationError, "config must be a Tamoz::Mcp::ServerConfig"
        end
        CircuitSupervision.validate_parameters!(circuit_threshold:, retry_budget:, base_backoff:, max_backoff:)

        store = circuit_store || MemoryCircuitStore.new(threshold: circuit_threshold)
        validate_circuit_store!(store)

        @config = config
        @environ = environ
        @working_directory = config.working_directory
        @pid = nil
        @stderr_buffer = +""
        @stderr_mutex = Mutex.new
        # Resolved credential values the child environment carries; `stderr_tail`
        # redacts these (F2 — a hostile/faulty child must not be able to print a
        # credential value into diagnostic metadata → durable records, inv 24).
        @redaction_values = [].freeze
        @circuit_threshold = circuit_threshold
        @retry_budget = retry_budget
        @base_backoff = base_backoff.to_f
        @max_backoff = max_backoff.to_f
        @random = random
        @circuit_store = store
        @retired = false
        @request_sent = false
        @sent_mutex = Mutex.new
        super(
          command: config.command,
          args: config.arguments,
          read_timeout: config.budgets.request_timeout
        )
      end

      def pid
        @pid
      end

      # --- request-sent boundary ---------------------------------------------
      #
      # The SDK yields after the request line has been written to the child's
      # stdin, so the boolean distinguishes "timeout/crash before the request was
      # sent" (provably no effect) from "after the request was sent" (ambiguous
      # for non-idempotent effects). Resets at the start of every `send_request`.

      def send_request(request:, &block)
        @sent_mutex.synchronize { @request_sent = false }
        super do
          @sent_mutex.synchronize { @request_sent = true }
          block&.call
        end
      end

      def request_sent?
        @sent_mutex.synchronize { @request_sent }
      end

      # Bounded, scrubbed, credential-redacted tail of the child's stderr.
      # Untrusted server content: surfaced only as typed error metadata by
      # callers, never into prompts. Values the child env resolved for
      # `credential_refs` are redacted by exact match (length >= 8 to avoid
      # mangling short innocuous values) before the tail leaves the supervisor
      # (F2, inv 24).
      def stderr_tail
        text = @stderr_mutex.synchronize { @stderr_buffer.dup }
        text.force_encoding(Encoding::UTF_8)
        text = text.scrub("?") unless text.valid_encoding?
        text = text.gsub(CONTROL_CHARACTER_PATTERN, " ")
        @redaction_values.each { |value| text.gsub!(value, "[REDACTED]") }
        text.strip.freeze
      end

      # Spawns the child in its own process group with the restricted
      # environment. Overrides the SDK's Open3 spawn so `pgroup: true`,
      # `chdir:`, and `unsetenv_others: true` are guaranteed.
      def start
        raise ProtocolError, "MCP supervisor already started" if @started

        child_env = child_environment
        # F2: redact exactly the values resolved for declared credential refs —
        # the allowlist values are operator-chosen and not credentials by
        # definition. Short values (< 8 bytes) are skipped to avoid mangling
        # common innocuous substrings.
        @redaction_values = @config.credential_refs.filter_map do |name|
          value = @environ[name]
          value if value.is_a?(String) && value.bytesize >= 8
        end.freeze
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
        @retired = false
        nil
      end

      # Reliable teardown: close the pipes, wait for a clean exit, then
      # SIGTERM → grace → SIGKILL addressed to the whole process group so no
      # child or grandchild survives (plan §8 teardown contract). Also retires
      # a supervisor that was never started — a closed supervisor is never
      # auto-started again.
      def close
        @retired = true
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
        @retired = true
        nil
      end
      alias_method :teardown, :close

      private

      # The injected store must satisfy the full CircuitStore contract so a
      # durable swap is mechanical (DR-2).
      def validate_circuit_store!(store)
        required = %i[
          record_failure record_success open? failures reset
          reset_evidence last_failure_kind last_failure_context conditions_digest
        ]
        missing = required.reject { |method| store.respond_to?(method) }
        return if missing.empty?

        raise ValidationError,
              "circuit_store must respond to #{missing.join(", ")}"
      end

      # Reads one newline-delimited frame from the server's stdout, bounded by
      # the SDK's per-frame limit. Overrides the SDK's `read_line` so an
      # oversized frame raises the typed `OutputLimitError` instead of a generic
      # handler error: the stream is desynced and the transport must be closed
      # (mirrors the SDK's own behavior exactly), and the typed class lets
      # Invocation classify the output-flood row without matching on message
      # text.
      def read_line(method, params)
        line = @stdout.gets("\n", @max_line_bytes)
        return line unless line && !line.end_with?("\n") && line.bytesize >= @max_line_bytes

        begin
          close
        rescue StandardError
          nil
        end

        raise OutputLimitError
      end

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

        Cancellation::ProcessGroup.alive?(@pid)
      end

      # This supervisor treats a denied group kill as "already handled"; the
      # check runner's fallback to a direct-pid kill is deliberately NOT shared.
      def signal_process_group(signal)
        Cancellation::ProcessGroup.signal(@pid, signal)
      rescue Errno::EPERM
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
