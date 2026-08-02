# frozen_string_literal: true

require "json"
require "optparse"
require "shellwords"
require "securerandom"
require "fileutils"

module Tamoz
  module Agent
    class CLI
      USAGE_ERROR = 64
      EXIT_PAUSED = 3
      EXIT_SIGINT = 130
      EXIT_SIGTERM = 143

      SUBCOMMANDS = %w[
        ask resume continue list show follow-up follow_up followup
        redirect cancel resolve profile
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
      end

      def run(argv)
        options, subcommand, sub_argv = parse(argv)
        return 0 if options[:terminal]

        if subcommand
          dispatch_subcommand(subcommand, options, sub_argv)
        else
          run_one_shot(options, sub_argv)
        end
      rescue OptionParser::ParseError, ArgumentError => error
        @err.puts "tamoz: #{error.message}"
        @err.puts "Try 'tamoz --help'."
        USAGE_ERROR
      rescue Tamoz::Agent::Error => error
        @err.puts "tamoz: #{error.message}"
        1
      rescue Tamoz::CheckpointConflictError => error
        @err.puts "tamoz: #{error.message}"
        1
      end

      private

      def parse(argv)
        options = {
          root: Dir.pwd,
          json: false,
          assume_model_exists: false,
          allow_changes: false,
          non_interactive: false,
          checks: {}
        }
        parser = OptionParser.new do |value|
          value.banner = <<~BANNER
            Usage: tamoz [global-options] [subcommand] [options] [ARGS]
                   tamoz [options] TASK

            Subcommands: ask, resume, continue, list, show, follow-up, redirect, cancel, resolve, profile
          BANNER
          value.on("--profile PROFILE", "Trusted profile path or id (durable sessions)") do |entry|
            options[:profile] = entry
          end
          value.on("--model MODEL", "RubyLLM model identifier") { |entry| options[:model] = entry }
          value.on("--provider PROVIDER", "RubyLLM provider (default: openai)") do |entry|
            options[:provider] = entry
          end
          value.on("--root PATH", "Workspace root (default: current directory)") do |entry|
            options[:root] = entry
          end
          value.on("--session-dir PATH", "Durable session directory") do |entry|
            options[:session_dir] = entry
          end
          value.on("--session NAME", "Thread name (default: generated)") do |entry|
            options[:session] = entry
          end
          value.on("--allow-changes", "Enable reviewed and approved workspace changes") do
            options[:allow_changes] = true
          end
          value.on("--check NAME=COMMAND", "Configure a named verification command") do |entry|
            name, command = entry.split("=", 2)
            if name.to_s.empty? || command.to_s.empty?
              raise OptionParser::InvalidArgument, "check must be NAME=COMMAND"
            end
            check_argv = Shellwords.split(command)
            raise OptionParser::InvalidArgument, "check command must not be empty" if check_argv.empty?
            if options[:checks].key?(name)
              raise OptionParser::InvalidArgument, "duplicate check #{name.inspect}"
            end

            options[:checks][name] = check_argv
          end
          value.on("--assume-model-exists", "Allow an unlisted model at a custom endpoint") do
            options[:assume_model_exists] = true
          end
          value.on("--json", "Emit newline-delimited JSON events") { options[:json] = true }
          value.on("--non-interactive", "Fail instead of prompting") { options[:non_interactive] = true }
          value.on("--version", "Print the Tamoz version") do
            @out.puts Tamoz::Agent::VERSION
            options[:terminal] = true
          end
          value.on("-h", "--help", "Show this help") do
            @out.puts value
            options[:terminal] = true
          end
        end
        parser.order!(argv)

        subcommand = SUBCOMMANDS.include?(argv.first) ? argv.shift : nil
        [options, subcommand, argv]
      end

      def dispatch_subcommand(subcommand, options, argv)
        validate_check_config!(options)
        validate_profile_usage!(options, subcommand)

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
        else
          raise OptionParser::InvalidArgument, "unknown subcommand: #{subcommand}"
        end
      end

      # A profile is session authority: it only makes sense on the durable,
      # profile-aware commands, and it replaces the flag-driven capability
      # surface, so combining it with --allow-changes/--check is an error.
      def validate_profile_usage!(options, subcommand)
        return unless options[:profile]

        unless %w[ask resume continue follow-up follow_up followup redirect].include?(subcommand)
          raise OptionParser::InvalidArgument,
                "--profile is not supported for #{subcommand}"
        end
        if options[:allow_changes] || !options[:checks].empty?
          raise OptionParser::InvalidArgument,
                "--profile sets the capability surface; do not combine it with " \
                "--allow-changes or --check"
        end
      end

      def run_one_shot(options, argv)
        if options[:session]
          validate_profile_usage!(options, "ask")
          options[:explicit_session] = options[:session]
          return cmd_ask(options, argv)
        end

        validate_profile_usage!(options, "one-shot")
        validate_check_config!(options)
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
        run_durable(options, thread_id, profile:) do |session, request_id, owner_id|
          drive_turn(session, task, thread_id:, request_id:, owner_id:, options:)
        end
      end

      def cmd_resume(options, argv)
        resume_options = parse_resume_options(argv)
        thread_id = extract_thread!(argv)
        profile = load_operator_profile(options)
        run_durable(options, thread_id, read_only: false, profile:) do |session, request_id, owner_id|
          guard_profile_resume!(session, thread_id, profile)
          session.verify_skill_binding!(thread: thread_id)
          drive_resume(session, thread_id:, request_id:, owner_id:, options:, resume_options:)
        end
      end

      def cmd_continue(options, argv)
        thread_id = extract_thread!(argv)
        profile = load_operator_profile(options)
        run_durable(options, thread_id, read_only: false, profile:) do |session, request_id, owner_id|
          guard_profile_resume!(session, thread_id, profile)
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
        run_durable(options, thread_id, read_only: false, profile:) do |session, request_id, owner_id|
          guard_profile_resume!(session, thread_id, profile)
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
        run_durable(options, thread_id, read_only: false, profile:) do |session, request_id, owner_id|
          guard_profile_resume!(session, thread_id, profile)
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
          view = session.view(thread: thread_id)

          if tracked_request && tracked_request_queued?(session, tracked_request) &&
             %i[paused running].include?(view.status)
            emit_follow_up_queued(thread_id, tracked_request, view, options:)
            return session.view(thread: thread_id)
          end

          # Advance any queued request first (follow-up, redirect, cancel).
          request_id = SecureRandom.uuid
          advanced = run_with_stream(session, thread_id:, request_id:, owner_id:, options:) do |context|
            session.app.durable_runner.run_next(thread: thread_id, owner_id:, context:)
          end
          next if advanced

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
          @err.puts "Error: #{part.data["message"]}"
        end
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
        when "approve_tool"
          prompt_approve_tool(descriptor)
        when "clarify"
          prompt_clarify(descriptor)
        else
          @err.puts "Interrupt: #{descriptor["kind"]}"
          @err.print "Answer: "
          @err.flush
          line = @input.gets
          line.nil? ? nil : line.strip
        end
      end

      def prompt_approve_tool(descriptor)
        @err.puts "Approval required for #{descriptor["tool"]}:"
        @err.puts descriptor["preview"]
        loop do
          @err.print "Approve #{descriptor["tool"]}? [y/N/?] "
          @err.flush
          line = @input.gets
          return nil if line.nil?

          answer = line.strip.downcase
          case answer
          when "y", "yes", "a", "approve" then return true
          when "n", "no", "d", "deny" then return false
          when "?", "h", "help"
            @err.puts "y/yes/a/approve: approve the operation"
            @err.puts "n/no/d/deny: deny the operation"
          else
            @err.puts "Invalid answer. Enter y/yes, n/no, a/approve, d/deny, or ? for help."
          end
        end
      end

      def prompt_clarify(descriptor)
        @err.puts descriptor["question"]
        loop do
          @err.print "Answer: "
          @err.flush
          line = @input.gets
          return nil if line.nil?

          answer = line.strip
          return answer unless answer.empty?

          @err.puts "Answer must be non-empty."
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
            @err.puts "tamoz: session failed"
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

          if options[:json]
            {
              "thread_id" => thread_id,
              "status" => view.status.to_s,
              "updated_at_ms" => snapshot.updated_at_ms,
              "summary" => summary
            }
          else
            {
              "thread_id" => thread_id,
              "status" => view.status.to_s,
              "updated_at_ms" => snapshot.updated_at_ms,
              "summary" => summary
            }
          end
        ensure
          adapter.close
        end
      rescue StandardError
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

      def run_durable(options, thread_id, read_only: false, profile: nil)
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
          session = Tamoz::Agent::Session.new(model:, toolbox:, checkpointer: adapter, profile:)
          install_signal_handlers do
            yield session, SecureRandom.uuid, SecureRandom.uuid
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

      def load_operator_profile(options)
        return nil unless options[:profile]

        path = Profile.resolve_path(profile: options[:profile], env: @env)
        Profile.load(path, env: @env, confirm_adoption: adoption_confirmation(options))
      end

      def adoption_confirmation(options)
        lambda do |document|
          if options[:non_interactive]
            raise Profile::AdoptionError,
                  "profile #{document.profile_id} digest #{document.canonical_digest} requires " \
                  "operator adoption; run 'tamoz profile import' or activate it interactively"
          end

          @err.puts "Profile #{document.profile_id} is not activated."
          @err.puts "  digest: #{document.canonical_digest}"
          @err.puts "  canonical_root: #{document.canonical_root}"
          @err.print "Activate this exact profile digest? [y/N] "
          @err.flush
          answer = @input.gets
          !!(answer && %w[y yes].include?(answer.strip.downcase))
        end
      end

      # §5.5: resume under a profile must never silently rebind authority. A
      # legacy session predates profiles; a different profile id or a changed
      # digest blocks mutation until an explicit transition exists.
      def guard_profile_resume!(session, thread_id, profile)
        return unless profile

        view = begin
          session.view(thread: thread_id)
        rescue Tamoz::Agent::Error
          return
        end
        record = view.state && view.state[:session]
        return unless record

        stored_id = record.fetch("profile_id")
        if stored_id == SessionRecords::LEGACY_PROFILE_ID
          raise Profile::AdoptionError,
                "session #{thread_id} predates trusted profiles; resume it without --profile"
        end
        unless stored_id == profile.profile_id
          raise Profile::AdoptionError,
                "session #{thread_id} belongs to profile #{stored_id.inspect}, not " \
                "#{profile.profile_id.inspect}; inspect it with 'tamoz show' instead"
        end

        stored_digest = record.fetch("profile_digest")
        return if stored_digest == profile.canonical_digest

        raise Profile::AdoptionError,
              "Session was created with profile #{stored_id} digest #{stored_digest}; " \
              "current profile digest is #{profile.canonical_digest}. Run 'tamoz profile " \
              "activate --thread #{thread_id} --digest #{stored_digest}' or resume with --read-only."
      end

      def cmd_profile(options, argv)
        action = argv.shift
        case action
        when "preview" then profile_preview(argv)
        when "list" then profile_list(options)
        when "show" then profile_show(argv)
        when "import" then profile_import(options, argv)
        else
          raise OptionParser::InvalidArgument, "unknown profile action: #{action.inspect}"
        end
      end

      def profile_preview(argv)
        path = argv.shift
        raise OptionParser::MissingArgument, "PATH" if path.to_s.empty?

        expanded = File.expand_path(File.path(path))
        document = Profile.preview(expanded, suggestion: Profile.suggestion_path?(expanded))
        render_profile(document)
        document.suggestion ? 3 : 0
      end

      def profile_list(options)
        directory = Profile.profiles_dir(env: @env)
        entries = Dir.glob(File.join(directory, "*.yaml")).sort.filter_map do |path|
          document = Profile.preview(path)
          [File.basename(path, ".yaml"), document]
        rescue Profile::ProfileError
          nil
        end
        if options[:json]
          @out.puts JSON.generate(
            entries.map do |name, document|
              {"file" => name, "profile_id" => document.profile_id,
               "profile_version" => document.profile_version,
               "canonical_digest" => document.canonical_digest}
            end
          )
        else
          entries.each do |name, document|
            @out.puts "#{name}: #{document.profile_id} #{document.profile_version} #{document.canonical_digest}"
          end
        end
        0
      end

      def profile_show(argv)
        id = argv.shift
        raise OptionParser::MissingArgument, "PROFILE_ID" if id.to_s.empty?

        path = Profile.resolve_path(profile: id, env: @env)
        render_profile(Profile.preview(path))
        0
      end

      def profile_import(options, argv)
        force = false
        OptionParser.new do |value|
          value.on("--force", "Overwrite an existing profile with the same id") { force = true }
        end.parse!(argv)
        source = argv.shift
        raise OptionParser::MissingArgument, "PATH" if source.to_s.empty?

        expanded = File.expand_path(File.path(source))
        document = Profile.preview(expanded, suggestion: Profile.suggestion_path?(expanded))
        directory = Profile.profiles_dir(env: @env)
        target = File.join(directory, "#{document.profile_id}.yaml")
        if File.exist?(target) && !force
          raise Profile::AdoptionError,
                "#{target} already exists; use --force and confirm to replace it"
        end
        unless force
          if options[:non_interactive]
            raise Profile::AdoptionError,
                  "import requires operator confirmation; re-run interactively or pass --force"
          end

          @err.puts "Import #{document.profile_id} digest #{document.canonical_digest}"
          @err.puts "  from: #{expanded}"
          @err.puts "  to:   #{target}"
          @err.print "Install and activate this exact profile? [y/N] "
          @err.flush
          answer = @input.gets
          unless answer && %w[y yes].include?(answer.strip.downcase)
            raise Profile::AdoptionError, "import not confirmed"
          end
        end

        FileUtils.mkdir_p(directory, mode: 0o700)
        File.chmod(0o700, directory)
        bytes = File.binread(expanded)
        File.write(target, bytes)
        File.chmod(0o600, target)
        Profile::AdoptionRegistry.new(env: @env).activate(
          document.profile_id, document.canonical_digest
        )
        @out.puts "Imported #{document.profile_id} (#{document.canonical_digest})"
        0
      end

      def render_profile(document)
        @out.puts "profile_id: #{document.profile_id}"
        @out.puts "profile_version: #{document.profile_version}"
        @out.puts "canonical_root: #{document.canonical_root}"
        @out.puts "canonical_digest: #{document.canonical_digest}"
        @out.puts "allow_changes: #{document.allow_changes?}"
        @out.puts "tools.allowed: #{document.tools_allowed.join(", ")}"
        @out.puts "tools.approval_required: #{document.tools_approval_required.join(", ")}"
        @out.puts "high_risk: #{document.high_risk?}"
        @out.puts "suggestion: #{document.suggestion}"
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

      def validate_check_config!(options)
        if !options[:allow_changes] && !options[:checks].empty?
          raise OptionParser::InvalidArgument, "--check requires --allow-changes"
        end
      end

      def build_model(options, profile: nil)
        return @model_factory.call(options) if @model_factory

        model_name = options[:model] || @env["TAMOZ_MODEL"]
        provider = options[:provider] || @env["TAMOZ_PROVIDER"]
        api_key = nil
        role = profile && profile.model_roles["primary"]
        if role
          # §5.3: the symbolic :primary role resolves through the profile when
          # the operator has not pinned a model on the command line.
          model_name ||= role.fetch("model")
          provider ||= role.fetch("provider")
          ref = role["credential_ref"]
          api_key = @env[ref.fetch("name")] if ref
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
        RubyLLMModel.new(
          model: model_name,
          provider:,
          api_key:,
          api_base:,
          assume_model_exists: options[:assume_model_exists]
        )
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
