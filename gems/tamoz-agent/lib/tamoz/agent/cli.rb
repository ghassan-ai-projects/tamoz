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
      include CLISessionCommands
      include CLIAuthority
      include CLIRendering
      include CLICommsCommands
      include CLICommsDoctor
      include CLICommsOps

      # Every subcommand dispatches to exactly one same-shaped cmd_* method
      # (three spellings share follow_up); `list` alone takes no argv.
      SUBCOMMAND_HANDLERS = {
        "ask" => :cmd_ask,
        "resume" => :cmd_resume,
        "continue" => :cmd_continue,
        "list" => :cmd_list,
        "show" => :cmd_show,
        "follow-up" => :cmd_follow_up,
        "follow_up" => :cmd_follow_up,
        "followup" => :cmd_follow_up,
        "redirect" => :cmd_redirect,
        "cancel" => :cmd_cancel,
        "resolve" => :cmd_resolve,
        "profile" => :cmd_profile,
        "comms" => :cmd_comms,
        "config" => :cmd_config,
        "init" => :cmd_init,
        "queue" => :cmd_queue,
        "worker" => :cmd_worker,
        "status" => :cmd_status,
        "schedule" => :cmd_schedule,
        "approve" => :cmd_approve,
        "observe" => :cmd_observe,
        "trace" => :cmd_trace
      }.freeze

      SUBCOMMANDS = SUBCOMMAND_HANDLERS.keys.freeze

      SINGLE_ARG_SUBCOMMANDS = %w[list].freeze

      # `--help` on any of these subcommands prints that subcommand's options
      # and stops there, without opening a runtime directory it was never
      # asked to touch.
      NEEDS_HELP_CATCH = %w[
        comms config init queue worker status schedule approve observe trace
      ].freeze

      THREAD_ID_PATTERN = /\A[A-Za-z0-9_\-\.]{1,64}\z/.freeze

      def self.run(argv = ARGV, out: $stdout, err: $stderr, input: $stdin, env: ENV, model_factory: nil,
                   comms_client_factory: nil)
        new(out:, err:, input:, env:, model_factory:, comms_client_factory:).run(argv)
      end

      def initialize(out:, err:, input:, env:, model_factory: nil, comms_client_factory: nil)
        @out = out
        @err = err
        @input = input
        @env = env
        @cancellation = nil
        @model_factory = model_factory
        @comms_client_factory = comms_client_factory
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

        handler = SUBCOMMAND_HANDLERS.fetch(subcommand) do
          raise OptionParser::InvalidArgument, "unknown subcommand: #{subcommand}"
        end
        arguments = SINGLE_ARG_SUBCOMMANDS.include?(subcommand) ? [options] : [options, argv]

        return catch(:tamoz_subcommand_help) { __send__(handler, *arguments) } if NEEDS_HELP_CATCH.include?(subcommand)

        __send__(handler, *arguments)
      end

      def run_one_shot(options, argv)
        raise ArgumentError, "--adaptive-routing requires --session" if options[:adaptive_routing]

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
          approval: method(:approve_one_shot),
          routing: if options[:experimental_routing]
                     :experimental
                   elsif options[:shadow_routing]
                     :shadow
                   else
                     :legacy
                   end
        )
        result = runtime.run(task) { |event| render_runtime_event(event, json: options[:json]) }
        unless options[:json]
          @out.puts
          @out.puts result.answer
          label = if result.responded?
                    "Response: not verified task completion"
                  else
                    "Verification: #{result.satisfied ? "satisfied" : "not satisfied"}"
                  end
          @out.puts("\n#{label}")
        end
        result.exit_status
      rescue Tamoz::Agent::ApprovalDeniedError
        @err.puts "tamoz: approval denied"
        1
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
            @err.puts "Resolve it with: tamoz resolve #{thread_id} EFFECT_KEY {succeeded|failed|abandoned}"
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

          resolve_interrupt_decision(interrupt, value)
          answers[interrupt.task_id] ||= {}
          answers[interrupt.task_id][interrupt.call_index] = value
        end
        answers
      end

      # The interactive operator is a resolution channel like any other — when
      # this process's engine holds the decision (it made the ask). A decision
      # recorded by another process resolves there; the resume only answers the
      # interrupt.
      def resolve_interrupt_decision(interrupt, value)
        descriptor = interrupt.descriptor
        return unless descriptor['kind'] == 'approve_tool'
        asked = descriptor['decision']
        return unless @approval_engine && asked

        decision_id = asked.fetch('id')
        return unless @approval_engine.decision_log.lookup(decision_id)

        scope = :once
        if value && Array(asked['grant_scopes']).include?('session') && @prompts.remember_for_session(descriptor)
          scope = :session
        end
        @approval_engine.resolve(decision_id:, answer: value ? :approve : :deny, scope:)
      end

      def answer_for(interrupt, options:, resume_options:)
        descriptor = interrupt.descriptor
        return map_answer(descriptor["kind"], resume_options[:answer]) if resume_options[:answer]
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
          parsed = Tamoz::Approval::Answer.parse(answer)
          raise ArgumentError, "invalid approve_tool answer: #{raw.inspect}" if parsed.nil?

          parsed == :approve
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
        mcp = nil
        begin
          mcp = build_mcp_source(options, profile:)
          # DR-5 D1 (RC5): the post-override resolution and the profile budgets are
          # computed HERE, in cli.rb, and folded into the session record at intake
          # via the extra constructor parameters — the same shared resolution
          # function build_model used, so the record never disagrees with the run.
          # Interactive default gates mutations behind a confirm: the
          # operator opts into autonomy by naming a looser profile.
          @approval_engine = Tamoz::Agent.build_approval_engine(profile_name: options[:approval_profile] || 'review')
          @approval_engine.bind_session('interactive')
          session = Tamoz::Agent::Session.new(
            model:,
            toolbox:,
            checkpointer: adapter,
            profile:,
            approval_engine: @approval_engine,
            approval_session_id: 'interactive',
            profile_roles: resolve_profile_roles(profile, options),
            profile_budgets: profile && profile.budgets,
            mcp:,
            artifact_store: adapter.bind_artifact_store(tenant: "session:#{thread_id}"),
            artifact_tenant: "session:#{thread_id}",
            routing: if options[:adaptive_routing]
                       :adaptive
                     else
                       (options[:experimental_routing] ? :experimental : :legacy)
                     end
          )
          install_signal_handlers do
            yield session, request_id || SecureRandom.uuid, SecureRandom.uuid
          end
        ensure
          mcp&.close
          adapter.close unless read_only
        end
      end

      def build_mcp_source(options, profile: nil)
        runtime_path = options[:runtime_dir] || @env["TAMOZ_RUNTIME_DIR"]
        return nil unless runtime_path

        directory = RuntimeDirectory.resolve(path: runtime_path, env: @env)
        expected_root = profile ? profile.canonical_root : options[:root]
        unless File.expand_path(directory.workspace_root) == File.expand_path(expected_root)
          raise ArgumentError,
                "runtime workspace #{directory.workspace_root.inspect} does not match " \
                "the CLI workspace #{expected_root.inspect}"
        end

        McpSourceBuilder.new(directory).build
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
          allowed_tools: profile.tools_allowed
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
          value.on("--recover", "Force recovery before resuming") { options[:recover] = true }
          value.on("--approval-profile NAME", "Approval policy profile for this session") { |entry| options[:approval_profile] = entry }
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
        when :task_started
          @err.puts "Working..."
        when :route_selected
          @err.puts "Route: #{event.data.fetch("route")}"
        when :route_fallback
          @err.puts "Route fallback: continuing with the standard workflow."
        when :route_shadow
          @err.puts "Route shadow: #{event.data.fetch("route")} (standard workflow retained)"
        when :plan_drafted
          @err.puts "Plan #{event.data.fetch("attempt")} (#{event.data.fetch("phase")}):"
          event.data.fetch("plan").fetch("steps").each do |step|
            tool = step.fetch("tool") ? " [#{step.fetch("tool")}]" : ""
            @err.puts "  - #{step.fetch("purpose")}#{tool}"
          end
        when :plan_reviewed
          @err.puts "Review (#{event.data.fetch("layer")}): #{event.data.fetch("decision")}"
        when :tool_started
          @err.puts "Running #{event.data.fetch("tool")}..."
        when :approval_requested
          @err.puts "Approval required for #{event.data.fetch("tool")}:"
          @err.puts event.data.fetch("preview")
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
