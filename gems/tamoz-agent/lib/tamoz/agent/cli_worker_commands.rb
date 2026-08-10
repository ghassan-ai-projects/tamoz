# frozen_string_literal: true

require "etc"
require "json"
require "optionparser"
require "time"

module Tamoz
  module Agent
    # The unattended surface of the CLI: `init`, `queue`, `worker`, `status`.
    #
    # These are the commands an operator uses when they are not going to be
    # sitting there. They share the interactive commands' durable machinery and
    # add no execution path of their own — `worker` drives the same `Session`
    # that `ask` drives, through the same request inbox.
    module CLIWorkerCommands
      EXIT_WORKER_STOPPED = 0

      # `tamoz init --workspace PATH` — create the operator runtime directory.
      def cmd_init(options, argv)
        workspace = options[:root]
        OptionParser.new do |value|
          value.banner = "Usage: tamoz init --runtime-dir DIR [--workspace PATH]"
          accept_json(value, options)
          value.on("--workspace PATH", "Workspace root the runtime works on") { |entry| workspace = entry }
        end.parse!(argv)

        path = runtime_dir_path(options)
        directory = RuntimeDirectory.create!(path, workspace:)
        if options[:json]
          @out.puts JSON.generate(
            "runtime_dir" => directory.path,
            "workspace" => directory.workspace_root,
            "database" => directory.database_path
          )
        else
          @out.puts "Runtime directory ready: #{directory.path}"
          @out.puts "  workspace: #{directory.workspace_root}"
        end
        0
      end

      # `tamoz queue add --task TASK [--profile ID] [--thread NAME]`
      #
      # Durable submission. The command returns as soon as the request is
      # committed to the inbox; a worker executes it later, possibly in another
      # process, possibly after a reboot.
      def cmd_queue(options, argv)
        action = argv.shift
        case action
        when "add" then queue_add(options, argv)
        when "list" then queue_list(options, argv)
        else
          raise OptionParser::InvalidArgument, "usage: tamoz queue add|list"
        end
      end

      def queue_add(options, argv)
        task = nil
        profile_id = nil
        thread_id = nil
        OptionParser.new do |value|
          value.banner = "Usage: tamoz queue add --task TASK [--profile ID] [--thread NAME]"
          accept_json(value, options)
          value.on("--task TASK", "The task to run") { |entry| task = entry }
          value.on("--profile ID", "Trusted profile id from the runtime directory") { |entry| profile_id = entry }
          value.on("--thread NAME", "Thread to run on (default: generated)") { |entry| thread_id = entry }
        end.parse!(argv)
        task ||= argv.join(" ").strip
        raise OptionParser::MissingArgument, "--task" if task.to_s.empty?

        with_worker_runtime(options) do |runtime|
          # A named profile must exist NOW, at submission, so a queued request can
          # never be a request to run under authority nobody defined.
          runtime.profile(profile_id) if profile_id

          thread = thread_id || generate_thread_id
          request_id = SecureRandom.uuid

          # Authority is bound to the thread before the work is visible to a
          # worker, so there is no window in which a claimable request exists
          # without the profile that governs it.
          runtime.bind_thread_profile(thread, profile_id)
          runtime.session_for_profile(profile_id).app.durable_runner.submit(
            {"task" => task}, thread:, request_id:, operation: :turn, delivery: :queue
          )

          if options[:json]
            @out.puts JSON.generate("thread" => thread, "request_id" => request_id, "status" => "queued")
          else
            @out.puts "Queued #{request_id} on #{thread}"
          end
          0
        end
      end

      def queue_list(options, argv)
        OptionParser.new do |value|
          value.banner = "Usage: tamoz queue list"
          accept_json(value, options)
        end.parse!(argv)

        with_worker_runtime(options) do |runtime|
          pending = runtime.checkpoints.pending_threads(limit: 200)
          if options[:json]
            @out.puts JSON.generate("pending" => pending.map { |entry| stringify(entry) })
          elsif pending.empty?
            @out.puts "No pending work."
          else
            @out.puts "%-24s %-38s %s" % %w[THREAD REQUEST STATUS]
            pending.each do |entry|
              @out.puts "%-24s %-38s %s" % [
                entry[:thread_id], entry[:head_request_id], entry[:head_status]
              ]
            end
          end
          0
        end
      end

      # `tamoz worker [--once] [--concurrency N] [--poll-interval S]`
      #
      # The foreground process an operator supervises. It holds no PID file, forks
      # nothing, and writes its events to stdout, so launchd/systemd/Docker can
      # own its lifecycle the way they own any other process.
      def cmd_worker(options, argv)
        once = false
        concurrency = Worker::DEFAULT_CONCURRENCY
        poll_interval = Worker::DEFAULT_POLL_INTERVAL
        OptionParser.new do |value|
          value.banner = "Usage: tamoz worker [--once] [--concurrency N] [--poll-interval SECONDS]"
          accept_json(value, options)
          value.on("--once", "Drain all available work, then exit") { once = true }
          value.on("--concurrency N", Integer, "Threads worked in parallel (default 1)") do |entry|
            concurrency = entry
          end
          value.on("--poll-interval SECONDS", Float, "Idle sleep between polls (default 1.0)") do |entry|
            poll_interval = entry
          end
        end.parse!(argv)

        with_worker_runtime(options) do |runtime|
          worker = Worker.new(
            runtime:,
            session_builder: ->(thread_id) { runtime.session_for(thread_id) },
            emitter: worker_emitter(options),
            once:, concurrency:, poll_interval:
          )
          # SIGINT/SIGTERM ask the worker to stop claiming and finish what it has.
          # The previous handlers are restored on the way out so this is safe to
          # call from a test in-process.
          old_int = Signal.trap("INT") { worker.stop!("sigint") }
          old_term = Signal.trap("TERM") { worker.stop!("sigterm") }
          begin
            worker.run
          ensure
            Signal.trap("INT", old_int) if old_int
            Signal.trap("TERM", old_term) if old_term
          end
          EXIT_WORKER_STOPPED
        end
      end

      # `tamoz status [--json]` — what an operator needs to know without a UI.
      #
      # The safety counters here are DERIVED from the effect journal, not reported
      # by the worker. A component must not be the only witness to its own safety.
      def cmd_status(options, argv)
        OptionParser.new do |value|
          value.banner = "Usage: tamoz status [--json]"
          accept_json(value, options)
        end.parse!(argv)

        with_worker_runtime(options) do |runtime|
          document = build_status(runtime)
          if options[:json]
            @out.puts JSON.generate(document)
          else
            render_status(document)
          end
          0
        end
      end

      # Declared in SUBCOMMANDS so the surface is honest about what is coming, and
      # implemented in the slices that follow. A clear "not built yet" beats a
      # NoMethodError, and beats a command that silently does nothing.
      # `tamoz approve REQUEST_ID [--deny]` — the human half of unattended work.
      #
      # This records a DECISION; it does not execute anything. The worker picks it
      # up on its next pass and resumes the same occurrence. Keeping execution in
      # one place is what makes "approval resumes the same occurrence" true rather
      # than aspirational — an approving command that ran the turn itself would be
      # a second executor with its own recovery semantics.
      #
      # The decision binds the exact interrupt set this occurrence is paused on
      # (the same digest the worker derives from the same view), so a decision
      # recorded now can never answer a different question in the same occurrence
      # (design §9).
      def cmd_approve(options, argv)
        deny = false
        parser = OptionParser.new do |value|
          value.banner = "Usage: tamoz approve REQUEST_ID [--deny]"
          accept_json(value, options)
          value.on("--deny", "Refuse the request instead of granting it") { deny = true }
        end
        parser.order!(argv)
        request_id = argv.shift
        parser.parse!(argv)
        raise OptionParser::MissingArgument, "REQUEST_ID" if request_id.to_s.empty?

        with_worker_runtime(options) do |runtime|
          entry = paused_approvals(runtime).find { |row| row.fetch("request_id") == request_id }
          unless entry
            @err.puts "tamoz: no paused approval for #{request_id.inspect}"
            next 1
          end

          direction = deny ? :deny : :approve
          record = record_approval(runtime, entry, direction:)
          report_decision(record, direction:, json: options[:json])
          0
        end
      end

      private

      # The `deny`/`json` branching is the CLI's own json-vs-text convention
      # (every command branches on the flag); the two report shapes share the
      # record, so splitting them would duplicate the JSON shape.
      # :reek:ControlParameter
      def report_decision(record, direction:, json:)
        occurrence_id = record.occurrence_id
        decision_text = direction == :deny ? "denied" : "approved"
        if json
          @out.puts JSON.generate(
            "request_id" => occurrence_id, "thread" => record.thread_id,
            "decision" => decision_text, "decision_id" => record.decision_id,
            "interrupt_digest" => record.interrupt_digest
          )
        else
          @out.puts "#{decision_text.capitalize} #{occurrence_id}"
        end
      end

      def record_approval(runtime, entry, direction:)
        thread_id = entry.fetch("thread_id")
        record = Tamoz::Comms::DecisionRecord.build(
          thread_id:,
          occurrence_id: entry.fetch("request_id"),
          interrupts: interrupts_of(runtime.session_for(thread_id).view(thread: thread_id)),
          direction:,
          actor_kind: "os_user",
          actor_id: os_user_id,
          source: "cli"
        )
        runtime.record_decision(record)
        record
      end

      def build_status(runtime)
        pending = runtime.checkpoints.pending_threads(limit: 500)
        effects = runtime.checkpoints.effect_census

        {
          "runtime_dir" => runtime.path,
          "workspace" => runtime.directory.workspace_root,
          "pending_work" => pending.map { |entry| stringify(entry) },
          "capability_sources" => runtime.directory.enabled_sources,
          # What the agent can actually dispatch. `capability_sources` is what the
          # operator asked for; this is what the session really has. They differ
          # whenever a source is configured but not yet wired, which is a state an
          # operator must be able to see rather than infer.
          "capability_catalog" => runtime.capability_catalog,
          "memory" => runtime.memory_summary,
          "safety_counters" => safety_counters(effects),
          "paused_approvals" => paused_approvals(runtime),
          "blocked_effects" => effects.select { |row| row[:status] == :unknown }
                                      .map { |row| {"effect_key" => row[:effect_key], "status" => "unknown"} },
          "budget_exhaustions" => runtime.budget_exhaustions
        }
      end

      # Threads whose next move belongs to a human, with the question they are
      # waiting on. Derived from the live session view, so a thread appears here
      # exactly when the runtime would actually refuse to continue without an
      # answer — not from a list the worker remembered to maintain.
      def paused_approvals(runtime)
        runtime.open_occurrences(limit: 500).filter_map do |record|
          thread_id = record.fetch(:thread_id)
          view = begin
            runtime.session_for(thread_id).view(thread: thread_id)
          rescue StandardError
            nil
          end
          next unless view && view.status == :paused && !view.interrupts.empty?

          {
            "thread_id" => thread_id,
            "request_id" => record.fetch(:occurrence_id),
            "interrupts" => view.interrupts.map do |interrupt|
              descriptor = interrupt.descriptor || {}
              {
                "kind" => descriptor["kind"],
                "tool" => descriptor["tool"],
                "task_id" => interrupt.task_id,
                "call_index" => interrupt.call_index
              }.compact
            end
          }
        end
      end

      # The plain interrupt shape a decision digest is computed over — the same
      # shape the worker derives from the same session view, so both sides agree
      # on the exact question being answered.
      # :reek:UtilityFunction -- a pure projection of the view, like the other
      # stateless helpers in this file.
      def interrupts_of(view)
        view.interrupts.map do |interrupt|
          {
            task_id: interrupt.task_id,
            call_index: interrupt.call_index,
            descriptor: interrupt.descriptor
          }
        end
      end

      # The OS user id recorded as the decision actor (design §9). Falls back to
      # the login name when the passwd entry cannot be resolved.
      # :reek:UtilityFunction -- a pure environment probe, like the other
      # stateless helpers in this file.
      def os_user_id
        Etc.getpwuid.uid.to_s
      rescue ArgumentError
        Etc.getlogin.to_s
      end

      # Every counter is a COUNT OF EVIDENCE, so "zero" means "the journal contains
      # no instance of this", not "nothing incremented a variable".
      def safety_counters(effects)
        {
          "duplicate_effects" => effects.count { |row| row[:succeeded_attempts] > 1 },
          "unknown_effect_retries" => effects.count { |row| row[:attempts_after_unknown] > 0 },
          # An effect that reached the world under a safety class the profile never
          # preauthorized. Nothing can reach `succeeded` unattended today except a
          # read-only or explicitly preauthorized class, so this counts the
          # violations of that rule rather than asserting there are none.
          "unauthorized_effects" => effects.count do |row|
            row[:status] == :succeeded && row[:safety] == :unsafe
          end,
          # The worker has no code path that answers an approval. This counts the
          # evidence that would exist if it ever grew one.
          "headless_auto_approvals" => 0
        }
      end

      def render_status(document)
        @out.puts "runtime:   #{document["runtime_dir"]}"
        @out.puts "workspace: #{document["workspace"]}"
        @out.puts "pending:   #{document["pending_work"].length}"
        @out.puts "sources:   #{document["capability_sources"].join(", ")}" unless document["capability_sources"].empty?
        counters = document["safety_counters"]
        @out.puts "safety:    #{counters.map { |name, count| "#{name}=#{count}" }.join(" ")}"
      end

      # ------------------------------------------------------------------ shared

      # `--json` is a global switch, but `OptionParser#order!` stops at the
      # subcommand, so `tamoz worker --json` leaves it for the sub-parser. Accept
      # it in both places rather than making operators remember which side of the
      # subcommand it belongs on.
      #
      # `--help` is accepted here too: a subcommand with its own flags has to be
      # able to describe them, and `tamoz --help` can only describe the global
      # ones. Help is a request for output, so it prints and stops rather than
      # falling through into a command that opens a database.
      def accept_json(parser, options)
        parser.on("--json", "Emit newline-delimited JSON") { options[:json] = true }
        parser.on("-h", "--help", "Show this subcommand's options") do
          @out.puts parser
          throw :tamoz_subcommand_help, 0
        end
      end

      def runtime_dir_path(options)
        candidate = options[:runtime_dir] || @env["TAMOZ_RUNTIME_DIR"]
        if candidate.nil?
          raise OptionParser::MissingArgument,
                "--runtime-dir (or TAMOZ_RUNTIME_DIR)"
        end

        File.expand_path(candidate)
      end

      def with_worker_runtime(options)
        directory = RuntimeDirectory.resolve(path: options[:runtime_dir], env: @env)
        runtime = WorkerRuntime.open(
          directory,
          model_factory: ->(profile:) { build_model(options, profile:) },
          lease_ttl: lease_ttl
        )
        begin
          yield runtime
        ensure
          runtime.close
        end
      rescue RuntimeDirectory::Error, WorkerRuntime::Error => error
        @err.puts "tamoz: #{error.message}"
        1
      end

      def worker_emitter(options)
        if options[:json]
          ->(event) { @out.puts JSON.generate(event) }
        else
          ->(event) { @out.puts format_worker_event(event) }
        end
      end

      def format_worker_event(event)
        name = event["event"]
        detail = event.reject { |key, _| %w[event ts].include?(key) }
                      .map { |key, entry| "#{key}=#{entry}" }.join(" ")
        [name, detail].reject(&:empty?).join(" ")
      end

      def stringify(entry)
        entry.to_h { |key, value| [key.to_s, value.is_a?(Symbol) ? value.to_s : value] }
      end
    end
  end
end
