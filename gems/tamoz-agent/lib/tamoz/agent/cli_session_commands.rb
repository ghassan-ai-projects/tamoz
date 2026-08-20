# frozen_string_literal: true

module Tamoz
  module Agent
    # Durable session command entry points. Lifecycle driving, authority policy,
    # and rendering remain on CLI; this module owns only command argument flow.
    # :reek:ControlParameter — --force is the CLI's explicit cancellation policy.
    # :reek:DataClump — (options, argv) is the established subcommand signature.
    # :reek:DuplicateMethodCall — repeated reads preserve validation and output order.
    # :reek:FeatureEnvy — renderers and guards intentionally inspect boundary values.
    # :reek:LongParameterList — submission requires the four parts of effect identity.
    # :reek:NestedIterators — OptionParser and durable execution are nested block APIs.
    # :reek:TooManyStatements — command entry points spell out ordered operator flows.
    # :reek:UncommunicativeVariableName — `e` follows the enforced rescue convention.
    # :reek:UtilityFunction — parsing/submission helpers belong beside their commands.
    # rubocop:disable Metrics/ModuleLength -- one private command family; every
    # command and helper stays within the method ceilings.
    module CLISessionCommands
      # The `tamoz resolve` vocabulary: exactly the three states the effect
      # journal can be resolved into (`effect_journal.rb:630-636`). Public
      # because it is the module's one piece of shared vocabulary, not a
      # helper — the private section below starts after it.
      RESOLUTIONS = %w[succeeded failed abandoned].freeze

      # These methods were private on CLI and remain private after inclusion.

      private

      def cmd_ask(options, argv)
        task = argv.join(' ').strip
        raise OptionParser::MissingArgument, 'TASK' if task.empty?

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
        require 'tamoz/sqlite'

        session_dir = resolve_session_dir(options)
        pattern = File.join(session_dir, '*.sqlite3')
        files = Dir.glob(pattern)
        if options[:json]
          render_thread_list_json(files, options)
        else
          render_thread_list_human(files, options)
        end
        0
      rescue Tamoz::SQLite::Error, SQLite3::Exception => e
        @err.puts "tamoz: #{e.message}"
        1
      end

      def render_thread_list_json(files, options)
        threads = files.filter_map { |path| list_entry(path, options) }
        @out.puts JSON.generate('threads' => threads)
      end

      def render_thread_list_human(files, options)
        if files.empty?
          @out.puts 'No sessions found.'
          return
        end

        @out.puts 'THREAD                 STATUS     LAST_UPDATED         SUMMARY'
        files.each do |path|
          entry = list_entry(path, options)
          render_thread_list_entry(entry) if entry
        end
      end

      def render_thread_list_entry(entry)
        @out.puts format(
          '%-22<thread>s %-10<status>s %-20<updated>s %<summary>s',
          thread: entry['thread_id'], status: entry['status'],
          updated: Time.at(entry['updated_at_ms'] / 1000.0).strftime('%Y-%m-%d %H:%M'),
          summary: entry['summary']
        )
      end

      def cmd_show(options, argv)
        transcript = 50
        OptionParser.new do |value|
          value.on('--transcript N', Integer, 'Show last N records') { |entry| transcript = entry }
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
        task = argv.join(' ').strip
        raise OptionParser::MissingArgument, 'TASK' if task.empty?

        profile = load_operator_profile(options)
        # DR-5 RC1: same request-id-before-authority rule as cmd_ask — a consumed
        # transition must be marked with the id of the ask that actually runs.
        request_id = SecureRandom.uuid
        profile = resolve_session_authority(options, thread_id, profile, boundary: true, request_id:)
        run_durable(options, thread_id, read_only: false, profile:, request_id:) do |session, request_id, owner_id|
          session.verify_skill_binding!(thread: thread_id)
          request = submit_follow_up(session, task, thread_id, request_id)
          view = drain_to_terminal(session, thread_id:, owner_id:, options:, tracked_request: request)
          if tracked_request_queued?(session, request)
            emit_follow_up_queued(thread_id, request, view, options:)
            return CLI::EXIT_PAUSED
          end
          exit_for_view(view)
        end
      end

      def submit_follow_up(session, task, thread_id, request_id)
        session.app.durable_runner.submit(
          SessionPlanningContext.follow_up_payload(
            session.app.checkpointer,
            thread_id:,
            request_id:,
            text: task
          ),
          thread: thread_id,
          request_id:,
          operation: :turn,
          delivery: :queue
        )
      end

      def cmd_redirect(options, argv)
        thread_id = extract_thread!(argv)
        task = argv.join(' ').strip
        raise OptionParser::MissingArgument, 'new task' if task.empty?

        profile = load_operator_profile(options)
        profile = resolve_session_authority(options, thread_id, profile, boundary: false)
        run_durable(options, thread_id, read_only: false, profile:) do |session, request_id, owner_id|
          session.verify_skill_binding!(thread: thread_id)
          session.app.durable_runner.submit(
            { 'task' => task },
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
        force = parse_cancel_force(argv)
        thread_id = extract_thread!(argv)

        run_durable(options, thread_id, read_only: false) do |session, request_id, owner_id|
          view = session.view(thread: thread_id)
          validate_cancellable!(view, force)
          submit_cancel(session, thread_id, request_id)
          view = drain_to_terminal(session, thread_id:, owner_id:, options:)
          cancel_exit(view)
        end
      end

      def parse_cancel_force(argv)
        force = false
        OptionParser.new do |value|
          value.on('--force', 'Cancel even if the thread is not active') { force = true }
        end.parse!(argv)
        force
      end

      def validate_cancellable!(view, force)
        return if %i[running paused].include?(view.status) || force

        raise ArgumentError,
              "thread status is #{view.status}; use --force to cancel anyway"
      end

      def submit_cancel(session, thread_id, request_id)
        session.app.durable_runner.submit(
          { 'task' => { 'cancel' => true, 'reason' => 'cancelled_by_user' } },
          thread: thread_id,
          request_id:,
          operation: :redirect,
          delivery: :redirect
        )
      end

      def cancel_exit(view)
        return exit_for_view(view) unless view.state&.fetch(:terminal_reason, nil) == 'cancelled_by_user'
        return exit_for_cancellation if @cancellation&.cancelled?

        0
      end

      def cmd_resolve(options, argv)
        thread_id = extract_thread!(argv)
        effect_key, status, status_symbol = parse_resolution(argv)
        run_durable(options, thread_id, read_only: false) do |session, _request_id, owner_id|
          session.resolve_effect(
            thread: thread_id,
            effect_key:,
            status: status_symbol,
            actor: 'tamoz.cli',
            evidence: { 'command' => 'tamoz resolve', 'status' => status },
            owner_id:
          )
          @out.puts "Resolved #{effect_key} as #{status}." unless options[:json]
          0
        end
      end

      # The word an operator types IS the state that gets recorded.
      #
      # This used to accept `unknown` and durably record `:failed`, which is one
      # word meaning two different things depending on which entry path you came
      # in through — and worse, it recorded a verdict the operator did not give.
      # `unknown` is the state an effect is being resolved OUT of; it is not one
      # of the three the journal can be resolved INTO
      # (`effect_journal.rb:630-636`), so it is refused with the vocabulary that
      # works instead of being silently translated.
      def parse_resolution(argv)
        effect_key = argv.shift
        status = argv.shift
        raise OptionParser::MissingArgument, 'EFFECT_KEY' if effect_key.to_s.empty?
        raise OptionParser::MissingArgument, 'STATUS' if status.to_s.empty?

        unless RESOLUTIONS.include?(status)
          hint = status == 'unknown' ? ' (`unknown` is the state being resolved, not a resolution)' : ''
          raise OptionParser::InvalidArgument,
                "status must be #{RESOLUTIONS.join(', ')}#{hint}"
        end

        [effect_key, status, status.to_sym]
      end
    end
    # rubocop:enable Metrics/ModuleLength
  end
end
