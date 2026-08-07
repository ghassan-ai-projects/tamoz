# frozen_string_literal: true

require "json"
require "optparse"
require "securerandom"
require "fileutils"

module Tamoz
  module Agent
    class CLI
      USAGE_ERROR = 64
      EXIT_PAUSED = 3
      EXIT_SIGINT = 130
      EXIT_SIGTERM = 143

      # The unattended surface (`init`, `queue`, `worker`, `status`) lives in its
      # own file; it is the same CLI object, split only so neither half becomes
      # unreadable.
      include CLIWorkerCommands
      include CLIScheduleCommands
      include CLIProfileCommands
      include CLIAuthority

      SUBCOMMANDS = %w[
        ask resume continue list show follow-up follow_up followup
        redirect cancel resolve profile
        init queue worker status schedule approve
      ].freeze

      THREAD_ID_PATTERN = /\A[A-Za-z0-9_\-\.]{1,64}\z/.freeze

      def self.run(argv = ARGV, out: $stdout, err: $stderr, input: $stdin, env: ENV, model_factory: nil)
        new(out:, err:, input:, env:, model_factory:).run(argv)
      end

      def initialize(out:, err:, input:, env:, model_factory: nil)
        @out = out
        @err = err
        @input = input
        @env = env
        @cancellation = nil
        @model_factory = model_factory
        @stream_error = nil
        @rendered_stale_request_ids = {}
        @prompts = PromptAdapter.new(input:, err:)
        @parser = ArgumentParser.new(out:, subcommands: SUBCOMMANDS)
        @policy = OptionPolicy.new
      end

      def run(argv)
        options, subcommand, sub_argv = @parser.parse(argv)
        return 0 if options[:terminal]

        if subcommand
          dispatch_subcommand(subcommand, options, sub_argv)
        else
          run_one_shot(options, sub_argv)
        end
      rescue OptionParser::ParseError, ArgumentError => error
        handle_usage_error(error)
      rescue Tamoz::Agent::Error => error
        handle_fatal_error(error)
      # P16: the D-7 taxonomy moved to tamoz-core (`Tamoz::Core::ToolError` family),
      # so it no longer subclasses `Tamoz::Agent::Error`. Catch it EXPLICITLY here —
      # never widen to `Tamoz::Error`, which would also swallow StoreError,
      # LeaseLostError, ConfigurationError, and the Checkpoint* classes, converting
      # their backtraces into clean "tamoz: …" exit-1 output.
      rescue Tamoz::Core::ToolError => error
        handle_fatal_error(error)
      rescue Tamoz::CheckpointConflictError => error
        handle_fatal_error(error)
      end

      private

      # Error policy (Q3): a raised error becomes one terminal report and one
      # exit code. Usage errors additionally hint at --help; every other error
      # class in the taxonomy exits 1 with a "tamoz: " message. Pinned by the
      # error-taxonomy tests in test/agent_cli_test.rb.
      def handle_usage_error(error)
        @err.puts "tamoz: #{error.message}"
        @err.puts "Try 'tamoz --help'."
        USAGE_ERROR
      end

      def handle_fatal_error(error)
        @err.puts "tamoz: #{error.message}"
        1
      end

      def dispatch_subcommand(subcommand, options, argv)
        @policy.validate_check_config(options)
        @policy.validate_profile_usage(options, subcommand)

        case subcommand
        when "ask" then cmd_ask(options, argv)
        when "resume" then cmd_resume(options, argv)
        when "continue" then cmd_continue(options, argv)
        when "list" then cmd_list(options)
        when "show" then cmd_show(options, argv)
        when "follow-up", "follow_up", "followup" then cmd_follow_up(options, argv)
        when "redirect" then cmd_redirect(options, argv)
        when "cancel" then cmd_cancel(options, argv)
        when "resolve" then cmd_resolve(options, argv)
        when "profile" then cmd_profile(options, argv)
        when "init", "queue", "worker", "status", "schedule", "approve"
          # `--help` on a subcommand prints that subcommand's options and stops
          # there, without opening a runtime directory it was never asked to touch.
          catch(:tamoz_subcommand_help) do
            case subcommand
            when "init" then cmd_init(options, argv)
            when "queue" then cmd_queue(options, argv)
            when "worker" then cmd_worker(options, argv)
            when "status" then cmd_status(options, argv)
            when "schedule" then cmd_schedule(options, argv)
            when "approve" then cmd_approve(options, argv)
            end
          end
        else
          raise OptionParser::InvalidArgument, "unknown subcommand: #{subcommand}"
        end
      end

      def run_one_shot(options, argv)
        if options[:session]
          @policy.validate_profile_usage(options, "ask")
          options[:explicit_session] = options[:session]
          return cmd_ask(options, argv)
        end

        @policy.validate_profile_usage(options, "one-shot")
        @policy.validate_check_config(options)
        task = argv.join(" ").strip
        raise OptionParser::MissingArgument, "TASK" if task.empty?

        model = build_model(options)
        runtime = Tamoz::Agent.build(
          model:,
          root: options[:root],
          allow_changes: options[:allow_changes],
          checks: options[:checks],
          approval: method(:approve_one_shot)
        )
        result = runtime.run(task) { |event| render_runtime_event(event, json: options[:json]) }
        unless options[:json]
          @out.puts
          @out.puts result.answer
          @out.puts("\nVerification: #{result.satisfied ? "satisfied" : "not satisfied"}")
        end
        result.satisfied ? 0 : 2
      rescue Tamoz::Agent::ApprovalDeniedError
        @err.puts "tamoz: approval denied"
        1
      end

      def cmd_ask(options, argv)
        task = argv.join(" ").strip
        raise OptionParser::MissingArgument, "TASK" if task.empty?

        profile = load_operator_profile(options)
        thread_id = resolve_thread_id(options)
        # DR-5 RC1: the request id exists BEFORE authority resolution so a consumed
        # transition can be marked with the id that actually executes the turn.
        request_id = SecureRandom.uuid
        profile = resolve_session_authority(options, thread_id, profile, boundary: true, request_id:)
        run_durable(options, thread_id, profile:, request_id:) do |session, request_id, owner_id|
          drive_turn(session, task, thread_id:, request_id:, owner_id:, options:)
        end
      end

      def cmd_resume(options, argv)
        resume_options = parse_resume_options(argv)
        thread_id = extract_thread!(argv)
        profile = load_operator_profile(options)
        profile = resolve_session_authority(options, thread_id, profile, boundary: false)
        run_durable(options, thread_id, read_only: false, profile:) do |session, request_id, owner_id|
          session.verify_skill_binding!(thread: thread_id)
          drive_resume(session, thread_id:, request_id:, owner_id:, options:, resume_options:)
        end
      end

      def cmd_continue(options, argv)
        thread_id = extract_thread!(argv)
        profile = load_operator_profile(options)
        profile = resolve_session_authority(options, thread_id, profile, boundary: false)
        run_durable(options, thread_id, read_only: false, profile:) do |session, request_id, owner_id|
          session.verify_skill_binding!(thread: thread_id)
          drive_continue(session, thread_id:, request_id:, owner_id:, options:)
        end
      end

      def cmd_list(options)
        require "tamoz/sqlite"

        session_dir = resolve_session_dir(options)
        pattern = File.join(session_dir, "*.sqlite3")
        files = Dir.glob(pattern).sort
        if options[:json]
          threads = files.map { |path| list_entry(path, options) }.compact
          @out.puts JSON.generate("threads" => threads)
        else
          if files.empty?
            @out.puts "No sessions found."
            return 0
          end
          @out.puts "%-22s %-10s %-20s %s" % ["THREAD", "STATUS", "LAST_UPDATED", "SUMMARY"]
          files.each do |path|
            entry = list_entry(path, options)
            next unless entry

            @out.puts "%-22s %-10s %-20s %s" % [
              entry["thread_id"],
              entry["status"],
              Time.at(entry["updated_at_ms"] / 1000.0).strftime("%Y-%m-%d %H:%M"),
              entry["summary"]
            ]
          end
        end
        0
      rescue Tamoz::SQLite::Error, SQLite3::Exception => error
        @err.puts "tamoz: #{error.message}"
        1
      end

      def cmd_show(options, argv)
        transcript = 50
        OptionParser.new do |value|
          value.on("--transcript N", Integer, "Show last N records") { |entry| transcript = entry }
        end.parse!(argv)
        thread_id = extract_thread!(argv)

        run_durable(options, thread_id, read_only: true) do |session, _request_id, _owner_id|
          view = session.view(thread: thread_id)
          render_show(view, thread_id:, transcript:, json: options[:json])
          exit_for_view(view)
        end
      end

      def cmd_follow_up(options, argv)
        thread_id = extract_thread!(argv)
        task = argv.join(" ").strip
        raise OptionParser::MissingArgument, "TASK" if task.empty?

        profile = load_operator_profile(options)
        # DR-5 RC1: same request-id-before-authority rule as cmd_ask — a consumed
        # transition must be marked with the id of the ask that actually runs.
        request_id = SecureRandom.uuid
        profile = resolve_session_authority(options, thread_id, profile, boundary: true, request_id:)
        run_durable(options, thread_id, read_only: false, profile:, request_id:) do |session, request_id, owner_id|
          session.verify_skill_binding!(thread: thread_id)
          request = session.app.durable_runner.submit(
            {"task" => task},
            thread: thread_id,
            request_id:,
            operation: :turn,
            delivery: :queue
          )
          view = drain_to_terminal(session, thread_id:, owner_id:, options:, tracked_request: request)
          if tracked_request_queued?(session, request)
            emit_follow_up_queued(thread_id, request, view, options:)
            return EXIT_PAUSED
          end
          exit_for_view(view)
        end
      end

      def cmd_redirect(options, argv)
        thread_id = extract_thread!(argv)
        task = argv.join(" ").strip
        raise OptionParser::MissingArgument, "new task" if task.empty?

        profile = load_operator_profile(options)
        profile = resolve_session_authority(options, thread_id, profile, boundary: false)
        run_durable(options, thread_id, read_only: false, profile:) do |session, request_id, owner_id|
          session.verify_skill_binding!(thread: thread_id)
          session.app.durable_runner.submit(
            {"task" => task},
            thread: thread_id,
            request_id:,
            operation: :redirect,
            delivery: :redirect
          )
          view = drain_to_terminal(session, thread_id:, owner_id:, options:)
          exit_for_view(view)
        end
      end

      def cmd_cancel(options, argv)
        force = false
        OptionParser.new do |value|
          value.on("--force", "Cancel even if the thread is not active") { force = true }
        end.parse!(argv)
        thread_id = extract_thread!(argv)

        run_durable(options, thread_id, read_only: false) do |session, request_id, owner_id|
          view = session.view(thread: thread_id)
          unless %i[running paused].include?(view.status) || force
            raise ArgumentError,
                  "thread status is #{view.status}; use --force to cancel anyway"
          end

          session.app.durable_runner.submit(
            {"task" => {"cancel" => true, "reason" => "cancelled_by_user"}},
            thread: thread_id,
            request_id:,
            operation: :redirect,
            delivery: :redirect
          )
          view = drain_to_terminal(session, thread_id:, owner_id:, options:)
          reason = view.state&.fetch(:terminal_reason, nil)
          if reason == "cancelled_by_user"
            return exit_for_cancellation if @cancellation&.cancelled?

            return 0
          end

          exit_for_view(view)
        end
      end

      def cmd_resolve(options, argv)
        thread_id = extract_thread!(argv)
        effect_key = argv.shift
        status = argv.shift
        raise OptionParser::MissingArgument, "EFFECT_KEY" if effect_key.to_s.empty?
        raise OptionParser::MissingArgument, "STATUS" if status.to_s.empty?
        unless %w[succeeded abandoned unknown].include?(status)
          raise OptionParser::InvalidArgument,
                "status must be succeeded, abandoned, or unknown"
        end

        status_symbol = status == "unknown" ? :failed : status.to_sym
        run_durable(options, thread_id, read_only: false) do |session, _request_id, owner_id|
          session.resolve_effect(
            thread: thread_id,
            effect_key:,
            status: status_symbol,
            actor: "tamoz.cli",
            evidence: {"command" => "tamoz resolve", "status" => status},
            owner_id:
          )
          @out.puts "Resolved #{effect_key} as #{status}." unless options[:json]
          0
        end
      end

      def drive_turn(session, task, thread_id:, request_id:, owner_id:, options:)
        run_with_stream(session, thread_id:, request_id:, owner_id:, options:) do |context|
          session.start(task, thread: thread_id, request_id:, owner_id:, context:)
        end
        view = drain_to_terminal(session, thread_id:, owner_id:, options:)
        exit_for_view(view)
      end

      def drive_resume(session, thread_id:, request_id:, owner_id:, options:, resume_options:)
        view = session.view(thread: thread_id)

        case view.status
        when :paused
          answers = collect_answers_from_view(view, options:, resume_options:)
          return EXIT_PAUSED if answers.nil?

          run_with_stream(session, thread_id:, request_id:, owner_id:, options:) do |context|
            session.resume(answers, thread: thread_id, request_id:, owner_id:, context:)
          end
        when :running
          run_with_stream(session, thread_id:, request_id:, owner_id:, options:) do |context|
            session.continue(thread: thread_id, request_id:, owner_id:, context:)
          end
        when :blocked
          blocked = view.blocked || {}
          if options[:json]
            emit_cli_event("cli.paused", {"reason" => "blocked", "thread_id" => thread_id, "blocked" => blocked})
          else
            @err.puts "Thread is blocked on effect #{blocked.fetch("effect_key", "unknown")}."
            @err.puts "Resolve it with: tamoz resolve #{thread_id} EFFECT_KEY {succeeded|abandoned|unknown}"
          end
          return EXIT_PAUSED
        else
          render_show(view, thread_id:, transcript: 50, json: options[:json])
          return exit_for_view(view)
        end

        view = drain_to_terminal(session, thread_id:, owner_id:, options:, resume_options:)
        exit_for_view(view)
      end

      def drive_continue(session, thread_id:, request_id:, owner_id:, options:)
        run_with_stream(session, thread_id:, request_id:, owner_id:, options:) do |context|
          session.continue(thread: thread_id, request_id:, owner_id:, context:)
        end
        view = drain_to_terminal(session, thread_id:, owner_id:, options:)
        exit_for_view(view)
      end

      def drain_to_terminal(session, thread_id:, owner_id:, options:, tracked_request: nil, resume_options: {})
        loop do
          # A stale request ahead of the current work may already have been
          # terminal-failed by a `deliver` (session.resume/start/continue) rather
          # than by this loop's own run_next. Render any unrendered stale-failure
          # once per request id (DR-4 D3 / DR4-27).
          render_pending_stale_failures(session, thread_id:, options:)
          view = session.view(thread: thread_id)

          if tracked_request && tracked_request_queued?(session, tracked_request) &&
             %i[paused running].include?(view.status)
            emit_follow_up_queued(thread_id, tracked_request, view, options:)
            return session.view(thread: thread_id)
          end

          # Advance any queued request first (follow-up, redirect, cancel). A stale
          # request is terminal-failed by run_next; render its typed reason once and
          # keep draining — the failed request is terminal, so it is never re-claimed
          # and never re-resumed (DR-4 D3 / DR4-29).
          request_id = SecureRandom.uuid
          advanced = run_with_stream(session, thread_id:, request_id:, owner_id:, options:) do |context|
            session.app.durable_runner.run_next(thread: thread_id, owner_id:, context:)
          end
          if advanced
            render_request_terminal_failure(advanced, options:) if stale_request_failure?(advanced)
            next
          end

          view = session.view(thread: thread_id)
          case view.status
          when :paused
            return session.view(thread: thread_id) if view.interrupts.empty?

            answers = collect_answers(session, thread_id:, options:, resume_options:)
            return session.view(thread: thread_id) if answers.nil?

            request_id = SecureRandom.uuid
            run_with_stream(session, thread_id:, request_id:, owner_id:, options:) do |context|
              session.resume(answers, thread: thread_id, request_id:, owner_id:, context:)
            end
          when :running
            request_id = SecureRandom.uuid
            run_with_stream(session, thread_id:, request_id:, owner_id:, options:) do |context|
              session.continue(thread: thread_id, request_id:, owner_id:, context:)
            end
          else
            break
          end
        end

        view = session.view(thread: thread_id)
        render_final_view(view, options:)
        view
      end

      def tracked_request_queued?(session, tracked_request)
        current = session.app.durable_runner.fetch(
          thread: tracked_request.thread_id,
          request_id: tracked_request.request_id
        )
        current&.status == :queued
      end

      def emit_follow_up_queued(thread_id, tracked_request, view, options:)
        front_request_id = view.execution_id
        if options[:json]
          emit_cli_event("cli.paused", {
            "reason" => "queued",
            "thread_id" => thread_id,
            "behind_request_id" => front_request_id
          })
        else
          @err.puts "Follow-up queued behind request #{front_request_id} (status: #{view.status})."
          @err.puts "Run `tamoz resume #{thread_id}` to advance."
        end
      end

      # A run_next return is a stale-fail exactly when the request carries the typed
      # terminal payload DR-4 writes (graph_status failed + a reason). Ordinary run
      # failures carry no reason and are rendered by the stream/final-view path.
      def stale_request_failure?(request)
        request.status == :failed &&
          request.terminal_error.is_a?(Hash) &&
          request.terminal_error.fetch("graph_status", nil) == "failed" &&
          !request.terminal_error["reason"].to_s.empty?
      end

      def render_request_terminal_failure(request, options:)
        @rendered_stale_request_ids[request.request_id] = true
        reason = request.terminal_error.fetch("reason")
        if options[:json]
          emit_cli_event("cli.request_stale", {
            "thread_id" => request.thread_id,
            "request_id" => request.request_id,
            "operation" => request.operation.to_s,
            "reason" => reason
          })
        else
          @err.puts(
            "tamoz: stale #{request.operation} request #{request.request_id} " \
            "was not run: #{reason}"
          )
        end
      end

      # Render stale terminal-failures already recorded in the thread history (a
      # claim consumed by a `deliver` inside session.resume/start/continue never
      # surfaces through the drain loop's own run_next). Each request id is rendered
      # at most once per CLI process.
      def render_pending_stale_failures(session, thread_id:, options:)
        session.app.durable_runner.history(thread: thread_id).each do |request|
          next unless stale_request_failure?(request)
          next if @rendered_stale_request_ids.key?(request.request_id)

          render_request_terminal_failure(request, options:)
        end
      end

      def run_with_stream(session, thread_id:, request_id:, owner_id:, options:, cancellation: @cancellation)
        cancellation ||= Tamoz::CancellationToken.new
        sink = Tamoz::StreamSink.new(cancellation:, run_id: request_id)
        mode = options[:json] ? :all : [:tasks, :updates, :interrupts, :checkpoints, :errors]
        emitter = Tamoz::Graph::StreamEmitter.new(sink:, mode:)
        context = Tamoz::Context.new(
          run_id: request_id,
          execution_id: SecureRandom.uuid,
          request_id: request_id,
          thread_id: thread_id,
          cancellation: cancellation,
          emitter: emitter
        )
        prompts = []
        # `@stream_error` is deliberately not reset here: the drain loop calls
        # `run_with_stream` once more after the failing run (to confirm nothing is
        # queued), and that empty poll must not erase the reason the operator just saw.

        outcome = nil
        worker = Thread.new do
          begin
            outcome = yield context
          ensure
            sink.finish
          end
        end

        begin
          sink.each { |part| render_stream_part(part, options:, prompts:) }
        ensure
          sink.finish unless sink.finished?
          worker.join
        end

        if prompts.any? && !options[:json]
          prompts.each { |part| render_interrupt_prompt(part, session:, thread_id:) }
        end

        outcome
      end

      def render_stream_part(part, options:, prompts:)
        if options[:json]
          @out.puts JSON.generate("type" => part.type.to_s, "data" => part.data)
          return
        end

        case part.type
        when :custom
          render_runtime_event(
            Tamoz::Agent::Event.new(
              type: part.data["type"].to_sym,
              data: part.data.fetch("data", part.data)
            ),
            json: options[:json]
          )
        when :interrupt
          prompts << part
        when :error
          @stream_error = error_summary(part.data)
          @err.puts "Error: #{@stream_error}"
        end
      end

      # An `:error` stream part carries graph/node/task_id/error_class/category/
      # safe_message. It has never carried a "message" key, so reading one produced a
      # blank line. Fall through every key that can name the failure so the operator is
      # never told only that something went wrong.
      def error_summary(data)
        reason = data["safe_message"].to_s.strip
        reason = data["error_class"].to_s.strip if reason.empty?
        reason = "the session failed" if reason.empty?
        node = data["node"].to_s.strip
        node.empty? ? reason : "#{reason} (node #{node})"
      end

      def render_interrupt_prompt(part, session:, thread_id:)
        view = session.view(thread: thread_id)
        interrupt = view.interrupts.find do |candidate|
          candidate.task_id == part.data["task_id"] && candidate.call_index == part.data["call_index"]
        end
        return unless interrupt

        descriptor = interrupt.descriptor
        case descriptor["kind"]
        when "approve_tool"
          @err.puts "Approval required for #{descriptor["tool"]}:"
          @err.puts descriptor["preview"]
        when "clarify"
          @err.puts descriptor["question"]
        end
      end

      def collect_answers(session, thread_id:, options:, resume_options: {})
        view = session.view(thread: thread_id)
        collect_answers_from_view(view, options:, resume_options:)
      end

      def collect_answers_from_view(view, options:, resume_options:)
        answers = {}
        view.interrupts.each do |interrupt|
          value = answer_for(interrupt, options:, resume_options:)
          return nil if value.nil?

          answers[interrupt.task_id] ||= {}
          answers[interrupt.task_id][interrupt.call_index] = value
        end
        answers
      end

      def answer_for(interrupt, options:, resume_options:)
        descriptor = interrupt.descriptor
        if resume_options[:answer]
          return map_answer(descriptor["kind"], resume_options[:answer])
        end
        if options[:all] && options[:i_understand_approve_all] && descriptor["kind"] == "approve_tool"
          emit_cli_event("audit.approve_all", {
            "thread_id" => "unknown",
            "request_id" => "unknown",
            "count" => 1,
            "opt_in" => "i-understand-approve-all"
          }) if options[:json]
          return true
        end
        return nil if options[:non_interactive]

        prompt_for_interrupt(descriptor)
      end

      def prompt_for_interrupt(descriptor)
        case descriptor["kind"]
        when "approve_tool" then @prompts.approve_tool(descriptor)
        when "clarify" then @prompts.clarify(descriptor)
        else @prompts.interrupt(descriptor)
        end
      end

      def map_answer(kind, raw)
        answer = raw.to_s.strip.downcase
        case kind
        when "approve_tool"
          case answer
          when "y", "yes", "a", "approve" then true
          when "n", "no", "d", "deny" then false
          else
            raise ArgumentError, "invalid approve_tool answer: #{raw.inspect}"
          end
        when "clarify"
          answer.empty? ? nil : raw.to_s.strip
        when "resolve_effect"
          case answer
          when "fixed", "approve", "ok", "succeeded", "yes" then :succeeded
          when "skipped", "deny", "no", "abandoned" then :abandoned
          when "failed" then :failed
          when "unknown", "?" then :unknown
          else
            raise ArgumentError, "invalid resolve_effect answer: #{raw.inspect}"
          end
        else
          raw
        end
      end

      def render_final_view(view, options:)
        if options[:json]
          emit_cli_event("cli.session", {
            "thread_id" => view.thread_id,
            "request_id" => view.execution_id,
            "status" => view.status.to_s
          })
        else
          case view.status
          when :completed
            verification = view.state&.fetch(:verification, nil)
            if verification
              @out.puts verification.fetch("answer", "")
              @out.puts("\nVerification: #{verification.fetch("satisfied", false) ? "satisfied" : "not satisfied"}")
            end
          when :failed
            @err.puts(@stream_error ? "tamoz: session failed: #{@stream_error}" : "tamoz: session failed")
          when :blocked
            @err.puts "tamoz: session is blocked"
          end
        end
      end

      def exit_for_view(view)
        case view.status
        when :completed then view.terminal&.fetch("satisfied", false) ? 0 : 2
        when :paused then EXIT_PAUSED
        when :blocked then EXIT_PAUSED
        when :failed then 1
        else 1
        end
      end

      def exit_for_cancellation
        case @cancellation&.reason
        when "sigint" then EXIT_SIGINT
        when "sigterm" then EXIT_SIGTERM
        else 1
        end
      end

      def render_show(view, thread_id:, transcript:, json:)
        if json
          @out.puts JSON.generate(show_document(view, thread_id:, transcript:))
        else
          render_show_human(view, thread_id:, transcript:)
        end
      end

      def show_document(view, thread_id:, transcript:)
        receipts = view.effect_receipts.last(transcript).map(&:to_h)
        {
          "thread_id" => thread_id,
          "checkpoint_id" => view.checkpoint_id,
          "sequence" => view.sequence,
          "status" => view.status.to_s,
          "accepted_plan_digest" => view.accepted_plan&.fetch("plan_digest", nil),
          "interrupts" => view.interrupts.map { |i| {"task_id" => i.task_id, "call_index" => i.call_index, "descriptor" => i.descriptor} },
          "effect_receipts" => receipts,
          "terminal" => view.terminal
        }
      end

      def render_show_human(view, thread_id:, transcript:)
        @out.puts "Thread: #{thread_id}"
        @out.puts "Checkpoint: #{view.checkpoint_id} (sequence #{view.sequence})"
        @out.puts "Status: #{view.status}"
        if view.accepted_plan
          @out.puts "Accepted plan digest: #{view.accepted_plan.fetch("plan_digest", "unknown")}"
        end
        unless view.interrupts.empty?
          @out.puts "Pending interrupts:"
          view.interrupts.each do |interrupt|
            @out.puts "  - #{interrupt.descriptor["kind"]} #{interrupt.task_id}/#{interrupt.call_index}"
          end
        end
        receipts = view.effect_receipts.last(transcript)
        unless receipts.empty?
          @out.puts "Recent effect receipts:"
          receipts.each { |receipt| @out.puts "  - #{receipt.fetch("operation", "unknown")}" }
        end
        if view.terminal
          @out.puts "Terminal: #{view.terminal.fetch("reason", "unknown")} (satisfied: #{view.terminal.fetch("satisfied", false)})"
        end
      end

      def list_entry(path, options)
        thread_id = File.basename(path, ".sqlite3")
        return nil unless THREAD_ID_PATTERN.match?(thread_id)

        adapter = Tamoz::SQLite::Adapter.new(path:)
        begin
          session = build_list_session(adapter, options)
          snapshot = session.app.checkpointer.latest(thread_id:, namespace: [])
          return nil unless snapshot

          view = session.view(thread: thread_id)
          summary = view.state ? view.state[:task].to_s[0, 40] : ""

          {
            "thread_id" => thread_id,
            "status" => view.status.to_s,
            # No checkpoint value carries a wall-clock stamp, so the session
            # file's last write is the honest last-activity signal here.
            "updated_at_ms" => (File.mtime(path).to_f * 1000).round,
            "summary" => summary
          }
        ensure
          adapter.close
        end
      # Skip a file that is not a readable Tamoz thread. This rescue used to
      # catch StandardError, which hid a NoMethodError (`updated_at_ms` is not
      # a Checkpoint member) and made every `list` report nothing at all.
      rescue Tamoz::Error, SQLite3::Exception
        nil
      end

      def build_list_session(adapter, options)
        dummy_model = Object.new
        def dummy_model.generate(**) = "{}"
        toolbox = Tamoz::Agent::Toolbox.new(
          root: options[:root],
          allow_changes: options[:allow_changes],
          checks: options[:checks]
        )
        Tamoz::Agent::Session.new(model: dummy_model, toolbox:, checkpointer: adapter)
      end

      def run_durable(options, thread_id, read_only: false, profile: nil, request_id: nil)
        # Deferred: tamoz/agent must not load the adapter package at require time
        # (dependency isolation), only when a durable subcommand actually runs.
        require "tamoz/sqlite"

        session_dir = resolve_session_dir(options)
        FileUtils.mkdir_p(session_dir, mode: 0o700)
        stat = File.stat(session_dir)
        unless (stat.mode & 0o077).zero?
          raise ArgumentError, "session directory #{session_dir} is accessible to group or others"
        end

        model = build_model(options, profile:)
        toolbox = build_toolbox(options, profile:)
        adapter = Tamoz::SQLite::Adapter.new(
          path: File.join(session_dir, "#{thread_id}.sqlite3"),
          limits: Tamoz::SQLite::Limits.new(lease_ttl: lease_ttl)
        )
        begin
          # DR-5 D1 (RC5): the post-override resolution and the profile budgets are
          # computed HERE, in cli.rb, and folded into the session record at intake
          # via the extra constructor parameters — the same shared resolution
          # function build_model used, so the record never disagrees with the run.
          session = Tamoz::Agent::Session.new(
            model:,
            toolbox:,
            checkpointer: adapter,
            profile:,
            profile_roles: resolve_profile_roles(profile, options),
            profile_budgets: profile && profile.budgets
          )
          install_signal_handlers do
            yield session, request_id || SecureRandom.uuid, SecureRandom.uuid
          end
        ensure
          adapter.close unless read_only
        end
      end

      def build_toolbox(options, profile: nil)
        return build_profile_toolbox(profile) if profile

        Tamoz::Agent::Toolbox.new(
          root: options[:root],
          allow_changes: options[:allow_changes],
          checks: options[:checks]
        )
      end

      # §5.2: the profile is the capability authority; the toolbox is derived
      # from it wholesale so its catalog digest matches the pinned value.
      def build_profile_toolbox(profile)
        Tamoz::Agent::Toolbox.new(
          root: profile.canonical_root,
          allow_changes: profile.allow_changes?,
          checks: profile.checks.transform_values { |check| check.fetch("argv") },
          check_safeties: profile.checks.transform_values { |check| check.fetch("safety").to_sym },
          allowed_tools: profile.tools_allowed,
          approval_required: profile.tools_approval_required
        )
      end


      def install_signal_handlers
        @cancellation = Tamoz::CancellationToken.new
        old_int = Signal.trap("INT") { @cancellation.cancel!("sigint") }
        old_term = Signal.trap("TERM") { @cancellation.cancel!("sigterm") }
        yield
      ensure
        Signal.trap("INT", old_int) if old_int
        Signal.trap("TERM", old_term) if old_term
        @cancellation = nil
      end

      def resolve_thread_id(options)
        if options[:session]
          validate_thread_id!(options[:session])
          options[:session]
        elsif options[:explicit_session]
          validate_thread_id!(options[:explicit_session])
          options[:explicit_session]
        else
          generate_thread_id
        end
      end

      def extract_thread!(argv)
        thread_id = argv.shift
        raise OptionParser::MissingArgument, "THREAD" if thread_id.to_s.empty?

        validate_thread_id!(thread_id)
        thread_id
      end

      def validate_thread_id!(thread_id)
        return if THREAD_ID_PATTERN.match?(thread_id)

        raise ArgumentError, "invalid thread id: #{thread_id.inspect}"
      end

      def generate_thread_id
        "th_#{SecureRandom.urlsafe_base64(12)}"
      end

      def resolve_session_dir(options)
        return File.expand_path(options[:session_dir]) if options[:session_dir]
        return File.expand_path(@env["TAMOZ_SESSION_DIR"]) if @env["TAMOZ_SESSION_DIR"]

        if RUBY_PLATFORM.match?(/darwin/)
          File.expand_path("~/Library/Application Support/tamoz/sessions")
        else
          base = @env["XDG_STATE_HOME"] || File.expand_path("~/.local/state")
          File.join(base, "tamoz", "sessions")
        end
      end

      def parse_resume_options(argv)
        options = {}
        OptionParser.new do |value|
          value.on("--answer ANSWER", "Non-interactive answer") { |entry| options[:answer] = entry }
          value.on("--all", "Approve all pending interrupts") { options[:all] = true }
          value.on("--i-understand-approve-all", "Dangerous opt-in for --all") { options[:i_understand_approve_all] = true }
          value.on("--recover", "Force recovery before resuming") { options[:recover] = true }
        end.parse!(argv)
        options
      end

      # Operator override for the writer lease TTL. Automation that kills and
      # immediately resumes a session (crash-recovery harnesses) can shorten the
      # wait for a dead owner's lease to expire; the default stays conservative.
      def lease_ttl
        raw = @env["TAMOZ_LEASE_TTL"]
        return 30.0 if raw.to_s.empty?

        ttl = begin
          Float(raw)
        rescue ArgumentError, TypeError
          raise ArgumentError, "TAMOZ_LEASE_TTL must be a number of seconds within (0, 30]"
        end
        unless ttl.positive? && ttl <= 30.0
          raise ArgumentError, "TAMOZ_LEASE_TTL must be a number of seconds within (0, 30]"
        end

        ttl
      end

      # DR-5 D1: ONE shared resolution path for both `build_model` and the recorded
      # `profile_roles`. f(model_roles, overrides): per-role {provider:, model:}
      # POST-OVERRIDE tuples with build_model's exact precedence — a CLI/flag value
      # wins over TAMOZ_MODEL/TAMOZ_PROVIDER, which win over the role's file value
      # for the :primary role; every other role keeps its file value (build_model
      # only ever resolves :primary). The record therefore carries NO independent
      # data: it is exactly what build_model used. Changing one precedence rule
      # here changes both consumers.
      #
      # DR-5 RC6: an override value entering the durable field is gated by the
      # SAME secret predicates profiles validate against (SECRET_VALUE_PATTERNS /
      # ENTROPY_PATTERN with the entropy exemption list), so nothing
      # credential-shaped is ever recorded (invariant 24). The 40-char entropy
      # floor can false-positive a long env-supplied model id — stated as
      # acceptable, since a profile file cannot carry such a value; the refusal
      # names the role and the predicate.
      def resolve_profile_roles(profile, options)
        return {} unless profile

        overridden_model = options[:model] || @env["TAMOZ_MODEL"]
        overridden_provider = options[:provider] || @env["TAMOZ_PROVIDER"]
        profile.model_roles.each_with_object({}) do |(name, role), resolved|
          entry = {
            "provider" => String(role.fetch("provider")),
            "model" => String(role.fetch("model"))
          }
          if name == "primary"
            if overridden_model
              entry["model"] = String(overridden_model)
              reject_secret_shaped_override!(name, "model", overridden_model)
            end
            if overridden_provider
              entry["provider"] = String(overridden_provider)
              reject_secret_shaped_override!(name, "provider", overridden_provider)
            end
          end
          resolved[name] = entry
        end
      end

      def reject_secret_shaped_override!(role, field, value)
        if Profile::SECRET_VALUE_PATTERNS.any? { |pattern| pattern.match?(value) }
          raise ProfilePolicyError,
                "override for profile role #{role.inspect} field #{field.inspect} " \
                "matches the embedded-secret pattern and cannot be recorded in profile_roles"
        end
        if Profile::ENTROPY_PATTERN.match?(value) &&
           !Profile::ENTROPY_EXEMPT_KEYS.include?(field)
          raise ProfilePolicyError,
                "override for profile role #{role.inspect} field #{field.inspect} is a " \
                "40+ character high-entropy value (candidate secret). Pin an explicit " \
                "identifier with --model/--provider if this value is a legitimate model id."
        end
      end

      def build_model(options, profile: nil)
        return @model_factory.call(options) if @model_factory

        # §5.3 precedence: CLI/flag > TAMOZ_MODEL/TAMOZ_PROVIDER > role. The role
        # side comes from the shared resolution function, so the model that runs
        # and the profile_roles record are computed by the same code (DR-5 D1).
        model_name = options[:model] || @env["TAMOZ_MODEL"]
        provider = options[:provider] || @env["TAMOZ_PROVIDER"]
        primary = resolve_profile_roles(profile, options)["primary"]
        model_name ||= primary && primary.fetch("model")
        provider ||= primary && primary.fetch("provider")
        api_key = nil
        role = profile && profile.model_roles["primary"]
        if role
          ref = role["credential_ref"]
          if ref
            api_key = @env[ref.fetch("name")]
            # DR-5 critic: a referenced credential that is not set must fail
            # TYPED at session start — never silently fall back to the generic
            # provider key (the divergence class RC-4 fixes at replay must not
            # be re-introduced at resolution). The existing rescue below stays
            # as the backstop for other constructor failures.
            if api_key.to_s.empty?
              raise ProfileRoleUnavailableError,
                    "profile role \"primary\" references credential " \
                    "#{ref.fetch("name").inspect} which is not set in the environment"
            end
          end
        end
        raise OptionParser::MissingArgument, "--model or TAMOZ_MODEL" if model_name.to_s.empty?

        provider = provider.to_s.empty? ? "openai" : provider
        if provider == "assume_model_exists"
          # §5.3: custom endpoints are out of scope for P8 v1.
          raise Profile::ValidationError,
                "profile model role provider \"assume_model_exists\" requires a custom " \
                "endpoint, which P8 v1 does not support"
        end
        provider_key = RubyLLMModel::ENV_KEYS[provider.downcase.to_sym]
        api_key ||= provider_key && @env[provider_key]
        api_base = @env["#{provider.upcase}_API_BASE"]
        begin
          RubyLLMModel.new(
            model: model_name,
            provider:,
            api_key:,
            api_base:,
            assume_model_exists: options[:assume_model_exists]
          )
        rescue ArgumentError => error
          # DR-5 D1: a role that references a credential name absent from the
          # environment surfaces as the typed ProfileRoleUnavailableError at
          # session start (before any model I/O or checkpoint), naming the role
          # and the failing reference — never a leaked untyped ArgumentError.
          if role && role["credential_ref"]
            raise ProfileRoleUnavailableError,
                  "profile role \"primary\" cannot resolve credential reference " \
                  "#{role.fetch("credential_ref").fetch("name").inspect}: #{error.message}"
          end

          raise
        end
      end

      def render_runtime_event(event, json:)
        if json
          @out.puts JSON.generate("type" => event.type.to_s, "data" => event.data)
          return
        end

        case event.type
        when :plan_drafted
          @out.puts "Plan #{event.data.fetch("attempt")} (#{event.data.fetch("phase")}):"
          event.data.fetch("plan").fetch("steps").each do |step|
            tool = step.fetch("tool") ? " [#{step.fetch("tool")}]" : ""
            @out.puts "  - #{step.fetch("purpose")}#{tool}"
          end
        when :plan_reviewed
          @out.puts "Review (#{event.data.fetch("layer")}): #{event.data.fetch("decision")}"
        when :tool_started
          @out.puts "Running #{event.data.fetch("tool")}..."
        when :approval_requested
          @out.puts "Approval required for #{event.data.fetch("tool")}:"
          @out.puts event.data.fetch("preview")
        end
      end

      def approve_one_shot(tool:, arguments:, preview:)
        @err.print "Approve #{tool}? [y/N] "
        @err.flush
        answer = @input.gets
        answer && %w[y yes].include?(answer.strip.downcase)
      end

      def emit_cli_event(type, data)
        @out.puts JSON.generate("type" => type, "data" => data)
      end
    end
  end
end
