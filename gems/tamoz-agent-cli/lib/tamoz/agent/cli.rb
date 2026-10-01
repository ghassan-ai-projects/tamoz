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
      EXIT_SIGINT = Tamoz::Cancellation::Trap::EXIT_CODES.fetch("sigint")
      EXIT_SIGTERM = Tamoz::Cancellation::Trap::EXIT_CODES.fetch("sigterm")

      # The unattended surface (`init`, `queue`, `worker`, `status`) lives in its
      # own file; it is the same CLI object, split only so neither half becomes
      # unreadable.
      include CLIWorkerCommands
      include CLIProbeCommands
      include CLISkillsCommands
      include CLIMemoryCommands
      include CLIImprovementCommands
      include CLIScheduleCommands
      include CLIProfileCommands
      include CLISessionCommands
      include CLIAuthority
      include CLIRendering
      include CLICommsCommands
      include CLICommsDoctor
      include CLICommsOps
      include CLITelegramCommands

      # Every subcommand dispatches to exactly one same-shaped cmd_* method
      # (three spellings share follow_up); `list` alone takes no argv.
      SUBCOMMAND_HANDLERS = {
        "ask" => :cmd_ask,
        "code" => :cmd_code,
        "investigate" => :cmd_investigate,
        "deep-research" => :cmd_deep_research,
        "probes" => :cmd_probes,
        "skills" => :cmd_skills,
        "memory" => :cmd_memory,
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
        "reset" => :cmd_reset,
        "compact" => :cmd_compact,
        "usage" => :cmd_usage,
        "context" => :cmd_context,
        "think" => :cmd_think,
        "verbose" => :cmd_verbose,
        "profile" => :cmd_profile,
        "comms" => :cmd_comms,
        "telegram" => :cmd_telegram,
        "config" => :cmd_config,
        "init" => :cmd_init,
        "queue" => :cmd_queue,
        "worker" => :cmd_worker,
        "improve" => :cmd_improve,
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
        comms telegram config init queue worker status schedule approve observe trace
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
        @prompts = PromptAdapter.new(input:, err:)
        @events = EventRenderer.new(out:, err:)
        @models = ModelBuilder.new(env:, factory: model_factory)
        @sessions = SessionBuilder.new(env:, models: @models)
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
      # P0-D: the parse helpers moved to tamoz-core, re-parenting ProtocolError
      # from Agent::Error to a sibling of it (`Tamoz::Error`). Catch explicitly,
      # same rule as the ToolError family above.
      rescue Tamoz::Core::ProtocolError => error
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
        raise ArgumentError, "--work-routing needs a durable session; use tamoz code" if options[:work_routing]

        if options[:session]
          @policy.validate_profile_usage(options, "ask")
          options[:explicit_session] = options[:session]
          return cmd_ask(options, argv)
        end

        @policy.validate_profile_usage(options, "one-shot")
        @policy.validate_check_config(options)
        task = argv.join(" ").strip
        raise OptionParser::MissingArgument, "TASK" if task.empty?

        OneShot.new(out: @out, err: @err, input: @input, events: @events, models: @models).run(task, options)
      end

      def turn_driver(session, thread_id:, owner_id:, options:)
        operator = Operator.new(out: @out, err: @err, events: @events, prompts: @prompts,
                                approvals: @approval_engine, cancellation: @cancellation)
        TurnDriver.new(session, thread_id:, owner_id:, options:, operator:)
      end

      def run_durable(options, thread_id, read_only: false, profile: nil, request_id: nil)
        @sessions.assemble(options, thread_id, read_only:, profile:,
                                               openers: run_openers(options, thread_id)) do |parts, session|
          @approval_engine = parts.approvals
          install_signal_handlers { yield session, request_id || SecureRandom.uuid, SecureRandom.uuid }
        end
      end

      # Both openers are lazy: the work harness pins into the session dir, so it
      # runs after the builder provisions it.
      def run_openers(options, thread_id)
        { harness: -> { work_harness(options, thread_id) },
          memory: ->(dir) { open_memory(options, dir) } }
      end

      def install_signal_handlers
        @cancellation = Tamoz::CancellationToken.new
        cancel = ->(reason) { @cancellation&.cancel!(reason) }
        Cancellation::Trap.install(int: cancel, term: cancel) { yield }
      ensure
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
    end
  end
end
